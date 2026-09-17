import Darwin
import Foundation

/// Original A32 → A64 translator for predicated integer operations, multiplication and branches.
/// Complex instructions use ARMCPU. Compiled code never accesses guest-supplied host pointers.
final class ARM64JIT {
  // Low word: CPSR. High word: the prefix actually executed, including predicates that failed.
  typealias Function = @convention(c) (UnsafeMutablePointer<UInt32>, UInt32) -> UInt64
  struct Block {
    let offset: Int
    let instructions: Int
    let generation: UInt64
    let checkedMemory: Bool
  }
  private let code: UnsafeMutableRawPointer
  private let capacity = 8 * 1024 * 1024
  private var used = 0
  private var blocks: [UInt32: Block] = [:]
  private var memoryVariants: [UInt32: [Block]] = [:]
  private var misses: [UInt32: UInt64] = [:]
  private struct ExecutableStoreMiss {
    let generation: UInt64
    let regionBase: UInt32
    let regionEnd: UInt64
    let baseRegister: Int
    let indexRegister: Int?
    let displacement: UInt32
    let shift: UInt32
    let add: Bool
    let width: Int

    func matches(_ cpu: ARMCPU, generation currentGeneration: UInt64) -> Bool {
      guard generation == currentGeneration else { return false }
      let offset = indexRegister.map { cpu.r[$0] << shift } ?? displacement
      let base = cpu.r[baseRegister]
      let address = add ? base &+ offset : base &- offset
      return address >= regionBase && UInt64(address) + UInt64(width) <= regionEnd
    }
  }
  // A store into executable memory must retain the interpreter's generation
  // updates. Cache that decision only for the current instruction generation
  // and a freshly computed complete target range in the same mapping.
  private var executableStoreMisses: [UInt32: ExecutableStoreMiss] = [:]
  // Own mappings for embedded, checked memory pointers; never reuse code across memory owners.
  private var memoryOwner: GuestMemory?
  private struct DispatchEntry {
    var pc: UInt32 = UInt32.max
    var generation: UInt64 = 0
    var block: Block? = nil
  }
  private static let dispatchSlots = 1024
  private let dispatch: UnsafeMutablePointer<DispatchEntry>
  // Keep alternatives off the ordinary dispatch entry's hot read path.
  private let dispatchAlternates: UnsafeMutablePointer<Block?>
  private(set) var compiledBlocks = 0
  private(set) var codeCacheResets = 0
  private(set) var executedInstructions: UInt64 = 0
  init() throws {
    guard
      let p = mmap(
        nil, capacity, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0),
      p != MAP_FAILED
    else { throw EmulationError.unsupported("MAP_JIT: \(String(cString:strerror(errno)))") }
    code = p
    dispatch = .allocate(capacity: Self.dispatchSlots)
    dispatch.initialize(repeating: DispatchEntry(), count: Self.dispatchSlots)
    dispatchAlternates = .allocate(capacity: Self.dispatchSlots)
    dispatchAlternates.initialize(repeating: nil, count: Self.dispatchSlots)
  }
  deinit {
    dispatch.deinitialize(count: Self.dispatchSlots)
    dispatch.deallocate()
    dispatchAlternates.deinitialize(count: Self.dispatchSlots)
    dispatchAlternates.deallocate()
    munmap(code, capacity)
  }
  func execute(_ cpu: ARMCPU, maximum: Int = 32) throws -> Bool {
    guard !cpu.thumb, cpu.pc < 0xf000_0000, maximum > 0 else { return false }
    if memoryOwner !== cpu.memory {
      if memoryOwner != nil { discardCodeCache() }
      memoryOwner = cpu.memory
    }
    guard let page = try cpu.memory.codePage(at: cpu.pc) else { return false }
    let generation = page.generation
    // The worker owns this fixed cache. Validate the current mapping and code
    // generation before either a positive or negative hit; collisions fall back
    // to the complete tables, so they never force otherwise valid recompilation.
    let pc = cpu.pc
    let slot = Int(((pc >> 2) ^ (pc >> 12)) & UInt32(Self.dispatchSlots - 1))
    let cached = dispatch[slot]
    let block: Block?
    if cached.pc == pc && cached.generation == generation {
      block = cached.block
    } else {
      dispatchAlternates[slot] = nil
      if misses[pc] == generation {
        block = nil
      } else if let existing = blocks[pc], existing.generation == generation {
        block = existing
      } else if executableStoreMisses[pc]?.matches(cpu, generation: generation) == true {
        return false
      } else {
        block = try compile(cpu, generation: generation, end: page.end)
      }
      // An invalid address is a property of this invocation, not of the opcode.
      dispatch[slot] = block != nil || misses[pc] == generation
        ? DispatchEntry(pc: pc, generation: generation, block: block) : DispatchEntry()
    }
    guard let block, block.instructions <= maximum else { return false }
    func run(_ candidate: Block) -> Bool {
      let fn = unsafeBitCast(code.advanced(by: candidate.offset), to: Function.self)
      let result = fn(cpu.r, cpu.cpsr)
      let executed = candidate.checkedMemory ? result >> 32 : UInt64(candidate.instructions)
      cpu.cpsr = UInt32(truncatingIfNeeded: result)
      cpu.count &+= executed
      executedInstructions &+= executed
      return executed != 0
    }
    if run(block) { return true }
    if let alternate = dispatchAlternates[slot], alternate.instructions <= maximum,
      run(alternate) {
      dispatch[slot] = DispatchEntry(pc: pc, generation: generation, block: alternate)
      dispatchAlternates[slot] = block
      return true
    }
    // A zero-length checked exit has changed no guest state. Another invocation
    // may use a different stack or data mapping at the same instruction address.
    for candidate in memoryVariants[pc] ?? [] where candidate.offset != block.offset
      && candidate.generation == generation && candidate.instructions <= maximum {
      if run(candidate) {
        dispatch[slot] = DispatchEntry(pc: pc, generation: generation, block: candidate)
        dispatchAlternates[slot] = block
        return true
      }
    }
    if executableStoreMisses[pc]?.matches(cpu, generation: generation) == true { return false }
    guard let replacement = try compile(cpu, generation: generation, end: page.end) else {
      return false
    }
    dispatch[slot] = DispatchEntry(pc: pc, generation: generation, block: replacement)
    dispatchAlternates[slot] = nil
    return replacement.instructions <= maximum && run(replacement)
  }
  private func discardCodeCache() {
    blocks.removeAll()
    memoryVariants.removeAll()
    misses.removeAll()
    executableStoreMisses.removeAll()
    for slot in 0..<Self.dispatchSlots {
      dispatch[slot] = DispatchEntry()
      dispatchAlternates[slot] = nil
    }
    codeCacheResets += 1
    used = 0
  }
  private func compile(_ cpu: ARMCPU, generation: UInt64, end: UInt64) throws -> Block? {
    executableStoreMisses.removeValue(forKey: cpu.pc)
    // NZCV uses the same bits and condition encodings in A32 and A64. w4 carries
    // CPSR; arithmetic flag updates are mirrored there without changing its low bits.
    var words: [UInt32] = [0xd51b_4201, 0x2a01_03e4]  // msr NZCV, x1; mov w4, w1
    var count = 0
    var address = cpu.pc
    var writesPC = false
    var accessExits: [(branch: Int, instructions: Int, pc: UInt32)] = []
    var accessRegion: GuestMemory.Region?
    var accessWidth = 4
    var transientMemoryMiss = false
    func load(_ host: UInt32, _ guest: UInt32) { words.append(0xb940_0000 | (guest << 10) | host) }
    func immediateWords(_ host: UInt32, _ value: UInt32) -> [UInt32] {
      var result = [0x5280_0000 | ((value & 65535) << 5) | host]
      if value >> 16 != 0 { result.append(0x72a0_0000 | ((value >> 16) << 5) | host) }
      return result
    }
    func imm(_ host: UInt32, _ value: UInt32) {
      words.append(contentsOf: immediateWords(host, value))
    }
    func returnPrefix(_ instructions: Int) {
      words.append(0x2a04_03e0)  // mov w0,w4: CPSR; zero the upper word.
      if !accessExits.isEmpty {
        imm(5, UInt32(instructions))
        words.append(0xb360_7ca0)  // bfi x0,x5,#32,#32: completed instruction count.
      }
      words.append(0xd65f_03c0)
    }
    func predicate(_ condition: UInt32) -> Int? {
      guard condition != 14 else { return nil }
      let index = words.count
      words.append(0x5400_0000 | (condition ^ 1))  // b.<inverse> past this guest instruction
      return index
    }
    func endPredicate(_ index: Int?) {
      if let index { words[index] |= UInt32(words.count - index) << 5 }
    }
    func registerShift(_ kind: UInt32, carry: Bool) {
      // A32 uses the low byte, unlike A64's modulo-32/64 shift counts.
      words.append(0x5300_1ca5)  // uxtb w5,w5
      let zero = words.count
      words.append(0x3400_0005)  // cbz w5: zero preserves operand and carry
      switch kind {
      case 0:
        // A 64-bit temporary retains the bit shifted out of bit 31.
        words += [0x9ac5_2046, 0x7100_80bf, 0x9a9f_90c6, 0xd360_fcc5, 0x2a06_03e2]
      case 1:
        // Pack the result and carry into bits 32:1 and bit 0.
        words += [0xd37f_f846, 0x9ac5_24c6, 0x7100_80bf, 0x9a9f_90c6,
          0x2a06_03e5, 0xd341_fcc6, 0x2a06_03e2]
      case 2:
        // Sign extension plus saturation at 32 gives both result and sign carry.
        words += [0x5280_0407, 0x6b07_00bf, 0x1a87_90a5, 0x9340_7c46,
          0xd37f_f8c6, 0x9ac5_28c6, 0x2a06_03e5, 0x9341_fcc6, 0x2a06_03e2]
      default:
        words += [0x1ac5_2c42, 0x531f_7c45]  // ror w2,w2,w5; result bit 31 is carry
      }
      if carry { words.append(0x3303_00a4) }
      // Internal comparisons must not change guest predicates or ADC/SBC input C.
      words.append(0xd51b_4204)
      words[zero] |= UInt32(words.count - zero) << 5
    }
    // A block belongs to one code page. Writes to other pages cannot invalidate it;
    // every write overlapping this page still invalidates both code and miss entries.
    while count < 32 && UInt64(address) + 4 <= end {
      guard let op = try? cpu.memory.read32(address) else { break }
      // PLD is an optional guest cache hint. Count it without accessing its
      // address or changing architectural state; other unconditional forms
      // still retain their existing interpreter path.
      if op & 0xff70_f000 == 0xf550_f000
        || (op & 0xff70_f010 == 0xf750_f000 && op & 15 != 15) {
        count += 1; address &+= 4
        continue
      }
      guard op >> 28 != 15 else { break }
      let condition = op >> 28
      if op & 0x0f7f_0000 == 0x051d_0000, (op >> 12) & 15 != 15 {
        // LDR Rt,[sp,+/-imm12], no writeback. Region storage is stable and owned by
        // memoryOwner. Check the complete four-byte range again on EVERY execution.
        let offset = op & 4095
        let effective = op & 0x0080_0000 != 0 ? cpu.r[13] &+ offset : cpu.r[13] &- offset
        transientMemoryMiss = true
        guard let region = try? cpu.memory.region(effective, 4) else { break }
        guard accessWidth == 4, accessRegion == nil || accessRegion === region else { break }
        accessRegion = region
        let skip = predicate(condition)
        load(2, 13)
        words.append((op & 0x0080_0000 != 0 ? 0x1100_0042 : 0x5100_0042) | (offset << 10))
        words.append(0x4b09_0042)  // sub w2,w2,w9: offset in the selected guest mapping.
        words.append(0x6b0a_005f)  // cmp w2,w10: unsigned bound also rejects addresses below base.
        accessExits.append((words.count, count, address))
        words.append(0x5400_0008)  // b.hi: leave precisely before this guest load.
        words.append(0xd51b_4204)  // Restore guest NZCV after the bounds comparison.
        words.append(0xb862_4903)  // ldr w3,[x8,w2,uxtw], including unaligned reads.
        words.append(0xb900_0003 | (((op >> 12) & 15) << 10))
        endPredicate(skip)
        count += 1
        address &+= 4
        continue
      }
      // A32's scalar stack aliases have the same single-word effect as a
      // one-register list transfer. Reuse its bounds, writeback and PC handling;
      // this normalizes the compiler input only, never the guest instruction.
      let stackRegister = (op >> 12) & 15
      let scalarPush = op & 0x0fff_0fff == 0x052d_0004 && stackRegister != 13 && stackRegister != 15
      let scalarPop = op & 0x0fff_0fff == 0x049d_0004 && stackRegister != 13
      let transfer = scalarPush || scalarPop
        ? (op & 0xf000_0000) | (scalarPop ? 0x08bd_0000 : 0x092d_0000) | (1 << stackRegister)
        : op
      if transfer & 0x0e40_0000 == 0x0800_0000, transfer & 65535 != 0 {
        // Register-list transfers start at a real instruction boundary. Validate
        // the entire span before native access; partial faults retain interpreter
        // ordering, and executable stores retain code-generation invalidation.
        guard count == 0 else { break }
        let base = (transfer >> 16) & 15, list = transfer & 65535
        let writeback = transfer & 0x0020_0000 != 0, reading = transfer & 0x0010_0000 != 0
        guard base != 15, !writeback || list & (1 << base) == 0 else { break }
        let width = list.nonzeroBitCount * 4
        let up = transfer & 0x0080_0000 != 0, pre = transfer & 0x0100_0000 != 0
        let initial = cpu.r[Int(base)]
        let first = up ? initial &+ (pre ? 4 : 0) : initial &- UInt32(width) &+ (pre ? 0 : 4)
        transientMemoryMiss = true
        guard let region = try? cpu.memory.region(first, width), reading || !region.executable else { break }
        accessRegion = region; accessWidth = width
        let loadsPC = reading && list & 0x8000 != 0
        if loadsPC { imm(3, address &+ 4); words.append(0xb900_3c03) }
        let skip = predicate(condition)
        load(2, base)
        if up {
          if pre { words.append(0x1100_1042) }
        } else {
          words.append(0x5100_0042 | (UInt32(width - (pre ? 0 : 4)) << 10))
        }
        words += [0x4b09_0042, 0x6b0a_005f]
        accessExits.append((words.count, count, address))
        words += [0x5400_0008, 0xd51b_4204, 0x8b22_410b] // add x11,x8,w2,uxtw
        // Base-in-list with writeback is excluded, so updating it now cannot
        // change a stored operand or conflict with a loaded register.
        if writeback {
          load(3, base)
          words.append((up ? 0x1100_0063 : 0x5100_0063) | UInt32(width) << 10)
          words.append(0xb900_0003 | base << 10)
        }
        var pending = list, slot: UInt32 = 0
        while pending != 0 {
          let register = UInt32(pending.trailingZeroBitCount)
          // The complete guest span was checked above. Consecutive register
          // slots can therefore move as exact 16-/8-byte NEON values. V0 is
          // caller-saved in the host C ABI. Never include guest PC: it retains
          // the scalar pipeline/interworking handling below. Unscaled offsets
          // also preserve unaligned guest addresses and arbitrary register runs.
          let lanes: UInt32 = register <= 11 && (pending >> register) & 15 == 15 ? 4
            : register <= 13 && (pending >> register) & 3 == 3 ? 2 : 1
          if lanes > 1 {
            let readOpcode: UInt32 = lanes == 4 ? 0x3cc00000 : 0xfc400000
            let writeOpcode: UInt32 = lanes == 4 ? 0x3c800000 : 0xfc000000
            let guestOffset = slot * 4, registerOffset = register * 4
            words.append(readOpcode | ((reading ? guestOffset : registerOffset) << 12)
              | (reading ? 11 << 5 : 0))
            words.append(writeOpcode | ((reading ? registerOffset : guestOffset) << 12)
              | (reading ? 0 : 11 << 5))
            pending &= ~(((1 << lanes) - 1) << register)
            slot += lanes
            continue
          }
          pending &= pending - 1
          if reading {
            words.append(0xb940_0163 | slot << 10) // ldr w3,[x11,#slot*4]
            if register == 15 {
              words += [0x331b_0064, 0x531f_0062, 0x5200_0442, 0x0a22_0063, 0xb900_3c03]
            } else { words.append(0xb900_0003 | register << 10) }
          } else {
            if register == 15 { imm(3, address &+ 12) } else { load(3, register) }
            words.append(0xb900_0163 | slot << 10) // str w3,[x11,#slot*4]
          }
          slot += 1
        }
        endPredicate(skip)
        count += 1; address &+= 4
        if loadsPC { writesPC = true; break }
        continue
      }
      let immediateWordStore = op & 0x0f70_0000 == 0x0500_0000
      let indexedWordStore = op & 0x0f70_0070 == 0x0700_0000
      let immediateByteStore = op & 0x0f70_0000 == 0x0540_0000
      let indexedByteStore = op & 0x0f70_0070 == 0x0740_0000
      let halfwordStore = op & 0x0f30_00f0 == 0x0100_00b0
      if immediateWordStore || indexedWordStore || immediateByteStore || indexedByteStore || halfwordStore {
        // Specialize only at an actual guest instruction boundary. Executable
        // mappings keep the interpreter write path and its code-page invalidation.
        guard count == 0 else { break }
        let base = (op >> 16) & 15, source = (op >> 12) & 15, index = op & 15
        let immediate = immediateWordStore || immediateByteStore
          || (halfwordStore && op & 0x0040_0000 != 0)
        guard base != 15, source != 15, immediate || index != 15,
          !halfwordStore || immediate || op & 0x0000_0f00 == 0 else { break }
        let shift = halfwordStore ? 0 : (op >> 7) & 31
        let displacement = halfwordStore ? ((op >> 4) & 0xf0) | (op & 15) : op & 4095
        let offset = immediate ? displacement : cpu.r[Int(index)] << shift
        let initial = cpu.r[Int(base)]
        let effective = op & 0x0080_0000 != 0 ? initial &+ offset : initial &- offset
        let width = halfwordStore ? 2 : (immediateByteStore || indexedByteStore ? 1 : 4)
        transientMemoryMiss = true
        guard let region = try? cpu.memory.region(effective, width) else { break }
        if region.executable {
          executableStoreMisses[cpu.pc] = ExecutableStoreMiss(
            generation: generation, regionBase: region.base, regionEnd: region.end,
            baseRegister: Int(base), indexRegister: immediate ? nil : Int(index),
            displacement: displacement, shift: shift, add: op & 0x0080_0000 != 0, width: width)
          break
        }
        accessRegion = region; accessWidth = width
        let skip = predicate(condition)
        load(2, base)
        if immediate {
          words.append((op & 0x0080_0000 != 0 ? 0x1100_0042 : 0x5100_0042) | (offset << 10))
        } else {
          load(1, index)
          words.append((op & 0x0080_0000 != 0 ? 0x0b01_0042 : 0x4b01_0042) | (shift << 10))
        }
        words += [0x4b09_0042, 0x6b0a_005f]
        accessExits.append((words.count, count, address))
        words += [0x5400_0008, 0xd51b_4204]
        load(3, source)
        words.append(width == 4 ? 0xb822_4903 : (width == 2 ? 0x7822_4903 : 0x3822_4903))
        endPredicate(skip)
        count += 1; address &+= 4
        continue
      }
      let immediateLoad = op & 0x0f70_0000 == 0x0510_0000
      let indexedLoad = op & 0x0f70_0070 == 0x0710_0000
      if immediateLoad || indexedLoad {
        // Start a checked word-load block at the actual instruction boundary.
        // Selecting a register's mapping after preceding guest arithmetic would
        // specialize on stale entry registers. Other mappings leave this block.
        guard count == 0 else { break }
        let base = (op >> 16) & 15, target = (op >> 12) & 15, index = op & 15
        guard !indexedLoad || index != 15 else { break }
        let amount = (op >> 7) & 31
        let initial = base == 15 ? address &+ 8 : cpu.r[Int(base)]
        let offset = immediateLoad ? op & 4095 : cpu.r[Int(index)] << amount
        let effective = op & 0x0080_0000 != 0 ? initial &+ offset : initial &- offset
        transientMemoryMiss = true
        guard let region = try? cpu.memory.region(effective, 4) else { break }
        accessRegion = region
        if target == 15 {
          imm(3, address &+ 4)
          words.append(0xb900_3c03) // Untaken predicated load falls through.
        }
        let skip = predicate(condition)
        if base == 15 { imm(2, address &+ 8) } else { load(2, base) }
        if immediateLoad {
          words.append((op & 0x0080_0000 != 0 ? 0x1100_0042 : 0x5100_0042) | (offset << 10))
        } else {
          load(1, index)
          words.append((op & 0x0080_0000 != 0 ? 0x0b01_0042 : 0x4b01_0042) | (amount << 10))
        }
        words.append(0x4b09_0042) // Mapping-relative offset, with A32 wraparound.
        words.append(0x6b0a_005f)
        accessExits.append((words.count, count, address))
        words.append(0x5400_0008)
        words.append(0xd51b_4204)
        words.append(0xb862_4903)
        if target == 15 {
          // ARMv5 load-to-PC interworks, just like the interpreter's branch().
          words += [0x331b_0064, 0x531f_0062, 0x5200_0442, 0x0a22_0063, 0xb900_3c03]
          writesPC = true
        } else {
          words.append(0xb900_0003 | (target << 10))
        }
        endPredicate(skip)
        count += 1
        address &+= 4
        if writesPC { break }
        continue
      }
      let immediateByte = op & 0x0f70_0000 == 0x0550_0000
      let indexedByte = op & 0x0f70_0070 == 0x0750_0000
      let halfword = op & 0x0f30_00f0 == 0x0110_00b0
      let signedByte = op & 0x0f30_00f0 == 0x0110_00d0
      let signedHalfword = op & 0x0f30_00f0 == 0x0110_00f0
      let extraLoad = halfword || signedByte || signedHalfword
      if immediateByte || indexedByte || extraLoad {
        guard count == 0 else { break }
        let base = (op >> 16) & 15, target = (op >> 12) & 15, index = op & 15
        let immediate = immediateByte || (extraLoad && op & 0x0040_0000 != 0)
        guard target != 15, immediate || (base != 15 && index != 15),
          !extraLoad || immediate || op & 0x0000_0f00 == 0 else { break }
        let amount = extraLoad ? 0 : (op >> 7) & 31
        let displacement = extraLoad ? ((op >> 4) & 0xf0) | (op & 15) : op & 4095
        let offset = immediate ? displacement : cpu.r[Int(index)] << amount
        let initial = base == 15 ? address &+ 8 : cpu.r[Int(base)]
        let effective = op & 0x0080_0000 != 0 ? initial &+ offset : initial &- offset
        let width = halfword || signedHalfword ? 2 : 1
        transientMemoryMiss = true
        guard let region = try? cpu.memory.region(effective, width) else { break }
        accessRegion = region; accessWidth = width
        let skip = predicate(condition)
        if base == 15 { imm(2, address &+ 8) } else { load(2, base) }
        if immediate {
          words.append((op & 0x0080_0000 != 0 ? 0x1100_0042 : 0x5100_0042) | (offset << 10))
        } else {
          load(1, index)
          words.append((op & 0x0080_0000 != 0 ? 0x0b01_0042 : 0x4b01_0042) | (amount << 10))
        }
        words += [0x4b09_0042, 0x6b0a_005f]
        accessExits.append((words.count, count, address))
        // Signed loads extend directly into W3 (the 32-bit guest register).
        // The same full-width guard and untaken-predicate path apply to both signs.
        let nativeLoad: UInt32 = signedHalfword ? 0x78e2_4903
          : signedByte ? 0x38e2_4903 : halfword ? 0x7862_4903 : 0x3862_4903
        words += [0x5400_0008, 0xd51b_4204, nativeLoad]
        words.append(0xb900_0003 | (target << 10))
        endPredicate(skip)
        count += 1; address &+= 4
        continue
      }
      if op & 0x0fff_fff0 == 0x01a0_f000 {  // MOV pc,Rm, without S or shift.
        imm(3, address &+ 4)
        words.append(0xb900_3c03)  // Fallthrough when the condition fails.
        let skip = predicate(condition)
        let source = op & 15
        if source == 15 { imm(3, address &+ 8) } else { load(3, source) }
        // A32 MOV to PC preserves CPSR and does not interwork like BX.
        words.append(0x121e_7463)  // and w3,w3,#0xfffffffc
        words.append(0xb900_3c03)
        endPredicate(skip)
        count += 1
        writesPC = true
        break
      }
      if op & 0x0fff_fff0 == 0x012f_ff10 || op & 0x0fff_fff0 == 0x012f_ff30 {
        let source = op & 15
        let link = op & 0x20 != 0
        guard !link || source != 15 else { break }  // BLX pc is not a valid ARMv5 operand.
        imm(3, address &+ 4)
        words.append(0xb900_3c03)
        let skip = predicate(condition)
        // Read the target before writing LR, including BLX lr.
        if source == 15 { imm(3, address &+ 8) } else { load(3, source) }
        if link {
          imm(2, address &+ 4)
          words.append(0xb900_3802)
        }
        words.append(0x331b_0064)  // bfi w4, w3, #5, #1: CPSR.T = target bit zero
        words.append(0x531f_0062)  // ubfiz w2, w3, #1, #1
        words.append(0x5200_0442)  // eor w2, w2, #3: alignment mask is 1 (Thumb) or 3 (ARM)
        words.append(0x0a22_0063)  // bic w3, w3, w2
        words.append(0xb900_3c03)
        endPredicate(skip)
        count += 1
        writesPC = true
        break
      }
      if op & 0x0e00_0000 == 0x0a00_0000 {  // B / BL; BLX immediate remains in ARMCPU.
        imm(3, address &+ 4)
        words.append(0xb900_3c03)  // str w3, [x0, #60]: fallthrough PC
        let skip = predicate(condition)
        if op & 0x0100_0000 != 0 {
          words.append(0xb900_3803)  // str w3, [x0, #56]: LR only when BL is taken
        }
        let displacement = UInt32(bitPattern: Int32(bitPattern: op << 8) >> 6)
        imm(3, address &+ 8 &+ displacement)
        words.append(0xb900_3c03)
        endPredicate(skip)
        count += 1
        writesPC = true
        break
      }
      if op & 0x0ff0_0030 == 0x0680_0010 {
        let rd = (op >> 12) & 15, rn = (op >> 16) & 15, rm = op & 15
        guard rd != 15, rn != 15, rm != 15 else { break }
        let skip = predicate(condition)
        load(1, rn)
        load(2, rm)
        let amount = (op >> 7) & 31
        let destination: UInt32
        if op & 0x40 == 0 {
          if amount != 0 {
            words.append(0x5300_0042 | ((32 - amount) << 16) | ((31 - amount) << 10))
          } // lsl w2,w2,#amount
          words.append(0x3300_3c22) // bfxil w2,w1,#0,#16
          destination = 2
        } else {
          let shift = amount == 0 ? 31 : amount // ASR #32 has the same sign-filled result.
          words.append(0x1300_7c42 | (shift << 16)) // asr w2,w2,#shift
          words.append(0x3300_3c41) // bfxil w1,w2,#0,#16
          destination = 1
        }
        words.append(0xb900_0000 | (rd << 10) | destination)
        endPredicate(skip)
        count += 1
        address &+= 4
        continue
      }
      if op & 0x0f80_03f0 == 0x0680_0070 {
        // ARMv6 byte/halfword extension, with optional rotated source and addend.
        // Packed two-lane forms retain their interpreter boundary.
        let kind = (op >> 20) & 7
        let rd = (op >> 12) & 15, rn = (op >> 16) & 15, rm = op & 15
        guard [UInt32(2), 3, 6, 7].contains(kind), rd != 15, rm != 15 else { break }
        let skip = predicate(condition)
        load(1, rm)
        let rotation = ((op >> 10) & 3) * 8
        if rotation != 0 { words.append(0x1381_0021 | (rotation << 10)) } // ror w1,w1,#rotation
        if rn != 15 { load(2, rn) }
        let signed: UInt32 = kind & 4 == 0 ? 0x1300_0000 : 0x5300_0000
        let lastBit: UInt32 = kind & 1 == 0 ? 7 : 15
        words.append(signed | (lastBit << 10) | 0x23) // sxtb/sxth/uxtb/uxth w3,w1
        if rn != 15 { words.append(0x0b03_0043) } // add w3,w2,w3, with no flag updates
        words.append(0xb900_0003 | (rd << 10))
        endPredicate(skip)
        count += 1
        address &+= 4
        continue
      }
      guard op & 0x0c00_0000 == 0 else { break }
      if op & 0x0ff0_0090 == 0x0160_0080 || op & 0x0ff0_00b0 == 0x0120_00a0
        || op & 0x0ff0_0090 == 0x0100_0080 {
        // SMULxy / SMULWy / SMLAxy. Word/long accumulating forms use ARMCPU.
        let destination = (op >> 16) & 15
        let rs = (op >> 8) & 15
        let rm = op & 15
        let accumulate = op & 0x0060_0000 == 0
        let accumulator = (op >> 12) & 15
        let word = op & 0x0060_0000 == 0x0020_0000
        guard destination != 15, rs != 15, rm != 15,
          accumulate ? accumulator != 15 : accumulator == 0 else { break }
        let skip = predicate(condition)
        load(1, rm)
        load(2, rs)
        if !word { words.append(op & 0x20 == 0 ? 0x1300_3c21 : 0x1310_7c21) }
        words.append(op & 0x40 == 0 ? 0x1300_3c42 : 0x1310_7c42)
        words.append(word ? 0x9b22_7c23 : 0x1b02_7c23)  // smull x3 / mul w3
        if word { words.append(0x9350_fc63) }  // asr x3, x3, #16 (negative rounds down)
        if accumulate {
          load(5, accumulator)  // Snapshot before the destination is written, including aliases.
          words.append(0x2b05_0063)  // adds w3,w3,w5: signed accumulation overflow
          words.append(0x1a9f_77e5)  // cset w5,vs
          words.append(0x2a05_6c84)  // orr w4,w4,w5,lsl #27: sticky CPSR.Q
          words.append(0xd51b_4204)  // Restore guest NZCV for following predicates/ADC/SBC.
        }
        words.append(0xb900_0003 | (destination << 10))
        endPredicate(skip)
        count += 1
        address &+= 4
        continue
      }
      if op & 0x0f80_00f0 == 0x0080_0090 {  // UMULL / UMLAL / SMULL / SMLAL.
        let hi = (op >> 16) & 15
        let lo = (op >> 12) & 15
        let rs = (op >> 8) & 15
        let rm = op & 15
        let accumulate = op & 0x0020_0000 != 0
        guard hi != 15, lo != 15, hi != lo, rs != 15, rm != 15 else { break }
        let skip = predicate(condition)
        // Snapshot both operands and the complete accumulator before writing either half.
        load(1, rm)
        load(2, rs)
        if accumulate {
          load(3, lo)
          load(5, hi)
          words.append(0xb360_7ca3)  // bfi x3, x5, #32, #32
        }
        let signed = op & 0x0040_0000 != 0
        words.append((signed ? 0x9b22_0023 : 0x9ba2_0023) | (accumulate ? 3 : 31) << 10)
        // S forms derive N/Z from all 64 bits, preserving C/V and all other CPSR bits.
        if op & 0x0010_0000 != 0 {
          words.append(0xea03_007f)  // tst x3, x3
          words.append(0xd53b_4205)  // mrs x5, NZCV
          words.append(0x3300_7485)  // bfi w5, w4, #0, #30
          words.append(0x2a05_03e4)
          words.append(0xd51b_4204)  // following predicates/ADC see the merged flags
        }
        words.append(0xb900_0003 | (lo << 10))
        words.append(0xd360_fc63)  // lsr x3, x3, #32
        words.append(0xb900_0003 | (hi << 10))
        endPredicate(skip)
        count += 1
        address &+= 4
        continue
      }
      if op & 0x0fc0_00f0 == 0x0000_0090 {  // MUL / MLA without flag updates.
        let destination = (op >> 16) & 15
        let accumulator = (op >> 12) & 15
        let rs = (op >> 8) & 15
        let rm = op & 15
        let accumulate = op & 0x0020_0000 != 0
        guard op & 0x0010_0000 == 0, destination != 15, rs != 15, rm != 15,
          accumulate ? accumulator != 15 : accumulator == 0
        else { break }
        let skip = predicate(condition)
        load(1, rm)
        load(2, rs)
        if accumulate { load(3, accumulator) }
        words.append(accumulate ? 0x1b02_0c23 : 0x1b02_7c23)
        words.append(0xb900_0003 | (destination << 10))
        endPredicate(skip)
        count += 1
        address &+= 4
        continue
      }
      let operation = (op >> 21) & 15
      let updatesFlags = op & 0x0010_0000 != 0
      let comparison = (8...11).contains(operation)
      let logical = operation < 2 || operation == 8 || operation == 9 || operation >= 12
      let rd = (op >> 12) & 15
      let rn = (op >> 16) & 15
      let rm = op & 15
      let byRegister = op & 0x0200_0010 == 0x10
      let rs = (op >> 8) & 15
      let supported =
        updatesFlags
        ? true
        : !comparison
      guard supported, rd != 15, !comparison || rd == 0,
        !byRegister || (op & 0x80 == 0 && rs != 15)
      else { break }
      if op & 0x0200_0000 == 0 && op & 0xff0 == 0x60 { break }
      let skip = predicate(condition)
      if rn == 15 { imm(1, address &+ 8) } else { load(1, rn) }
      if op & 0x0200_0000 != 0 {
        let rotate = (op >> 8) & 15
        let byte = op & 255
        let value = rotate == 0 ? byte : (byte >> (rotate * 2)) | (byte << (32 - rotate * 2))
        imm(2, value)
        if updatesFlags && logical && rotate != 0 {
          imm(5, value >> 31)
          words.append(0x3303_00a4)  // bfi w4, w5, #29, #1: shifter carry
        }
      } else {
        if rm == 15 { imm(2, address &+ (byRegister ? 12 : 8)) } else { load(2, rm) }
        let kind = (op >> 5) & 3
        let amount = (op >> 7) & 31
        if byRegister {
          load(5, rs)
          registerShift(kind, carry: updatesFlags && logical)
        } else {
          if updatesFlags && logical && (kind != 0 || amount != 0) {
            let bit = kind == 0 ? 32 - amount : (amount == 0 ? 31 : amount - 1)
            words.append(0x5300_0045 | (bit << 16) | (bit << 10))  // ubfx w5,w2,#bit,#1
            words.append(0x3303_00a4)
          }
          if kind != 0 && amount == 0 {  // LSR/ASR #32 and RRX require special treatment.

            if kind == 1 { imm(2, 0) } else { words.append(0x1300_7c42 | (31 << 16)) }
          } else if amount != 0 {
            if kind == 0 {
              words.append(0x5300_0042 | ((32 - amount) << 16) | ((31 - amount) << 10))
            } else if kind == 1 {
              words.append(0x5300_7c42 | (amount << 16))
            } else if kind == 2 {
              words.append(0x1300_7c42 | (amount << 16))
            } else {
              words.append(0x1382_0042 | (amount << 10))
            }
          }
        }
      }
      let native: UInt32
      switch operation {
      case 0, 8: native = 0x0a02_0023
      case 1, 9: native = 0x4a02_0023
      case 2, 10: native = 0x4b02_0023
      case 3: native = 0x4b01_0043
      case 4, 11: native = 0x0b02_0023
      case 5: native = 0x1a02_0023  // adc w3,w1,w2
      case 6: native = 0x5a02_0023  // sbc w3,w1,w2
      case 7: native = 0x5a01_0043  // sbc w3,w2,w1 (RSC)
      case 12: native = 0x2a02_0023
      case 13: native = 0x2a02_03e3
      case 14: native = 0x0a22_0023
      default: native = 0x2a22_03e3
      }
      words.append(native | (updatesFlags && !logical ? 0x2000_0000 : 0))
      if !comparison { words.append(0xb900_0003 | (rd << 10)) }
      if updatesFlags {
        if logical { words.append(0x6a03_007f) }  // tst w3,w3: derive N/Z from the result
        words.append(0xd53b_4205)  // mrs x5, NZCV
        // Logical instructions preserve V and use shifter C; arithmetic writes all NZCV.
        words.append(logical ? 0x3300_7485 : 0x3300_6c85)
        words.append(0x2a05_03e4)  // mov w4, w5; native NZCV remains available to predicates
        if logical { words.append(0xd51b_4204) }  // restore merged C/V for later predicates/ADC
      }
      endPredicate(skip)
      count += 1
      address &+= 4
    }
    guard count > 0 else {
      if !transientMemoryMiss { misses[cpu.pc] = generation }
      return nil
    }
    if !writesPC {
      imm(3, address)
      words.append(0xb900_3c03)
    }
    returnPrefix(count)
    for accessExit in accessExits {
      words[accessExit.branch] |= UInt32(words.count - accessExit.branch) << 5
      imm(3, accessExit.pc)
      words.append(0xb900_3c03)
      returnPrefix(accessExit.instructions)
    }
    if let region = accessRegion {
      // x8–x10 are caller-saved and otherwise unused by this leaf translator.
      // Inserting the shared prelude before all guest instructions preserves every
      // already-patched relative branch displacement, including the memory exits.
      var prelude = immediateWords(9, region.base) + immediateWords(10, UInt32(region.count - accessWidth))
      let pointer = UInt64(UInt(bitPattern: region.bytes))
      prelude.append(0xd280_0008 | UInt32(pointer & 65535) << 5)
      for half in 1..<4 {
        prelude.append(0xf280_0008 | UInt32(half) << 21 | UInt32((pointer >> (half * 16)) & 65535) << 5)
      }
      words.insert(contentsOf: prelude, at: 2)
    }
    let byteCount = words.count * 4
    if used + byteCount > capacity {
      // Native offsets are about to be reused, even on unchanged guest pages.
      // No fast-cache entry may retain a pointer into the previous arena contents.
      discardCodeCache()
    }
    pthread_jit_write_protect_np(0)
    words.withUnsafeBytes {
      code.advanced(by: used).copyMemory(from: $0.baseAddress!, byteCount: byteCount)
    }
    sys_icache_invalidate(code.advanced(by: used), byteCount)
    pthread_jit_write_protect_np(1)
    let block = Block(offset: used, instructions: count, generation: generation,
      checkedMemory: !accessExits.isEmpty)
    used += (byteCount + 15) & ~15
    compiledBlocks += 1
    blocks[cpu.pc] = block
    if block.checkedMemory {
      var variants = memoryVariants[cpu.pc, default: []].filter { $0.generation == generation }
      // Bound retained alternatives; every native variant still checks its mapping.
      if variants.count >= 4 { variants.removeFirst() }
      variants.append(block)
      memoryVariants[cpu.pc] = variants
    } else {
      memoryVariants.removeValue(forKey: cpu.pc)
    }
    return block
  }
}
