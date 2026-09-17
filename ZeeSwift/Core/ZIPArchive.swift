import Foundation

/// ZIP central-directory reader. Entry bytes remain in memory; no archive paths reach the host filesystem.
struct ZIPArchive {
  struct Entry {
    let name: String
    let method: UInt16
    let flags: UInt16
    let crc: UInt32
    let compressedSize: Int
    let size: Int
    let localOffset: Int
  }
  let data: Data
  let entries: [Entry]
  static let maxEntrySize = 128 * 1024 * 1024
  static let maxArchiveSize = 512 * 1024 * 1024

  init(url: URL) throws {
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= Self.maxArchiveSize else { throw EmulationError.invalid("ZIP too large") }
    try self.init(data: Data(contentsOf: url))
  }
  init(data: Data) throws {
    guard data.count >= 22, data.count <= Self.maxArchiveSize else {
      throw EmulationError.invalid("ZIP size")
    }
    var end: Int?
    for p in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
      if try data.u32(p) == 0x0605_4b50, p + 22 + Int(try data.u16(p + 20)) == data.count {
        end = p
        break
      }
    }
    guard let end else { throw EmulationError.invalid("ZIP directory missing") }
    guard try data.u16(end + 4) == 0, try data.u16(end + 6) == 0,
      try data.u16(end + 8) == data.u16(end + 10)
    else { throw EmulationError.unsupported("multipart ZIP file") }
    let count = Int(try data.u16(end + 10))
    let dirSize = Int(try data.u32(end + 12))
    var cursor = Int(try data.u32(end + 16))
    guard count < 65535, cursor <= end, dirSize == end - cursor else {
      throw EmulationError.invalid("ZIP64 or directory bounds")
    }
    var entries: [Entry] = []
    var names = Set<String>()
    var total = 0
    for _ in 0..<count {
      guard try data.u32(cursor) == 0x0201_4b50 else { throw EmulationError.invalid("ZIP entry") }
      let flags = try data.u16(cursor + 8)
      let method = try data.u16(cursor + 10)
      let crc = try data.u32(cursor + 16)
      let packed = Int(try data.u32(cursor + 20))
      let size = Int(try data.u32(cursor + 24))
      let n = Int(try data.u16(cursor + 28))
      let extra = Int(try data.u16(cursor + 30))
      let comment = Int(try data.u16(cursor + 32))
      let raw = try data.checked(cursor + 46, n)
      guard let name = String(data: raw, encoding: .utf8), !name.isEmpty,
        !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"), !name.contains("\0"),
        !name.split(separator: "/").contains(".."), !name.split(separator: "/").contains("."),
        names.insert(name.lowercased()).inserted
      else { throw EmulationError.invalid("Unsafe/ambiguous ZIP path") }
      guard flags & 1 == 0, method == 0 || method == 8 else {
        throw EmulationError.unsupported("ZIP encryption or compression \(method)")
      }
      guard size <= Self.maxEntrySize, packed <= data.count, total <= Self.maxArchiveSize - size
      else { throw EmulationError.invalid("ZIP decompression limit") }
      total += size
      let offset = Int(try data.u32(cursor + 42))
      guard offset < end - dirSize else { throw EmulationError.invalid("ZIP data offset") }
      entries.append(
        Entry(
          name: name, method: method, flags: flags, crc: crc, compressedSize: packed, size: size,
          localOffset: offset))
      cursor += 46 + n + extra + comment
      guard cursor <= end else { throw EmulationError.invalid("ZIP entry bounds") }
    }
    guard cursor == end else { throw EmulationError.invalid("ZIP directory length") }
    self.data = data
    self.entries = entries
  }
  func read(_ entry: Entry) throws -> Data {
    let o = entry.localOffset
    guard try data.u32(o) == 0x0403_4b50, try data.u16(o + 8) == entry.method,
      try data.u16(o + 6) == entry.flags
    else { throw EmulationError.invalid("Local ZIP header") }
    let n = Int(try data.u16(o + 26))
    let x = Int(try data.u16(o + 28))
    guard String(data: try data.checked(o + 30, n), encoding: .utf8) == entry.name else {
      throw EmulationError.invalid("ZIP name mismatch")
    }
    let input = try data.checked(o + 30 + n + x, entry.compressedSize)
    var output: Data
    if entry.method == 0 {
      guard input.count == entry.size else { throw EmulationError.invalid("ZIP file size") }
      output = input
    } else {
      output = Data(count: max(1, entry.size))
      var stream = z_stream()
      guard
        inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
      else { throw EmulationError.invalid("Deflate initialization") }
      defer { inflateEnd(&stream) }
      let status = output.withUnsafeMutableBytes { out in
        input.withUnsafeBytes { source in
          stream.next_in = UnsafeMutablePointer(
            mutating: source.bindMemory(to: Bytef.self).baseAddress)
          stream.avail_in = uInt(input.count)
          stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
          stream.avail_out = uInt(out.count)
          return inflate(&stream, Z_FINISH)
        }
      }
      guard status == Z_STREAM_END, stream.total_out == entry.size,
        stream.total_in == entry.compressedSize
      else { throw EmulationError.invalid("Deflate data") }
      output.count = entry.size
    }
    let checksum = output.withUnsafeBytes {
      crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))
    }
    guard UInt32(checksum) == entry.crc else {
      throw EmulationError.invalid("ZIP CRC: \(entry.name)")
    }
    return output
  }
}

/// Original resource-directory decoder inferred from the supplied MIF binaries.
/// Resource types and MIF IDs are defined by the original AEEShell.h / AEEMIF.h.
struct BREWResourceFile {
  struct Entry {
    let type: UInt16
    let firstID: UInt16
    let additionalIDs: Int
    let firstIndex: Int
  }
  let bytes: Data
  let entries: [Entry]
  private let offsets: [Int]
  init(_ bytes: Data) throws {
    guard bytes.count >= 32, try bytes.u16(0) == 0x11,
      try bytes.u16(2) == 1, try bytes.u16(4) == 1
    else { throw EmulationError.unsupported("MIF resource layout") }
    let count = Int(try bytes.u16(6))
    let directory = Int(try bytes.u32(8))
    let directoryBytes = Int(try bytes.u32(12))
    let table = Int(try bytes.u32(16))
    let resources = Int(try bytes.u32(20))
    let dataStart = Int(try bytes.u32(24))
    guard count <= 4096, resources <= 65535, directory >= 32,
      directoryBytes == count * 8, table == directory + directoryBytes,
      dataStart == table + (resources + 1) * 4, dataStart <= bytes.count
    else { throw EmulationError.invalid("MIF directory bounds") }
    let offsets = try (0...resources).map { Int(try bytes.u32(table + $0 * 4)) }
    guard offsets.first == dataStart, offsets.allSatisfy({ $0 >= dataStart && $0 <= bytes.count }),
      zip(offsets, offsets.dropFirst()).allSatisfy({ $0 <= $1 })
    else { throw EmulationError.invalid("MIF resource bounds") }
    var entries: [Entry] = []
    var seen = Set<UInt32>()
    for index in 0..<count {
      let p = directory + index * 8
      let type = try bytes.u16(p)
      let first = try bytes.u16(p + 2)
      let additional = Int(try bytes.u16(p + 4))
      let resource = Int(try bytes.u16(p + 6))
      guard Int(first) + additional <= 65535, resource + additional < resources else {
        throw EmulationError.invalid("MIF resource index")
      }
      for id in Int(first)...(Int(first) + additional) {
        guard seen.insert(UInt32(type) << 16 | UInt32(id)).inserted else {
          throw EmulationError.invalid("Duplicate MIF resource ID")
        }
      }
      entries.append(
        Entry(type: type, firstID: first, additionalIDs: additional, firstIndex: resource))
    }
    self.bytes = bytes
    self.entries = entries
    self.offsets = offsets
  }
  func resource(type: UInt16, id: UInt16) -> Data? {
    guard
      let entry = entries.first(where: {
        $0.type == type && Int(id) >= Int($0.firstID)
          && Int(id) <= Int($0.firstID) + $0.additionalIDs
      })
    else { return nil }
    let index = entry.firstIndex + Int(id - entry.firstID)
    return bytes.subdata(in: offsets[index]..<offsets[index + 1])
  }
  var appletClassID: UInt32? {
    guard let applet = resource(type: 0x5000, id: 2), applet.count >= 4,
      let id = try? applet.u32(0), id != 0
    else { return nil }
    return id
  }
  // Original AEEMIF.h, IDB_MIF_CLASSES: zero-terminated little-endian AEECLSIDs.
  func exportedClassIDs() throws -> [UInt32] {
    guard let data = resource(type: 0x5000, id: 1) else { return [] }
    guard data.count >= 4, data.count.isMultiple(of: 4) else {
      throw EmulationError.invalid("MIF class list")
    }
    let words = try stride(from: 0, to: data.count, by: 4).map { try data.u32($0) }
    guard let end = words.firstIndex(of: 0), words[end...].allSatisfy({ $0 == 0 }) else {
      throw EmulationError.invalid("MIF class list without a valid terminator")
    }
    return Array(words[..<end])
  }
  func appletResourceBase(classID: UInt32) -> UInt16? {
    guard let applets = resource(type: 0x5000, id: 2) else { return nil }
    // Original AEEAppInfo records: class, MIF pointer, resource base, remaining uint16 fields.
    for offset in stride(from: 0, to: applets.count, by: 20) where offset + 20 <= applets.count {
      if (try? applets.u32(offset)) == classID { return try? applets.u16(offset + 8) }
    }
    return nil
  }
  /// RESTYPE_STRING: encoding tags from AEEShell.h; resource bounds supply the length.
  func stringUnits(id: UInt16) -> [UInt16]? {
    guard let data = resource(type: 1, id: id), let encoding = data.first else { return nil }
    let units: [UInt16]
    if data.starts(with: [0xff, 0xfe]) {
      guard data.count.isMultiple(of: 2) else { return nil }
      units = stride(from: 2, to: data.count, by: 2).map {
        UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8
      }
    } else if encoding == 3 {
      units = data.dropFirst().map { UInt16($0) }
    } else if encoding == 2, let text = String(data: data.dropFirst(), encoding: .utf8) {
      units = Array(text.utf16)
    } else {
      return nil
    }
    return Array(units.prefix { $0 != 0 })
  }
}

struct GamePackage {
  struct BundledModule {
    let path: String
    let bytes: Data
  }
  let url: URL
  let title: String
  let modulePath: String
  let module: Data
  let archive: ZIPArchive
  let format: String
  let classID: UInt32
  let resources: BREWResourceFile
  let classModulePaths: [UInt32: String]
  init(url: URL) throws {
    let zip = try ZIPArchive(url: url)
    let mods = zip.entries.filter { $0.name.lowercased().hasSuffix(".mod") }
    let manifests = try zip.entries.filter { $0.name.lowercased().hasSuffix(".mif") }.map {
      ($0, try BREWResourceFile(zip.read($0)))
    }
    let applets = manifests.filter { $0.1.appletClassID != nil }
    guard applets.count == 1, let manifest = applets.first else {
      throw EmulationError.unsupported("No unambiguous MIF applet descriptor")
    }
    var classModules: [UInt32: String] = [:]
    for (mifEntry, mif) in manifests {
      let classes = try mif.exportedClassIDs()
      guard !classes.isEmpty else { continue }
      let stem = ((mifEntry.name as NSString).lastPathComponent as NSString).deletingPathExtension
      let candidates = mods.filter {
        (($0.name as NSString).deletingLastPathComponent as NSString).lastPathComponent == stem
      }
      guard candidates.count == 1 else {
        throw EmulationError.unsupported("No unambiguous library for MIF " + mifEntry.name)
      }
      for cls in classes {
        guard classModules[cls] == nil || classModules[cls] == candidates[0].name else {
          throw EmulationError.invalid("Ambiguous module class " + cls.hex)
        }
        classModules[cls] = candidates[0].name
      }
    }
    classModulePaths = classModules
    let entry: ZIPArchive.Entry
    if mods.count == 1 {
      entry = mods[0]
    } else {
      // Zeebo packages place each module in mod/<MIF-number>/, including dependency modules.
      let name = (manifest.0.name as NSString).lastPathComponent
      let stem = (name as NSString).deletingPathExtension
      let matching = mods.filter {
        (($0.name as NSString).deletingLastPathComponent as NSString).lastPathComponent == stem
      }
      guard matching.count == 1 else {
        throw EmulationError.unsupported("No unambiguous mapping from MIF to BREW module")
      }
      entry = matching[0]
    }
    let mod = try zip.read(entry)
    guard mod.count >= 64 else { throw EmulationError.invalid("BREW module too short") }
    let header = try mod.checked(8, 4) == Data("BREW".utf8)
    let first = try mod.u32(0)
    let branchTarget = Int64(8) + Int64(Int32(bitPattern: first << 8) >> 6)
    let branchEntry = first >> 24 == 0xea && branchTarget >= 0 && branchTarget + 4 <= mod.count
    guard header || first == 0xe52d_e004 || first & 0xffff_0000 == 0xe92d_0000 || branchEntry else {
      throw EmulationError.unsupported("Unknown MOD format")
    }
    resources = manifest.1
    classID = manifest.1.appletClassID!
    self.url = url
    archive = zip
    module = mod
    modulePath = entry.name
    title = url.deletingPathExtension().lastPathComponent
    format = header ? "BREW ARM with relocation header" : "BREW ARM (direct entry)"
  }
  func asset(_ path: String) throws -> Data? {
    let root = (modulePath as NSString).deletingLastPathComponent
    let components = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
    guard !components.contains("..") else { throw EmulationError.invalid("Guest file path") }
    let normalized = components.filter { $0 != "." }.joined(separator: "/")
    let candidates = [normalized, root + "/" + normalized]
    guard
      let e = archive.entries.first(where: { e in
        candidates.contains { $0.lowercased() == e.name.lowercased() }
      })
    else { return nil }
    return try archive.read(e)
  }
}
