import Foundation

final class BREWTextControl {
  var references: UInt32 = 1
  var buffer: UInt32
  var bufferUnits = 1
  var maximum = 65535
  var active = false
  var inputMode: UInt32 = 0
  var properties: UInt32 = 0
  var rectangle = Data([0, 0, 0, 0, 0x80, 2, 0xe0, 1])
  init(buffer: UInt32) { self.buffer = buffer }
}

extension BREWRuntime {
  // Own IBASE/IControl/ITextCtl ABI adapter from the supplied AEEText.h.
  // Text is kept in guest memory, so GetTextPtr returns an actual owned buffer.
  func createTextControl() throws -> UInt32 {
    let handle = try allocate(4)
    guard handle != 0 else { return 0 }
    let buffer = try allocate(2)
    guard buffer != 0 else { try free(handle); return 0 }
    try memory.write16(buffer, 0)
    let table = hleAddress(0x20d00)
    for offset in stride(from: UInt32(0), through: 0x6c, by: 4) {
      try memory.write32(table + offset, 0xf0250000 + offset)
    }
    try memory.write32(handle, table)
    textControls[handle] = BREWTextControl(buffer: buffer)
    return handle
  }

  func textControlUnits(_ object: BREWTextControl) throws -> [UInt16] {
    var units: [UInt16] = []
    for index in 0..<object.bufferUnits {
      let value = UInt16(try memory.read16(object.buffer + UInt32(index * 2)))
      if value == 0 { return units }
      units.append(value)
    }
    throw EmulationError.invalid("ITextCtl buffer without terminator")
  }

  @discardableResult
  func replaceControlText(_ object: BREWTextControl, _ units: [UInt16], capacity: Int? = nil) throws -> Bool {
    let count = capacity ?? max(object.bufferUnits, units.count + 1)
    var data = Data(repeating: 0, count: count * 2)
    for (index, unit) in units.enumerated() {
      data[index * 2] = UInt8(truncatingIfNeeded: unit); data[index * 2 + 1] = UInt8(unit >> 8)
    }
    let buffer = try allocate(UInt32(data.count))
    guard buffer != 0 else { return false }
    try memory.write(buffer, data: data)
    let old = object.buffer
    object.buffer = buffer; object.bufferUnits = count
    try free(old)
    return true
  }

  func dispatchTextControl(_ offset: UInt32) throws {
    let handle = cpu.r[0]
    guard let object = textControls[handle] else { throw EmulationError.invalid("Released ITextCtl") }
    switch offset {
    case 0: object.references += 1; cpu.r[0] = object.references
    case 4:
      object.references -= 1; cpu.r[0] = object.references
      if object.references == 0 {
        textControls.removeValue(forKey: handle)
        try free(object.buffer); try free(handle)
      }
    // Application lifecycle notifications are not text-editing events. Zenonia
    // forwards EVT_APP_START to this control before running its own startup.
    case 8 where !object.active || cpu.r[1] <= 0x14: cpu.r[0] = 0
    case 0x0c where object.properties & 0x00100000 != 0: cpu.r[0] = 1 // TP_NODRAW
    case 0x10: object.active = cpu.r[1] != 0; cpu.r[0] = 0
    case 0x14: cpu.r[0] = object.active ? 1 : 0
    case 0x18: object.rectangle = try memory.data(cpu.r[1], count: 8); cpu.r[0] = 0
    case 0x1c: try memory.write(cpu.r[1], data: object.rectangle); cpu.r[0] = 0
    case 0x20: object.properties = cpu.r[1]; cpu.r[0] = 0
    case 0x24: cpu.r[0] = object.properties
    case 0x28:
      guard try replaceControlText(object, []) else { throw EmulationError.invalid("ITextCtl.Reset: out of memory") }
      object.active = false; cpu.r[0] = 0
    case 0x30:
      let source = cpu.r[1], requested = Int(Int32(bitPattern: cpu.r[2]))
      guard source != 0 || requested == 0 else { cpu.r[0] = 0; return }
      var units: [UInt16] = []
      let limit = min(requested < 0 ? 65536 : requested, 65536)
      for index in 0..<limit {
        let address = UInt64(source) + UInt64(index * 2)
        guard address <= UInt64(UInt32.max) - 1 else { cpu.r[0] = 0; return }
        let value = UInt16(try memory.read16(UInt32(address)))
        if value == 0 { break }
        guard units.count < object.maximum else { cpu.r[0] = 0; return }
        units.append(value)
      }
      cpu.r[0] = try replaceControlText(object, units) ? 1 : 0
    case 0x34:
      let destination = cpu.r[1], maximum = Int(Int32(bitPattern: cpu.r[2]))
      guard destination != 0, maximum > 0 else { cpu.r[0] = 0; return }
      let units = try textControlUnits(object)
      var data = Data()
      for unit in units.prefix(maximum - 1) {
        data.append(UInt8(truncatingIfNeeded: unit)); data.append(UInt8(unit >> 8))
      }
      data.append(contentsOf: [0, 0])
      try memory.write(destination, data: data); cpu.r[0] = 1
    case 0x38: cpu.r[0] = object.buffer
    case 0x40:
      let maximum = Int(cpu.r[1] & 0xffff)
      if maximum > 0 {
        let units = try textControlUnits(object)
        // SetMaxSize must reserve the requested guest buffer capacity, including
        // growth with unchanged text. Subsequent SetText retains that capacity.
        if try !replaceControlText(object, Array(units.prefix(maximum)), capacity: maximum + 1) {
          throw EmulationError.invalid("ITextCtl.SetMaxSize: out of memory")
        }
        object.maximum = maximum
      }
      cpu.r[0] = 0
    case 0x48:
      // Mode configuration is independent of event processing. The latter is
      // still an explicit HLE boundary for an active control.
      switch cpu.r[1] {
      case 0, 3: object.inputMode = cpu.r[1]; cpu.r[0] = object.inputMode
      case 1: cpu.r[0] = object.inputMode // AEE_TM_CURRENT
      default: cpu.r[0] = 0 // AEE_TM_NONE for an unavailable input method
      }
    case 0x54:
      if cpu.r[1] != 0 {
        var info = Data(repeating: 0, count: 36)
        info[0] = UInt8(object.inputMode)
        if object.inputMode == 3 { info[4] = 65; info[6] = 66; info[8] = 67 }
        try memory.write(cpu.r[1], data: info)
      }
      cpu.r[0] = object.inputMode
    default:
      // Active editing, IME, drawing, titles and newer selection APIs remain
      // explicit missing calls until their full behavior is implemented.
      throw EmulationError.hle("ITextCtl+" + offset.hex, cpu.r[14])
    }
  }
}
