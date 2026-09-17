import Foundation

extension BREWRuntime {
  enum FileKind { case file, directory }
  final class FileManagerState {
    var references: UInt32 = 1
    var lastError: UInt32 = 0
    var enumeration: [String]?
    var enumerationIndex = 0
    var enumerationPrefix = ""
    var enumeratesDirectories = false
  }
  func createFileManager() throws -> UInt32 {
    let handle = try allocate(16)
    guard handle != 0 else { return 0 }
    try memory.write32(handle, memory.read32(fileManager))
    fileManagers[handle] = FileManagerState()
    return handle
  }
  func visibleChildren(of directory: String, directoriesOnly: Bool) -> [String] {
    let names = Set(mountedFiles.keys).union(mountedDirectories).union(savedFiles.keys).union(
      savedDirectories).union(absoluteFileAliases.keys)
    let kind: FileKind = directoriesOnly ? .directory : .file
    return names.filter {
      !$0.isEmpty && $0.hasPrefix("fs:/") == directory.hasPrefix("fs:/")
        && GameSaveStore.parent($0) == directory && fileKind(absoluteFileAliases[$0] ?? $0) == kind
    }.sorted()
  }
  // Legacy AEEFileInfo is 76 bytes on ARM: byte attribute, three padding bytes,
  // uint32 creation time, uint32 size, and 64 bytes for a NUL-terminated name.
  // Original creation timestamps are unavailable in these packages/saves and remain zero.
  func fileInfoBasename(_ path: String) -> String {
    let path = absoluteFileAliases[path] ?? path
    let sourceName = fileKind(path) != .directory ? mountedFiles[path]?.name : nil
    return (sourceName ?? path).split(separator: "/").last.map(String.init) ?? ""
  }
  func writeFileInfo(_ path: String, to output: UInt32, name: String? = nil) throws {
    let path = absoluteFileAliases[path] ?? path
    var info = Data(repeating: 0, count: 76)
    let directory = fileKind(path) == .directory
    info[0] = directory ? 2 : 0  // AEE_FA_DIR / AEE_FA_NORMAL; installed files support overlays.
    let size = directory ? 0 : (savedFiles[path]?.count ?? mountedFiles[path]?.size ?? 0)
    var little = UInt32(size).littleEndian
    withUnsafeBytes(of: &little) { info.replaceSubrange(8..<12, with: $0) }
    let name = name ?? fileInfoBasename(path)
    // The legacy structure cannot represent arbitrarily long names. Do not split UTF-8.
    var bytes = Array(name.utf8.prefix(63))
    while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
    info.replaceSubrange(12..<(12 + bytes.count), with: bytes)
    try memory.write(output, data: info)
  }
  func getFileInfo(_ path: String, output: UInt32) throws {
    guard output != 0 else {
      fileResult(14)
      return
    }
    guard fileKind(path) != nil else {
      fileResult(0x101)
      return
    }
    try writeFileInfo(path, to: output)
    fileResult(0)
  }
  // AEEFile.h ARM layout: 40-byte AEEFileInfoEx, with caller-owned optional
  // name, AECHAR description and class-list buffers. Preserve their pointers
  // and capacities and validate every write before changing any output.
  func getOpenFileInfoEx(_ path: String, size: Int, output: UInt32) throws {
    guard output != 0, try memory.read32(output) >= 40 else { fileResult(14); return }
    var info = try memory.data(output, count: 40)
    func word(_ offset: Int) -> UInt32 {
      (0..<4).reduce(0) { $0 | UInt32(info[offset + $1]) << ($1 * 8) }
    }
    let fields = [(word(16), Int32(bitPattern: word(20))), (word(24), Int32(bitPattern: word(28))), (word(32), Int32(bitPattern: word(36)))]
    guard fields.allSatisfy({ $0.1 >= 0 }) else { fileResult(14); return }
    var writes: [(UInt32, Data)] = []
    if fields[0].0 != 0 && fields[0].1 > 0 {
      var name = Array(fileInfoBasename(path).utf8.prefix(Int(fields[0].1) - 1))
      while String(bytes: name, encoding: .utf8) == nil { name.removeLast() }
      writes.append((fields[0].0, Data(name) + Data([0])))
    }
    if fields[1].0 != 0 && fields[1].1 >= 2 { writes.append((fields[1].0, Data([0, 0]))) }
    if fields[2].0 != 0 && fields[2].1 >= 4 {
      var cls = package.classID.littleEndian
      writes.append((fields[2].0, withUnsafeBytes(of: &cls) { Data($0) }))
    }
    for (pointer, data) in writes { _ = try memory.region(pointer, data.count) }
    info.replaceSubrange(4..<12, with: Data(repeating: 0, count: 8))
    var count = UInt32(size).littleEndian
    withUnsafeBytes(of: &count) { info.replaceSubrange(12..<16, with: $0) }
    try memory.write(output, data: info)
    for (pointer, data) in writes { try memory.write(pointer, data: data) }
    fileResult(0)
  }
  func initializeFileEnumeration(_ manager: FileManagerState) throws {
    manager.enumeration = nil
    manager.enumerationIndex = 0
    manager.enumerationPrefix = ""
    guard cpu.r[1] != 0 else {
      fileResult(0x103)
      return
    }
    let raw = try memory.string(cpu.r[1])
    guard let path = try? filePath(raw, allowRoot: true) else {
      fileResult(0x103)
      return
    }
    guard fileKind(path) == .directory else {
      fileResult(0x109)
      return
    }
    manager.enumeratesDirectories = cpu.r[2] != 0
    // EnumNext names are reopenable paths. Preserve the caller's validated prefix:
    // original game code also removes that prefix when copying an enumerated directory.
    let prefix = raw.replacingOccurrences(of: "\\", with: "/")
    manager.enumerationPrefix = prefix.isEmpty || prefix.hasSuffix("/") ? prefix : prefix + "/"
    manager.enumeration = visibleChildren(of: path, directoriesOnly: manager.enumeratesDirectories)
    log.append(
      "EnumInit: \(path.debugDescription), directories=\(manager.enumeratesDirectories), entries=\(manager.enumeration!.count)"
    )
    fileResult(0)
  }
  func nextFileInfo(_ manager: FileManagerState) throws {
    guard let entries = manager.enumeration else {
      fileError = 0x10a
      cpu.r[0] = 0
      return
    }
    guard cpu.r[1] != 0 else {
      fileError = 14
      cpu.r[0] = 0
      return
    }
    let kind: FileKind = manager.enumeratesDirectories ? .directory : .file
    while manager.enumerationIndex < entries.count {
      let path = entries[manager.enumerationIndex]
      // Deletions/type changes after EnumInit are skipped; new names need a new EnumInit.
      guard fileKind(path) == kind else {
        manager.enumerationIndex += 1
        continue
      }
      try writeFileInfo(path, to: cpu.r[1], name: manager.enumerationPrefix + fileInfoBasename(path))
      manager.enumerationIndex += 1
      fileError = 0
      cpu.r[0] = 1  // EnumNext is boolean, unlike GetInfo/EnumInit.
      return
    }
    fileError = 1  // The interface requires EFAILED even for normal enumeration exhaustion.
    cpu.r[0] = 0
  }

  // Mount metadata once. Directory tests never inflate ZIP data. Both historical
  // archive-qualified names and app-relative names resolve to one overlay key.
  func mountFiles() {
    for entry in package.archive.entries {
      // Archive entry names must already be confined; guest relative-path resolution
      // must not reinterpret malformed ZIP entries as module-relative siblings.
      guard !entry.name.contains(":"), (try? GameSaveStore.path(entry.name, allowRoot: true)) != nil,
        let path = try? filePath(entry.name, allowRoot: true) else { continue }
      if entry.name.hasSuffix("/") || path.isEmpty {
        mountedDirectories.insert(path)
      } else {
        let moduleRoot = (package.modulePath as NSString).deletingLastPathComponent.lowercased()
        if mountedFiles[path] == nil || entry.name.lowercased().hasPrefix(moduleRoot + "/") {
          mountedFiles[path] = entry
        }
      }
      // Publish archive metadata in the explicit device-root namespace too.
      // Current-module and legacy sibling aliases still share their old keys.
      if let absolute = try? GameSaveStore.path("fs:/" + entry.name, allowRoot:true) {
        absoluteFileAliases[absolute] = path
        mountedDirectories.formUnion(GameSaveStore.parents(of:[absolute]))
      }
    }
    mountedDirectories.formUnion(
      GameSaveStore.parents(of: Array(mountedFiles.keys) + Array(mountedDirectories)))
    mountedDirectories.insert("")
    mountedDirectories.insert("fs:/")
    // Zeeboids' original first-run code creates its database here without a
    // preceding MkDir. Model that installed platform directory, not its contents.
    // A persisted RmDir tombstone may hide it, as with the per-app udata folder.
    mountedDirectories.insert("fs:/zeeboiddata")
    // DD and RE4 create udata saves without first calling MkDir. Their ZIPs omit
    // this initially empty per-app user directory; the HLE launch environment provides it.
    // A persisted RmDir tombstone can still hide it on later launches.
    mountedDirectories.insert("udata")
    // The supplied Quake II module copies saves into save0...save14 without
    // creating those directories. Reconstruct its empty installation layout;
    // all save contents are still written by the original guest. This is inferred
    // from its copy routine and isolated save/load tests, not a firmware manifest.
    if package.classID == 0x0108_7c1c {
      mountedDirectories.insert("udata/save")
      for slot in 0...14 { mountedDirectories.insert("udata/save/save\(slot)") }
    }
  }
  func filePath(_ raw: String, allowRoot: Bool = false) throws -> String {
    let root = (package.modulePath as NSString).deletingLastPathComponent.lowercased()
    var qualified = raw.replacingOccurrences(of: "\\", with: "/")
    // AEEFile.h: fs:/~<clsid>/ names the directory of the module exporting
    // that class. Resolve aliases for this installed module from its MIF;
    // other applications still need module ACL support.
    if qualified.hasPrefix("fs:/~"), !qualified.hasPrefix("fs:/~/") {
      let suffix = qualified.dropFirst(5)
      let identifier = suffix.prefix(while: { $0 != "/" })
      let digits = identifier.lowercased()
      let classID = digits.hasPrefix("0x") ? UInt32(digits.dropFirst(2), radix: 16) : UInt32(digits)
      guard let classID,
        classID == package.classID || package.classModulePaths[classID]?.lowercased() == package.modulePath.lowercased()
      else { throw EmulationError.invalid("Unknown or inaccessible module class path") }
      let relative = String(suffix.dropFirst(identifier.count))
      qualified = "fs:/~/" + (relative.hasPrefix("/") ? String(relative.dropFirst()) : relative)
    }
    if qualified.hasPrefix("/") {
      // Legacy absolute names are rooted at the app directory. Parent steps
      // at that root stay there; they cannot select a sibling app or host path.
      // Boia Cross writes udata/trackinfo.txt and reopens /../udata/trackinfo.txt.
      guard qualified.utf8.count <= 1024, !qualified.contains(":"),
        !qualified.contains("\0") else { throw EmulationError.invalid("Guest file path") }
      var components: [String] = []
      for part in qualified.split(separator: "/") {
        if part == "." { continue }
        if part == ".." {
          if !components.isEmpty { components.removeLast() }
        } else { components.append(String(part)) }
      }
      qualified = components.joined(separator: "/")
    }
    if qualified.hasPrefix("fs:/"), !qualified.hasPrefix("fs:/~/") {
      let suffix = String(qualified.dropFirst(4))
      guard qualified.utf8.count <= 1024, !suffix.contains(":"), !suffix.contains("\0") else {
        throw EmulationError.invalid("Guest file path")
      }
      var components: [String] = []
      for part in suffix.split(separator:"/") {
        if part == "." { continue }
        if part == ".." {
          guard !components.isEmpty else { throw EmulationError.invalid("Guest file path") }
          components.removeLast()
        } else { components.append(String(part)) }
      }
      // System storage is not mounted or exposed by the game-only runtime.
      guard components.first != "sys", !components.contains("~") else { throw EmulationError.invalid("Guest file path") }
      let absolute = components.joined(separator:"/")
      if let alias = absoluteFileAliases["fs:/" + absolute] {
        guard allowRoot || !alias.isEmpty else { throw EmulationError.invalid("Guest file path") }
        return alias
      }
      if absolute == root || absolute.hasPrefix(root + "/") {
        return try filePath(absolute, allowRoot:allowRoot)
      }
      let moduleParent = (root as NSString).deletingLastPathComponent
      if !moduleParent.isEmpty && absolute.hasPrefix(moduleParent + "/") {
        return try GameSaveStore.path(absolute,allowRoot:allowRoot)
      }
      return try GameSaveStore.path("fs:/" + absolute,allowRoot:allowRoot)
    }
    // Both ordinary relative paths and fs:/~/ start at the module directory.
    // Parent components can reach shared assets elsewhere inside this ZIP, but
    // cannot escape the virtual archive root. No guest path becomes a host path.
    let explicitModuleRoot = qualified.hasPrefix("fs:/~/")
    let suffix = explicitModuleRoot ? String(qualified.dropFirst(6)) : qualified
    if (explicitModuleRoot || !qualified.hasPrefix("/")), suffix.split(separator: "/").contains("..") {
      guard suffix.utf8.count <= 1024, !suffix.contains(":"), !suffix.contains("\0") else {
        throw EmulationError.invalid("Guest file path")
      }
      var components = root.split(separator: "/").map(String.init)
      for part in suffix.split(separator: "/") {
        if part == "." { continue }
        if part == ".." {
          guard !components.isEmpty else { throw EmulationError.invalid("Guest file path") }
          components.removeLast()
        } else { components.append(String(part)) }
      }
      qualified = components.joined(separator: "/")
    }
    let path = try GameSaveStore.path(qualified, allowRoot: allowRoot)
    if !root.isEmpty && path == root {
      guard allowRoot else { throw EmulationError.invalid("Guest file path") }
      return ""
    }
    return !root.isEmpty && path.hasPrefix(root + "/")
      ? String(path.dropFirst(root.count + 1)) : path
  }
  func fileKind(_ path: String) -> FileKind? {
    if let alias = absoluteFileAliases[path], alias != path { return fileKind(alias) }
    if path.isEmpty || path == "fs:/" { return .directory }
    if savedFiles[path] != nil { return .file }
    if savedDirectories.contains(path) { return .directory }
    if removedPaths.contains(path) { return nil }
    if mountedFiles[path] != nil { return .file }
    return mountedDirectories.contains(path) ? .directory : nil
  }
  func normalizeSavedPaths() throws {
    var normalized: [String: Data] = [:]
    for (name, data) in savedFiles {
      let canonical = try filePath(name)
      if let other = normalized[canonical], other != data {
        throw EmulationError.invalid("Conflicting save-game aliases")
      }
      normalized[canonical] = data
    }
    let directories = try Set(savedDirectories.map { try filePath($0, allowRoot: true) })
      .subtracting([""])
    let removed = try Set(removedPaths.map { try filePath($0) })
    let parents = GameSaveStore.parents(of: Array(normalized.keys) + Array(directories))
    try GameSaveStore.validate(
      files: normalized, directories: directories.union(parents), removedPaths: removed)
    savedFiles = normalized
    savedDirectories = directories.union(parents)
    removedPaths = removed
  }
  func fileContents(_ path: String) throws -> Data? {
    let path = absoluteFileAliases[path] ?? path
    guard fileKind(path) == .file else { return nil }
    if let saved = savedFiles[path] { return saved }
    return try mountedFiles[path].map { try package.archive.read($0) }
  }
  func commitFiles(_ updated: [String: Data], directories: Set<String>, removed: Set<String>) throws
  {
    try GameSaveStore.validate(files: updated, directories: directories, removedPaths: removed)
    try saveStore?.replace(files: updated, directories: directories, removedPaths: removed)
    savedFiles = updated
    savedDirectories = directories
    removedPaths = removed
  }

  func fileSystemFree(total output: UInt32) throws -> UInt32 {
    // GETFSFREE and IFileMgr.GetFreeSpace describe the same writable app volume.
    // ZIP resources are read-only mounts; only committed save bytes occupy it.
    if output != 0 { try memory.write32(output, UInt32(GameSaveStore.capacity)) }
    let used = savedFiles.values.reduce(0) { $0 + $1.count }
    return UInt32(max(0, GameSaveStore.capacity - used))
  }
  private func fileResult(_ error: UInt32) {
    fileError = error
    cpu.r[0] = error == 0 ? 0 : 1
  }
  func fileStorageError(_ error: Error) -> UInt32 {
    log.append("Save-game change failed: \(error.localizedDescription)")
    if case EmulationError.invalid("Save-game storage limit") = error { return 0x106 }
    return 1
  }
  func renameFile() throws {
    guard cpu.r[1] != 0, cpu.r[2] != 0 else { fileResult(0x103); return }
    let sourceName = try memory.string(cpu.r[1]), destinationName = try memory.string(cpu.r[2])
    guard let source = try? filePath(sourceName), let destination = try? filePath(destinationName) else {
      fileResult(0x103); return
    }
    guard fileKind(source) == .file else { fileResult(fileKind(source) == nil ? 0x101:0x10a); return }
    guard !files.values.contains(where: { $0.name == source || $0.name == destination }) else {
      fileResult(0x107); return
    }
    if source == destination { fileResult(0); return }
    guard fileKind(destination) == nil else { fileResult(0x100); return }
    guard fileKind(GameSaveStore.parent(destination)) == .directory else { fileResult(0x109); return }
    guard let contents = try fileContents(source) else { fileResult(0x101); return }
    var updated = savedFiles, removed = removedPaths
    updated.removeValue(forKey:source); updated[destination] = contents
    if mountedFiles[source] != nil { removed.insert(source) }
    removed.remove(destination)
    do {
      try commitFiles(updated, directories:savedDirectories.union(GameSaveStore.parents(of:updated.keys)),removed:removed)
      log.append("File renamed: \(source) → \(destination)")
      fileResult(0)
    } catch { fileResult(fileStorageError(error)) }
  }
  func changeFileTree(_ operation: UInt32) throws {
    guard cpu.r[1] != 0 else {
      fileResult(0x103)
      return
    }
    let raw = try memory.string(cpu.r[1])
    guard let path = try? filePath(raw, allowRoot: true) else {
      fileResult(0x103)
      return
    }
    let kind = fileKind(path)
    var updatedFiles = savedFiles
    var directories = savedDirectories
    var removed = removedPaths
    switch operation {
    case 0x14:  // MkDir: repeated creation of an existing directory succeeds.
      if kind == .directory {
        fileResult(0)
        return
      }
      guard kind == nil else {
        fileResult(0x100)
        return
      }
      guard fileKind(GameSaveStore.parent(path)) == .directory else {
        fileResult(0x109)
        return
      }
      directories.insert(path)
      directories.formUnion(GameSaveStore.parents(of: [path]))
    case 0x18:  // Neither virtual root may be removed.
      guard !path.isEmpty && path != "fs:/" else {
        fileResult(0x10a)
        return
      }
      guard kind == .directory else {
        fileResult(kind == nil ? 0x109 : 0x10a)
        return
      }
      let names = Set(mountedFiles.keys).union(mountedDirectories).union(savedFiles.keys).union(
        directories).union(absoluteFileAliases.keys)
      guard !names.contains(where: { $0.hasPrefix(path + "/") && fileKind($0) != nil }) else {
        fileResult(0x102)
        return
      }
      directories.remove(path)
      if mountedDirectories.contains(path) { removed.insert(path) }
    case 0x10:  // Remove never mutates the source archive.
      guard kind == .file else {
        fileResult(kind == nil ? 0x101 : 0x10a)
        return
      }
      guard !files.values.contains(where: { $0.name == path }) else {
        fileResult(0x107)
        return
      }
      updatedFiles.removeValue(forKey: path)
      if mountedFiles[path] != nil { removed.insert(path) }
    default: throw EmulationError.invalid("File-system operation")
    }
    do {
      try commitFiles(updatedFiles, directories: directories, removed: removed)
      log.append("File system \(operation.hex): \(path)")
      fileResult(0)
    } catch {
      // A failed host write must not commit half of the guest overlay in memory.
      fileResult(fileStorageError(error))
    }
  }
}
