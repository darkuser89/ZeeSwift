import Foundation

/// BREW class preferences are separate from the guest filesystem. A class ID
/// shares one versioned record across applications using the same save root.
final class BREWPreferenceStore {
  struct Record: Codable { let version: UInt16; let data: Data }
  let root: URL?
  private var transient: [UInt32: Record] = [:]
  init(root: URL?) { self.root = root?.appendingPathComponent("preferences") }

  func read(_ classID: UInt32) throws -> Record? {
    guard let root else { return transient[classID] }
    let url = root.appendingPathComponent(String(format: "%08x.plist", classID))
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 72 * 1024 else { throw EmulationError.invalid("BREW preference size") }
    let record = try PropertyListDecoder().decode(Record.self, from: Data(contentsOf: url))
    guard !record.data.isEmpty, record.data.count <= Int(UInt16.max) else {
      throw EmulationError.invalid("BREW preference data")
    }
    return record
  }

  func write(_ classID: UInt32, version: UInt16, data: Data) throws {
    guard !data.isEmpty, data.count <= Int(UInt16.max) else {
      throw EmulationError.invalid("BREW preference data")
    }
    let record = Record(version: version, data: data)
    guard let root else {
      guard transient[classID] != nil || transient.count < 1024 else {
        throw EmulationError.invalid("BREW preference limit")
      }
      transient[classID] = record
      return
    }
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let bytes = try encoder.encode(record)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try bytes.write(to: root.appendingPathComponent(String(format: "%08x.plist", classID)),
      options: .atomic)
  }
}

/// One atomic container per BREW application. Guest paths are dictionary keys, never host paths.
final class GameSaveStore {
  static let capacity = 128 * 1024 * 1024
  static let maximumFileSize = 16 * 1024 * 1024
  let url: URL
  private(set) var files: [String: Data]
  private(set) var directories: Set<String> = []
  private(set) var removedPaths: Set<String> = []
  private struct Container: Codable {
    let version: Int
    let files: [String: Data]
    let directories: Set<String>
    let removedPaths: Set<String>
  }
  static func parent(_ path: String) -> String {
    if path == "fs:/" { return "" }
    if path.hasPrefix("fs:/"), !path.dropFirst(4).contains("/") { return "fs:/" }
    return path.lastIndex(of: "/").map { String(path[..<$0]) } ?? ""
  }
  static func parents<S: Sequence>(of names: S) -> Set<String> where S.Element == String {
    var result = Set<String>()
    for name in names {
      var current = parent(name)
      while !current.isEmpty && current != "fs:/" {
        result.insert(current)
        current = parent(current)
      }
    }
    return result
  }
  static func path(_ input: String, allowRoot: Bool = false) throws -> String {
    var path = input.replacingOccurrences(of: "\\", with: "/")
    if path.hasPrefix("fs:/~/") { path.removeFirst(6) }
    else if path.hasPrefix("fs:/") {
      // Canonical virtual-root keys are distinct from old module-relative keys.
      // They never become host paths. Preserve case in the BREW 3.1 namespace.
      let suffix = String(path.dropFirst(4))
      let parts = suffix.split(separator:"/").filter { $0 != "." }
      guard !suffix.contains(":"), !suffix.contains("\0"), !parts.contains(".."),
        !parts.contains("~"), allowRoot || !parts.isEmpty, path.utf8.count <= 1024
      else { throw EmulationError.invalid("Guest file path") }
      return "fs:/" + parts.joined(separator:"/")
    }
    // Legacy BREW paths are rooted in this app's module, never the host filesystem.
    while path.hasPrefix("/") { path.removeFirst() }
    let parts = path.split(separator: "/").filter { $0 != "." }
    guard !path.contains(":"), !path.contains("\0"),
      !parts.contains(".."), allowRoot || !parts.isEmpty, path.utf8.count <= 1024
    else { throw EmulationError.invalid("Guest file path") }
    return parts.joined(separator: "/").lowercased()
  }
  init(root: URL, classID: UInt32) throws {
    url = root.appendingPathComponent(String(format: "%08x.plist", classID))
    if FileManager.default.fileExists(atPath: url.path) {
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size <= Self.capacity + 8 * 1024 * 1024 else {
        throw EmulationError.invalid("Save-game container too large")
      }
      let data = try Data(contentsOf: url)
      let decoder = PropertyListDecoder()
      if let legacy = try? decoder.decode([String: Data].self, from: data) {
        files = legacy
        directories = Self.parents(of: legacy.keys)
      } else {
        let container = try decoder.decode(Container.self, from: data)
        guard container.version == 1 else { throw EmulationError.invalid("Save-game version") }
        files = container.files
        directories = container.directories
        removedPaths = container.removedPaths
      }
      try Self.validate(files: files, directories: directories, removedPaths: removedPaths)
    } else {
      files = [:]
    }
  }
  static func applicationStore(classID: UInt32) throws -> GameSaveStore {
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    return try GameSaveStore(
      root: support.appendingPathComponent("ZeeSwift/Saves"), classID: classID)
  }
  static func validate(files: [String: Data], directories: Set<String>, removedPaths: Set<String>)
    throws
  {
    guard files.count <= 1024, directories.count <= 1024, removedPaths.count <= 4096,
      files.values.reduce(0, { $0 + $1.count }) <= capacity
    else {
      throw EmulationError.invalid("Save-game storage limit")
    }
    for (name, data) in files {
      guard try path(name) == name, data.count <= maximumFileSize else {
        throw EmulationError.invalid("Invalid save-game entry")
      }
    }
    for name in directories.union(removedPaths) {
      guard try path(name) == name else {
        throw EmulationError.invalid("Invalid save-game path")
      }
    }
    let requiredDirectories = Self.parents(of: Array(files.keys) + Array(directories))
    guard directories.isSuperset(of: requiredDirectories),
      directories.isDisjoint(with: files.keys)
    else {
      throw EmulationError.invalid("Conflicting save-game directories")
    }
  }
  func replace(_ updated: [String: Data]) throws {
    try replace(
      files: updated, directories: directories.union(Self.parents(of: updated.keys)),
      removedPaths: removedPaths)
  }
  func replace(files updated: [String: Data], directories: Set<String>, removedPaths: Set<String>)
    throws
  {
    try Self.validate(files: updated, directories: directories, removedPaths: removedPaths)
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let data = try encoder.encode(
      Container(version: 1, files: updated, directories: directories, removedPaths: removedPaths))
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
    files = updated
    self.directories = directories
    self.removedPaths = removedPaths
  }
}
