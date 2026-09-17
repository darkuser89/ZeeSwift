import Foundation

/// User-mode ARM/Thumb integer execution. No Zeebo firmware, MMU or kernel emulation.
final class ARMCPU {
  let memory: GuestMemory
  let r: UnsafeMutablePointer<UInt32>
  var cpsr: UInt32 = 0x10
  var count: UInt64 = 0
  private struct TraceEntry {
    var pc: UInt32 = 0
    var instruction: UInt32 = 0
    var thumb = false
    var registers = SIMD4<UInt32>(repeating: 0)
  }
  private var traceEntries = [TraceEntry](repeating: TraceEntry(), count: 64)
  private var traceIndex = 0
  private var traceCount = 0
  var trace: [String] {
    (0..<traceCount).map { offset in
      let entry = traceEntries[(traceIndex - traceCount + offset + 64) % 64]
      return
        "\(entry.pc.hex) \(entry.thumb ? "T" : "A") \(entry.instruction.hex) r0=\(entry.registers.x.hex) r1=\(entry.registers.y.hex) r2=\(entry.registers.z.hex) r3=\(entry.registers.w.hex)"
    }
  }
  var tracing = false
  private let trapRange: ClosedRange<UInt32>
  var trap: ((ARMCPU) throws -> Bool)?
  var supervisorCall: ((ARMCPU, UInt32) throws -> Bool)?
  var thumb: Bool {
    get { cpsr & 0x20 != 0 }
    set { cpsr = newValue ? cpsr | 0x20 : cpsr & ~0x20 }
  }
  var pc: UInt32 {
    get { r[15] }
    set { r[15] = newValue }
  }
  var n: Bool { cpsr & 0x8000_0000 != 0 }
  var z: Bool { cpsr & 0x4000_0000 != 0 }
  var c: Bool { cpsr & 0x2000_0000 != 0 }
  var v: Bool { cpsr & 0x1000_0000 != 0 }
  init(memory: GuestMemory, trapRange: ClosedRange<UInt32> = 0...UInt32.max) {
    self.memory = memory
    self.trapRange = trapRange
    r = .allocate(capacity: 16)
    r.initialize(repeating: 0, count: 16)
  }
  deinit { r.deallocate() }
  func reg(_ i: Int) -> UInt32 { i == 15 ? pc &+ (thumb ? 4 : 8) : r[i] }
  func branch(_ address: UInt32, exchange: Bool = true) {
    if exchange { thumb = address & 1 != 0 }
    pc = address & (thumb ? ~UInt32(1) : ~UInt32(3))
  }
  func condition(_ code: UInt32) -> Bool {
    switch code {
    case 0: return z
    case 1: return !z
    case 2: return c
    case 3: return !c
    case 4: return n
    case 5: return !n
    case 6: return v
    case 7: return !v
    case 8: return c && !z
    case 9: return !c || z
    case 10: return n == v
    case 11: return n != v
    case 12: return !z && n == v
    case 13: return z || n != v
    case 14: return true
    default: return false
    }
  }
  func nz(_ value: UInt32) {
    cpsr = (cpsr & 0x3fff_ffff) | (value & 0x8000_0000) | (value == 0 ? 0x4000_0000 : 0)
  }
  func carry(_ value: Bool) { cpsr = value ? cpsr | 0x2000_0000 : cpsr & ~0x2000_0000 }
  func arithmetic(_ a: UInt32, _ b: UInt32, _ cin: UInt32, flags: Bool) -> UInt32 {
    let wide = UInt64(a) + UInt64(b) + UInt64(cin)
    let result = UInt32(truncatingIfNeeded: wide)
    if flags {
      nz(result)
      carry(wide >> 32 != 0)
      let overflow = (~(a ^ b) & (a ^ result)) & 0x8000_0000 != 0
      cpsr = overflow ? cpsr | 0x1000_0000 : cpsr & ~0x1000_0000
    }
    return result
  }
  func shift(_ value: UInt32, type: UInt32, amount: Int, immediate: Bool) -> (UInt32, Bool) {
    var s = amount
    if s == 0 {
      if !immediate || type == 0 { return (value, c) }
      if type == 3 { return ((c ? 0x8000_0000 : 0) | value >> 1, value & 1 != 0) }
      s = 32
    }
    switch type {
    case 0:
      return s < 32 ? (value << s, value & (1 << (32 - s)) != 0) : (0, s == 32 && value & 1 != 0)
    case 1:
      return s < 32 ? (value >> s, value & (1 << (s - 1)) != 0) : (0, s == 32 && value >> 31 != 0)
    case 2:
      return (
        UInt32(bitPattern: Int32(bitPattern: value) >> min(s, 31)),
        value & (1 << min(s - 1, 31)) != 0
      )
    default:
      let q = s & 31
      let out = q == 0 ? value : (value >> q) | (value << (32 - q))
      return (out, out >> 31 != 0)
    }
  }
  func step() throws {
    // Ordinary guest instructions must not enter the host callback merely to
    // discover that their PC is outside the runtime's synthetic HLE addresses.
    if trapRange.contains(pc), try trap?(self) == true {
      count &+= 1
      return
    }
    if tracing {
      traceEntries[traceIndex] = TraceEntry(
        pc: pc, instruction: try thumb ? memory.read16(pc) : memory.read32(pc), thumb: thumb,
        registers: SIMD4(r[0], r[1], r[2], r[3]))
      traceIndex = (traceIndex + 1) % 64
      traceCount = min(64, traceCount + 1)
    }
    if thumb {
      try stepThumb()
      count &+= 1
      return
    }
    let op = try memory.read32(pc)
    let oldPC = pc
    if op >> 28 == 15 {
      if op & 0xff70_f000 == 0xf550_f000
        || (op & 0xff70_f010 == 0xf750_f000 && op & 15 != 15) {
        // PLD is an optional cache hint, not a load. It must not dereference
        // an unmapped guest address, write back a base register or change flags.
        pc &+= 4
        count &+= 1
        return
      }
      if op & 0xfe00_0000 == 0xfa00_0000 {
        r[14] = pc &+ 4
        let d = UInt32(bitPattern: Int32(bitPattern: op << 8) >> 6) | ((op >> 23) & 2)
        branch(pc &+ 8 &+ d | 1)
        count &+= 1
        return
      }
      throw EmulationError.instruction(pc, op, false)
    }
    guard condition(op >> 28) else {
      pc &+= 4
      count &+= 1
      return
    }
    let rd = Int((op >> 12) & 15)
    let rn = Int((op >> 16) & 15)
    let rm = Int(op & 15)
    var wrotePC = false
    if op & 0x0fff_fff0 == 0x012f_ff10 || op & 0x0fff_fff0 == 0x012f_ff30 {
      let target = reg(rm)
      if op & 0x20 != 0 { r[14] = pc &+ 4 }
      branch(target)
      wrotePC = true
    } else if op & 0x0fff_0ff0 == 0x016f_0f10 {
      r[rd] = UInt32(reg(rm).leadingZeroBitCount)
    } else if op & 0x0fbf_0fff == 0x010f_0000 {
      r[rd] = cpsr
    } else if op & 0x0db0_f000 == 0x0120_f000 {
      let value: UInt32
      if op & 0x0200_0000 != 0 {
        value = shift(op & 255, type: 3, amount: Int((op >> 8) & 15) * 2, immediate: false).0
      } else {
        value = reg(rm)
      }
      if op & 0x0008_0000 != 0 { cpsr = (cpsr & 0x07ff_ffff) | (value & 0xf800_0000) }
    } else if op & 0x0f90_0090 == 0x0100_0080 {
      // ARMv5TE signed halfword DSP multiplies occupy the miscellaneous, not ALU, space.
      let rs = Int((op >> 8) & 15)
      let kind = (op >> 21) & 3
      let word = kind == 1
      let accumulate = kind == 0 || (word && op & 0x20 == 0)
      guard rn != 15, rm != 15, rs != 15,
        kind == 2 ? (rd != 15 && rd != rn) : (accumulate ? rd != 15 : rd == 0)
      else { throw EmulationError.instruction(pc, op, false) }
      // Snapshot all inputs before either destination is written (registers may alias).
      let a = word ? Int64(Int32(bitPattern: r[rm]))
        : Int64(Int16(truncatingIfNeeded: r[rm] >> (op & 0x20 == 0 ? 0 : 16)))
      let b = Int64(Int16(truncatingIfNeeded: r[rs] >> (op & 0x40 == 0 ? 0 : 16)))
      let product = (a * b) >> (word ? 16 : 0)
      if kind == 2 {  // SMLALxy: signed 16 × 16, modulo-64-bit accumulation; no flags.
        let initial = UInt64(r[rd]) | UInt64(r[rn]) << 32
        let result = initial &+ UInt64(bitPattern: product)
        r[rd] = UInt32(truncatingIfNeeded: result)
        r[rn] = UInt32(result >> 32)
      } else {
        let result = product + (accumulate ? Int64(Int32(bitPattern: r[rd])) : 0)
        r[rn] = UInt32(truncatingIfNeeded: result)
        if accumulate && (result < Int64(Int32.min) || result > Int64(Int32.max)) {
          cpsr |= 0x0800_0000  // Sticky Q; NZCV is preserved, even on overflow.
        }
      }
    } else if op & 0x0f80_00f0 == 0x0080_0090 {
      let hi = rn
      let lo = rd
      let a = reg(rm)
      let b = reg(Int((op >> 8) & 15))
      var out =
        op & 0x0040_0000 != 0
        ? UInt64(bitPattern: Int64(Int32(bitPattern: a)) * Int64(Int32(bitPattern: b)))
        : UInt64(a) * UInt64(b)
      if op & 0x0020_0000 != 0 { out &+= UInt64(r[lo]) | UInt64(r[hi]) << 32 }
      r[lo] = UInt32(truncatingIfNeeded: out)
      r[hi] = UInt32(out >> 32)
      if op & 0x0010_0000 != 0 {
        cpsr = (cpsr & 0x3fff_ffff) | (r[hi] & 0x8000_0000) | (out == 0 ? 0x4000_0000 : 0)
      }
    } else if op & 0x0fc0_00f0 == 0x0000_0090 {
      var out = reg(rm) &* reg(Int((op >> 8) & 15))
      if op & 0x0020_0000 != 0 { out &+= r[rd] }
      r[rn] = out
      if op & 0x0010_0000 != 0 { nz(out) }
    } else if op & 0x0fb0_0ff0 == 0x0100_0090 {
      let a = reg(rn)
      let b = reg(rm)
      if op & 0x0040_0000 != 0 {
        r[rd] = try memory.read8(a)
        try memory.write8(a, b)
      } else {
        r[rd] = try memory.read32(a)
        try memory.write32(a, b)
      }
    } else if op & 0x0e00_0090 == 0x0000_0090 {
      let offset = op & 0x0040_0000 != 0 ? ((op >> 4) & 0xf0) | (op & 15) : reg(rm)
      let base = reg(rn)
      let adjusted = op & 0x0080_0000 != 0 ? base &+ offset : base &- offset
      let a = op & 0x0100_0000 != 0 ? adjusted : base
      let kind = (op >> 5) & 3
      if op & 0x0010_0000 != 0 {
        switch kind {
        case 1: r[rd] = try memory.read16(a)
        case 2: r[rd] = UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: try memory.read8(a))))
        case 3: r[rd] = UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: try memory.read16(a))))
        default: throw EmulationError.instruction(pc, op, false)
        }
      } else if kind == 1 {
        try memory.write16(a, reg(rd))
      } else if kind == 2 || kind == 3 {
        // A32 LDRD / STRD encode the double transfer with L=0, S=1.
        let immediate = op & 0x0040_0000 != 0
        let indexed = op & 0x0100_0000 != 0
        let writeback = !indexed || op & 0x0020_0000 != 0
        guard rd.isMultiple(of: 2), rd <= 12,
          indexed || op & 0x0020_0000 == 0,
          !writeback || (rn != 15 && rn != rd && rn != rd + 1),
          rn != 15 || (kind == 2 && immediate && indexed && !writeback),
          immediate || (rm != 15 && (kind != 2 || (rm != rd && rm != rd + 1)))
        else { throw EmulationError.instruction(pc, op, false) }
        // ARM11 permits word-aligned double transfers; never accept byte alignment.
        guard a & 3 == 0 else { throw EmulationError.memory(a, 8) }
        _ = try memory.region(a, 8)
        if kind == 2 {
          let low = try memory.read32(a)
          let high = try memory.read32(a + 4)
          r[rd] = low
          r[rd + 1] = high
        } else {
          let low = r[rd]
          let high = r[rd + 1]
          try memory.write32(a, low)
          try memory.write32(a + 4, high)
        }
      } else {
        throw EmulationError.instruction(pc, op, false)
      }
      if op & 0x0100_0000 == 0 || op & 0x0020_0000 != 0 { r[rn] = adjusted }
    } else if op & 0x0c00_0000 == 0 {
      // TST/TEQ/CMP/CMN require S=1. S=0 here is a different instruction family.
      guard op & 0x0190_0000 != 0x0100_0000 else {
        throw EmulationError.instruction(pc, op, false)
      }
      let second: (UInt32, Bool)
      if op & 0x0200_0000 != 0 {
        second = shift(op & 255, type: 3, amount: Int((op >> 8) & 15) * 2, immediate: false)
      } else {
        let byReg = op & 0x10 != 0
        let amount = byReg ? Int(reg(Int((op >> 8) & 15)) & 255) : Int((op >> 7) & 31)
        second = shift(
          reg(rm) &+ (byReg && rm == 15 ? 4 : 0), type: (op >> 5) & 3, amount: amount,
          immediate: !byReg)
      }
      let a = reg(rn)
      let b = second.0
      let code = (op >> 21) & 15
      let flags = op & 0x0010_0000 != 0
      var result: UInt32 = 0
      var logical = false
      var write = true
      switch code {
      case 0, 8:
        result = a & b
        logical = true
        write = code != 8
      case 1, 9:
        result = a ^ b
        logical = true
        write = code != 9
      case 2, 10:
        result = arithmetic(a, ~b, 1, flags: flags)
        write = code != 10
      case 3: result = arithmetic(b, ~a, 1, flags: flags)
      case 4, 11:
        result = arithmetic(a, b, 0, flags: flags)
        write = code != 11
      case 5: result = arithmetic(a, b, c ? 1 : 0, flags: flags)
      case 6: result = arithmetic(a, ~b, c ? 1 : 0, flags: flags)
      case 7: result = arithmetic(b, ~a, c ? 1 : 0, flags: flags)
      case 12:
        result = a | b
        logical = true
      case 13:
        result = b
        logical = true
      case 14:
        result = a & ~b
        logical = true
      case 15:
        result = ~b
        logical = true
      default: break
      }
      if flags && logical {
        nz(result)
        carry(second.1)
      }
      if write {
        if rd == 15 {
          if flags { throw EmulationError.unsupported("ARM exception return") }
          branch(result, exchange: false)
          wrotePC = true
        } else {
          r[rd] = result
        }
      }
    } else if op & 0x0ff0_0030 == 0x0680_0010 {
      // ARMv6 PKHBT/PKHTB, including ASR #32 encoded as an immediate of zero.
      guard rd != 15, rn != 15, rm != 15 else {
        throw EmulationError.instruction(pc, op, false)
      }
      let a = r[rn], b = r[rm], amount = Int((op >> 7) & 31)
      if op & 0x40 == 0 {
        r[rd] = (a & 0xffff) | ((b << amount) & 0xffff0000)
      } else {
        let shifted = UInt32(bitPattern: Int32(bitPattern: b) >> (amount == 0 ? 31 : amount))
        r[rd] = (a & 0xffff0000) | (shifted & 0xffff)
      }
    } else if op & 0x0ff0_0ff0 == 0x06a0_0f30 || op & 0x0ff0_0ff0 == 0x06e0_0f30 {
      // ARMv6 SSAT16/USAT16: both inputs are signed halfwords. Saturation is
      // independent per lane and sets sticky Q; NZCV and GE are preserved.
      guard rd != 15, rm != 15 else { throw EmulationError.instruction(pc, op, false) }
      let unsigned = op & 0x0040_0000 != 0
      let width = Int((op >> 16) & 15) + (unsigned ? 0 : 1)
      let minimum: Int32 = unsigned ? 0 : -(1 << (width - 1))
      let maximum: Int32 = (1 << (unsigned ? width : width - 1)) - 1
      let input = reg(rm)
      var result: UInt32 = 0
      for shift in [0, 16] {
        let value = Int32(Int16(truncatingIfNeeded: input >> shift))
        let saturated = min(maximum, max(minimum, value))
        if saturated != value { cpsr |= 0x0800_0000 }
        result |= (UInt32(bitPattern: saturated) & 0xffff) << shift
      }
      r[rd] = result
    } else if op & 0x0f80_03f0 == 0x0680_0070 {
      // ARMv6 extend/extend-and-add, including independent byte-to-halfword lanes.
      // These occupy the media encoding space, not register-offset LDR/STR.
      let kind = (op >> 20) & 7
      guard rd != 15, rm != 15, kind != 1, kind != 5 else {
        throw EmulationError.instruction(pc, op, false)
      }
      let rotation = Int((op >> 10) & 3) * 8
      let value = reg(rm)
      let rotated = rotation == 0 ? value : (value >> rotation) | (value << (32 - rotation))
      let signed = kind & 4 == 0
      let addend = rn == 15 ? 0 : reg(rn)
      func byte(_ value: UInt32) -> UInt32 {
        signed ? UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: value))) : value & 255
      }
      if kind & 3 == 0 {
        let low = ((addend & 0xffff) &+ byte(rotated)) & 0xffff
        let high = ((addend >> 16) &+ byte(rotated >> 16)) & 0xffff
        r[rd] = low | (high << 16)
      } else {
        let extended: UInt32
        if kind & 3 == 2 {
          extended = byte(rotated)
        } else {
          extended =
            signed
            ? UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: rotated))) : rotated & 0xffff
        }
        r[rd] = addend &+ extended
      }
    } else if op & 0x0fff_0ff0 == 0x06bf_0f30
      || op & 0x0fff_0ff0 == 0x06bf_0fb0
      || op & 0x0fff_0ff0 == 0x06ff_0fb0
    {
      guard rd != 15, rm != 15 else { throw EmulationError.instruction(pc, op, false) }
      let value = reg(rm)
      if op & 0x80 == 0 {
        r[rd] = value.byteSwapped
      } else {
        let swapped = ((value & 0x00ff_00ff) << 8) | ((value & 0xff00_ff00) >> 8)
        r[rd] =
          op & 0x0040_0000 == 0
          ? swapped : UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: swapped)))
      }
    } else if op & 0x0e00_0010 == 0x0600_0010 {
      // Unsupported media instructions must not silently read/write guest memory.
      throw EmulationError.instruction(pc, op, false)
    } else if op & 0x0c00_0000 == 0x0400_0000 {
      let offset =
        op & 0x0200_0000 == 0
        ? op & 4095
        : shift(reg(rm), type: (op >> 5) & 3, amount: Int((op >> 7) & 31), immediate: true).0
      let base = reg(rn)
      let adjusted = op & 0x0080_0000 != 0 ? base &+ offset : base &- offset
      let a = op & 0x0100_0000 != 0 ? adjusted : base
      let byte = op & 0x0040_0000 != 0
      if op & 0x0010_0000 != 0 {
        let value = try byte ? memory.read8(a) : memory.read32(a)
        if rd == 15 {
          branch(value)
          wrotePC = true
        } else {
          r[rd] = value
        }
      } else {
        let value = rd == 15 ? pc &+ 12 : r[rd]
        if byte { try memory.write8(a, value) } else { try memory.write32(a, value) }
      }
      if op & 0x0100_0000 == 0 || op & 0x0020_0000 != 0 { r[rn] = adjusted }
    } else if op & 0x0e00_0000 == 0x0800_0000 {
      guard op & 0x0040_0000 == 0, op & 65535 != 0 else {
        throw EmulationError.instruction(pc, op, false)
      }
      var registers = op & 0xffff
      let byteCount = UInt32(registers.nonzeroBitCount * 4)
      let base = reg(rn)
      let up = op & 0x0080_0000 != 0
      let pre = op & 0x0100_0000 != 0
      var a = up ? base &+ (pre ? 4 : 0) : base &- byteCount &+ (pre ? 0 : 4)
      while registers != 0 {
        let i = registers.trailingZeroBitCount
        registers &= registers - 1
        if op & 0x0010_0000 != 0 {
          let value = try memory.read32(a)
          if i == 15 {
            branch(value)
            wrotePC = true
          } else {
            r[i] = value
          }
        } else {
          try memory.write32(a, i == 15 ? oldPC &+ 12 : r[i])
        }
        a &+= 4
      }
      if op & 0x0020_0000 != 0 {
        r[rn] = up ? base &+ byteCount : base &- byteCount
      }
    } else if op & 0x0e00_0000 == 0x0a00_0000 {
      if op & 0x0100_0000 != 0 { r[14] = pc &+ 4 }
      pc = pc &+ 8 &+ UInt32(bitPattern: Int32(bitPattern: op << 8) >> 6)
      wrotePC = true
    } else if op & 0x0f00_0000 == 0x0f00_0000, let supervisorCall,
      try supervisorCall(self, op & 0x00ff_ffff) {
      // A handled diagnostic SVC returns to the next guest instruction.
    } else {
      throw EmulationError.instruction(pc, op, false)
    }
    if !wrotePC { pc = oldPC &+ 4 }
    count &+= 1
  }
}
