import Foundation

final class GuestMemory {
  final class Region {
    let base: UInt32
    let count: Int
    let end: UInt64
    let bytes: UnsafeMutableRawPointer
    let executable: Bool
    // Stable storage also lets the memory owner's code lookup read a generation
    // without returning a retained Region or borrowing a mutable Swift Array.
    fileprivate let pageGenerations: UnsafeMutablePointer<UInt64>?
    private let pageCount: Int
    init(base: UInt32, count: Int, executable: Bool) {
      self.base = base
      self.count = count
      self.end = UInt64(base) + UInt64(count)
      self.executable = executable
      pageCount = executable ? (count + 4095) / 4096 : 0
      pageGenerations = executable ? .allocate(capacity: pageCount) : nil
      pageGenerations?.initialize(repeating: 0, count: pageCount)
      bytes = .allocate(byteCount: count, alignment: 16)
      bytes.initializeMemory(as: UInt8.self, repeating: 0, count: count)
    }
    deinit {
      pageGenerations?.deinitialize(count: pageCount)
      pageGenerations?.deallocate()
      bytes.deallocate()
    }
    func generation(at address: UInt32) -> UInt64 {
      precondition(executable && address >= base && UInt64(address) < end)
      return pageGenerations![Int(address - base) / 4096]
    }
    func codePageEnd(at address: UInt32) -> UInt64 {
      min(
        UInt64(base) + UInt64(count), UInt64(base) + UInt64((Int(address - base) / 4096 + 1) * 4096)
      )
    }
    func didWrite(_ address: UInt32, count: Int) {
      guard executable, count > 0 else { return }
      let start = Int(address - base) / 4096
      let end = (Int(address - base) + count - 1) / 4096
      for page in start...end { pageGenerations![page] &+= 1 }
    }
  }
  private(set) var regions: [Region] = []
  // The guest worker owns this memory. Mappings are append-only and never overlap.
  // Fixed storage avoids Array copy-on-write/exclusivity bookkeeping on every hit.
  // Slots retain Region objects; bounds are still checked for every access, including
  // accesses spanning pages or sharing a cache slot with another mapping.
  private let lookup = UnsafeMutablePointer<Region?>.allocate(capacity: 256)
  // Scalar loads need bytes and bounds, not an owned Region result on every hit.
  // `regions` retains each allocation for the complete GuestMemory lifetime;
  // mappings are append-only, so these cached pointers cannot become dangling.
  private struct ReadEntry {
    var base: UInt32 = 0
    var end: UInt64 = 0
    var bytes: UnsafeRawPointer?
  }
  private let readLookup = UnsafeMutablePointer<ReadEntry>.allocate(capacity: 256)
  private struct CodeEntry {
    var base: UInt32 = 0
    var end: UInt64 = 0
    var generations: UnsafePointer<UInt64>?
  }
  struct CodePage {
    let generation: UInt64
    let end: UInt64
  }
  private let codeLookup = UnsafeMutablePointer<CodeEntry>.allocate(capacity: 256)
  init() {
    lookup.initialize(repeating: nil, count: 256)
    readLookup.initialize(repeating: ReadEntry(), count: 256)
    codeLookup.initialize(repeating: CodeEntry(), count: 256)
  }
  deinit {
    codeLookup.deinitialize(count: 256)
    codeLookup.deallocate()
    readLookup.deinitialize(count: 256)
    readLookup.deallocate()
    lookup.deinitialize(count: 256)
    lookup.deallocate()
  }
  func map(_ base: UInt32, size: Int, executable: Bool = false) throws {
    guard size > 0, UInt64(base) + UInt64(size) <= 0x1_0000_0000,
      !regions.contains(where: {
        UInt64(base) < UInt64($0.base) + UInt64($0.count)
          && UInt64($0.base) < UInt64(base) + UInt64(size)
      })
    else { throw EmulationError.invalid("Overlapping memory region") }
    regions.append(Region(base: base, count: size, executable: executable))
  }
  func region(_ address: UInt32, _ size: Int) throws -> Region {
    guard size >= 0 else { throw EmulationError.memory(address, size) }
    let end = UInt64(address) + UInt64(size)
    let slot = Int(((address >> 12) ^ (address >> 20)) & 255)
    // A zero-length range at an adjacent boundary may match two regions. Preserve
    // insertion-order lookup in that case, as in the uncached implementation.
    if size > 0, let cached = lookup[slot], address >= cached.base, end <= cached.end {
      return cached
    }
    guard let region = regions.first(where: { address >= $0.base && end <= $0.end }) else {
      throw EmulationError.memory(address, size)
    }
    if size > 0 { lookup[slot] = region }
    return region
  }
  private func readPointer(_ address: UInt32, size: UInt32) throws -> UnsafeRawPointer {
    let slot = Int(((address >> 12) ^ (address >> 20)) & 255)
    let cached = readLookup[slot]
    if let bytes = cached.bytes, address >= cached.base,
      UInt64(address) + UInt64(size) <= cached.end {
      return bytes.advanced(by: Int(address - cached.base))
    }
    let region = try region(address, Int(size))
    readLookup[slot] = ReadEntry(base: region.base, end: region.end, bytes: UnsafeRawPointer(region.bytes))
    return UnsafeRawPointer(region.bytes.advanced(by: Int(address - region.base)))
  }
  // Four-byte instruction bounds are checked even on a hit. Generation values
  // are read live, never cached: writes must invalidate positive AND negative
  // JIT entries. The append-only regions own these stable counters and pointers.
  @inline(__always)
  func codePage(at address: UInt32) throws -> CodePage? {
    let slot = Int(((address >> 12) ^ (address >> 20)) & 255)
    var entry = codeLookup[slot]
    if address < entry.base || UInt64(address) + 4 > entry.end {
      let region = try region(address, 4)
      entry = CodeEntry(base: region.base, end: region.end,
        generations: region.pageGenerations.map { UnsafePointer($0) })
      codeLookup[slot] = entry
    }
    guard let generations = entry.generations else { return nil }
    let page = Int(address - entry.base) / 4096
    return CodePage(generation: generations[page],
      end: min(entry.end, UInt64(entry.base) + UInt64((page + 1) * 4096)))
  }
  func read8(_ a: UInt32) throws -> UInt32 {
    UInt32(try readPointer(a, size: 1).load(as: UInt8.self))
  }
  func read16(_ a: UInt32) throws -> UInt32 {
    UInt32(try readPointer(a, size: 2).loadUnaligned(as: UInt16.self).littleEndian)
  }
  func read32(_ a: UInt32) throws -> UInt32 {
    try readPointer(a, size: 4).loadUnaligned(as: UInt32.self).littleEndian
  }
  func write8(_ a: UInt32, _ v: UInt32) throws {
    let r = try region(a, 1)
    r.bytes.storeBytes(
      of: UInt8(truncatingIfNeeded: v), toByteOffset: Int(a - r.base), as: UInt8.self)
    r.didWrite(a, count: 1)
  }
  func write16(_ a: UInt32, _ v: UInt32) throws {
    let r = try region(a, 2)
    var w = UInt16(truncatingIfNeeded: v).littleEndian
    withUnsafeBytes(of: &w) {
      r.bytes.advanced(by: Int(a - r.base)).copyMemory(from: $0.baseAddress!, byteCount: 2)
    }
    r.didWrite(a, count: 2)
  }
  func write32(_ a: UInt32, _ v: UInt32) throws {
    let r = try region(a, 4)
    var w = v.littleEndian
    withUnsafeBytes(of: &w) {
      r.bytes.advanced(by: Int(a - r.base)).copyMemory(from: $0.baseAddress!, byteCount: 4)
    }
    r.didWrite(a, count: 4)
  }
  func write(_ a: UInt32, data: Data) throws {
    let r = try region(a, data.count)
    data.withUnsafeBytes {
      if let p = $0.baseAddress {
        r.bytes.advanced(by: Int(a - r.base)).copyMemory(from: p, byteCount: data.count)
      }
    }
    r.didWrite(a, count: data.count)
  }
  func data(_ a: UInt32, count: Int) throws -> Data {
    let r = try region(a, count)
    return Data(bytes: r.bytes.advanced(by: Int(a - r.base)), count: count)
  }
  func stringBytes(_ a: UInt32, limit: Int = 1_048_576) throws -> Data {
    var bytes: [UInt8] = []
    for i in 0..<limit {
      let c = try read8(a &+ UInt32(i))
      if c == 0 { return Data(bytes) }
      bytes.append(UInt8(c))
    }
    throw EmulationError.invalid("Guest string without terminator")
  }
  func string(_ a: UInt32, limit: Int = 4096) throws -> String {
    String(decoding: try stringBytes(a, limit: limit), as: UTF8.self)
  }
  /// A reversible one-scalar-per-byte bridge for the C formatter, not a charset conversion.
  func byteString(_ a: UInt32, limit: Int = 65536) throws -> String {
    String(String.UnicodeScalarView(try stringBytes(a, limit: limit).map { UnicodeScalar($0) }))
  }
}
