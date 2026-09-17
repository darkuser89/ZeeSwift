import Foundation
import SQLite3

private final class BREWSQLExecContext {
  unowned let runtime: BREWRuntime
  let callback: UInt32, user: UInt32
  var error: Error?
  init(_ runtime: BREWRuntime, callback: UInt32, user: UInt32) {
    self.runtime = runtime; self.callback = callback; self.user = user
  }
  func row(_ count: Int32, _ values: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, _ names: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) throws -> Int32 {
    var allocated: [UInt32] = []
    defer { for pointer in allocated { try? runtime.free(pointer) } }
    let pointers = try runtime.allocate(UInt32(max(1, count) * 8)); allocated.append(pointers)
    guard pointers != 0 else { return 1 }
    for index in 0..<Int(count) {
      for (column, source) in [(index, values?[index]), (index + Int(count), names?[index])] {
        var pointer: UInt32 = 0
        if let source { pointer = try runtime.guestString(String(cString: source)); allocated.append(pointer) }
        try runtime.memory.write32(pointers + UInt32(column * 4), pointer)
      }
    }
    return Int32(bitPattern: try runtime.invokeFormCallback(callback, [user, UInt32(count), pointers, pointers + UInt32(count * 4)]))
  }
}

// Own ARM ABI adapter for the supplied AEESQL.h. SQLite is the macOS system
// library; guest SQL never receives a host path or a host pointer.
final class BREWSQLObject {
  var references: UInt32 = 1
  let kind: UInt32
  var database: OpaquePointer?
  var statement: OpaquePointer?
  var owner: BREWSQLObject?
  var path = ""
  var guestBuffers: [UInt32] = []
  init(_ kind: UInt32) { self.kind = kind }
  deinit {
    if let statement { sqlite3_finalize(statement) }
    if let database { sqlite3_close_v2(database) }
  }
}

extension BREWRuntime {
  func createSQL(_ kind: UInt32 = 0, object: BREWSQLObject? = nil) throws -> UInt32 {
    let handle = try allocate(4)
    guard handle != 0 else { return 0 }
    let table = hleAddress(0x21000 + kind * 0x100)
    for offset in stride(from: UInt32(0), through: 0x40, by: 4) {
      try memory.write32(table + offset, 0xf0280000 + kind * 0x100 + offset)
    }
    try memory.write32(handle, table)
    sqlObjects[handle] = object ?? BREWSQLObject(kind)
    return handle
  }

  func flushSQL(_ object: BREWSQLObject) throws {
    guard let db = object.database, sqlite3_get_autocommit(db) != 0 else { return }
    var size: sqlite3_int64 = 0
    guard let bytes = sqlite3_serialize(db, "main", &size, 0) else {
      if size < 0 { throw EmulationError.invalid("SQL storage: " + String(cString: sqlite3_errmsg(db))) }
      return
    }
    defer { sqlite3_free(bytes) }
    guard size <= GameSaveStore.capacity else { throw EmulationError.invalid("Save-game storage limit") }
    try saveFile(object.path, data: Data(bytes: bytes, count: Int(size)))
  }

  func dispatchSQL(_ raw: UInt32) throws {
    let handle = cpu.r[0], offset = raw & 0xff
    guard let object = sqlObjects[handle], object.kind == raw >> 8 else {
      throw EmulationError.invalid("Released SQL object")
    }
    if offset == 0 { object.references += 1; cpu.r[0] = object.references; return }
    if offset == 4 {
      object.references -= 1; cpu.r[0] = object.references
      if object.references == 0 {
        for pointer in object.guestBuffers { try free(pointer) }
        sqlObjects.removeValue(forKey: handle); try free(handle)
      }
      return
    }
    if offset == 8 {
      guard cpu.r[2] != 0 else { cpu.r[0] = 14; return }
      let iid: UInt32 = object.kind == 0 ? 0x0103abcb : object.kind == 1 ? 0x0103abca : 0x0103abcd
      let supported = cpu.r[1] == iid || cpu.r[1] == 0x01000001
      try memory.write32(cpu.r[2], supported ? handle : 0)
      if supported { object.references += 1 }
      cpu.r[0] = supported ? 0 : 3; return
    }
    if object.kind == 0 {
      guard cpu.r[1] != 0, let path = try? filePath(memory.string(cpu.r[1])) else { cpu.r[0] = 14; return }
      if offset == 0x10 {
        guard !sqlObjects.values.contains(where: { $0.kind == 1 && $0.path == path }) else { cpu.r[0] = 5; return }
        var files = savedFiles; files.removeValue(forKey: path)
        try commitFiles(files, directories: savedDirectories, removed: removedPaths.union([path]))
        cpu.r[0] = 0; return
      }
      guard offset == 0xc else { throw EmulationError.hle("ISQLMgr+" + offset.hex, cpu.r[14]) }
      let out = cpu.r[2], flags = cpu.r[3]
      guard out != 0 else { cpu.r[0] = 14; return }
      try memory.write32(out, 0)
      guard flags & ~7 == 0 else { cpu.r[0] = 20; return }
      if let existing = sqlObjects.first(where: { $0.value.kind == 1 && $0.value.path == path }) {
        existing.value.references += 1; try memory.write32(out, existing.key); cpu.r[0] = 0; return
      }
      let dbObject = BREWSQLObject(1); dbObject.path = path
      let code = sqlite3_open(":memory:", &dbObject.database)
      guard code == SQLITE_OK, let db = dbObject.database else { cpu.r[0] = UInt32(bitPattern: code); return }
      sqlite3_exec(db, "PRAGMA temp_store=MEMORY", nil, nil, nil)
      sqlite3_limit(db, SQLITE_LIMIT_LENGTH, Int32(GameSaveStore.capacity))
      if let data = try fileContents(path), !data.isEmpty {
        guard let bytes = sqlite3_malloc64(UInt64(data.count)) else { cpu.r[0] = 7; return }
        data.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: data.count)
        let result = sqlite3_deserialize(db, "main", bytes.assumingMemoryBound(to: UInt8.self), Int64(data.count), Int64(data.count), UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_RESIZEABLE))
        guard result == SQLITE_OK else { cpu.r[0] = UInt32(bitPattern: result); return }
      }
      // deserialize internally attaches the copied in-memory database. Install
      // the guest authorizer afterwards, before executing any guest SQL.
      sqlite3_set_authorizer(db, { _, action, first, _, _, _ in
        if action == SQLITE_ATTACH || action == SQLITE_DETACH { return SQLITE_DENY }
        if action == SQLITE_PRAGMA {
          let name = first.map { String(cString: $0).lowercased() } ?? ""
          // Z-Wheel configures these connection-local settings before creating
          // its schemas. The connection and serialized storage remain in memory;
          // none of these pragmas accepts a filesystem path.
          return ["integrity_check", "quick_check", "page_count", "page_size", "table_info", "index_info", "index_list", "user_version", "schema_version",
            "journal_mode", "locking_mode", "synchronous", "legacy_file_format", "encoding"].contains(name) ? SQLITE_OK : SQLITE_DENY
        }
        return SQLITE_OK
      }, nil)
      let result = try createSQL(1, object: dbObject)
      try memory.write32(out, result); cpu.r[0] = result == 0 ? 7 : 0; return
    }
    if object.kind == 1, let db = object.database {
      switch offset {
      case 0xc:
        let sql = try memory.string(cpu.r[1]), callback = cpu.r[2]
        let context = BREWSQLExecContext(self, callback: callback, user: cpu.r[3])
        let errorOut = try argument(4)
        if errorOut != 0 { try memory.write32(errorOut, 0) }
        let changes = sqlite3_total_changes(db)
        let code: Int32
        if callback == 0 { code = sqlite3_exec(db, sql, nil, nil, nil) }
        else {
          code = sqlite3_exec(db, sql, { raw, count, values, names in
            let context = Unmanaged<BREWSQLExecContext>.fromOpaque(raw!).takeUnretainedValue()
            do { return try context.row(count, values, names) }
            catch { context.error = error; return 1 }
          }, Unmanaged.passUnretained(context).toOpaque(), nil)
        }
        if let error = context.error { throw error }
        if code != SQLITE_OK { log.append("ISQL.Exec error \(code): " + String(cString: sqlite3_errmsg(db))) }
        if code != SQLITE_OK, errorOut != 0 { try memory.write32(errorOut, guestString(String(cString: sqlite3_errmsg(db)))) }
        if sqlite3_total_changes(db) != changes || code == SQLITE_OK { try flushSQL(object) }
        cpu.r[0] = UInt32(bitPattern: code)
      case 0x10:
        let pointer = cpu.r[1], length = Int32(bitPattern: cpu.r[2]), flags = cpu.r[3]
        let out = try argument(4), tail = try argument(5)
        guard out != 0, pointer != 0 else { cpu.r[0] = 14; return }
        try memory.write32(out, 0)
        guard flags == 0 else { cpu.r[0] = 20; return }
        if length == 0 {
          if tail != 0 { try memory.write32(tail, pointer) }
          cpu.r[0] = 0; return
        }
        let data = length < 0 ? Data(try memory.string(pointer).utf8) + Data([0]) : try memory.data(pointer, count: Int(length))
        let stmt = BREWSQLObject(2); stmt.owner = object
        var consumed = 0
        let code = data.withUnsafeBytes { bytes -> Int32 in
          let start = bytes.baseAddress!.assumingMemoryBound(to: CChar.self)
          var end: UnsafePointer<CChar>?
          let code = sqlite3_prepare_v2(db, start, Int32(data.count), &stmt.statement, &end)
          if let end { consumed = start.distance(to: end) }
          return code
        }
        if tail != 0 { try memory.write32(tail, pointer + UInt32(consumed)) }
        if code == SQLITE_OK, stmt.statement != nil { try memory.write32(out, createSQL(2, object: stmt)) }
        cpu.r[0] = UInt32(bitPattern: code)
      case 0x14: cpu.r[0] = UInt32(bitPattern: sqlite3_errcode(db))
      default: throw EmulationError.hle("ISQL+" + offset.hex, cpu.r[14])
      }
      return
    }
    if object.kind == 2, let stmt = object.statement {
      switch offset {
      case 0xc, 0x10:
        for pointer in object.guestBuffers { try free(pointer) }; object.guestBuffers.removeAll()
        let code = offset == 0xc ? sqlite3_step(stmt) : sqlite3_reset(stmt)
        if code == SQLITE_DONE, sqlite3_stmt_readonly(stmt) == 0, let owner = object.owner { try flushSQL(owner) }
        cpu.r[0] = UInt32(bitPattern: code)
      case 0x14:
        let type = cpu.r[1], column = Int32(bitPattern: cpu.r[2]), out = cpu.r[3], size = try argument(4)
        guard out != 0, column >= 0, column < sqlite3_column_count(stmt) else { cpu.r[0] = 14; return }
        if type == 2 {
          guard size >= 4 else { cpu.r[0] = 14; return }
          try memory.write32(out, UInt32(bitPattern: sqlite3_column_int(stmt, column)))
        } else if type == 0 || type == 1 || type == 4 {
          guard size >= 4 else { cpu.r[0] = 14; return }
          let raw: UnsafeRawPointer? = type == 0 ? sqlite3_column_text(stmt, column).map(UnsafeRawPointer.init) : type == 1 ? sqlite3_column_text16(stmt, column) : sqlite3_column_blob(stmt, column)
          let count = type == 1 ? sqlite3_column_bytes16(stmt, column) : sqlite3_column_bytes(stmt, column)
          var guest: UInt32 = 0
          if let raw {
            var bytes = Data(bytes: raw, count: Int(count))
            if type != 4 { bytes.append(Data(repeating: 0, count: type == 1 ? 2 : 1)) }
            guest = try allocate(UInt32(max(1, bytes.count))); try memory.write(guest, data: bytes); object.guestBuffers.append(guest)
          }
          try memory.write32(out, guest)
        } else { throw EmulationError.hle("ISQLStmt.GetColumn type " + type.hex, cpu.r[14]) }
        cpu.r[0] = 0
      case 0x18: cpu.r[0] = UInt32(sqlite3_column_count(stmt))
      case 0x1c: cpu.r[0] = UInt32(sqlite3_column_bytes(stmt, Int32(bitPattern: cpu.r[1])))
      case 0x20: cpu.r[0] = UInt32(sqlite3_column_type(stmt, Int32(bitPattern: cpu.r[1])))
      default: throw EmulationError.hle("ISQLStmt+" + offset.hex, cpu.r[14])
      }
      return
    }
    throw EmulationError.invalid("SQL object without database")
  }
}
