import Foundation

final class BREWNet {
  var references: UInt32 = 1
  var linger: UInt16 = 30
  var error: UInt32 = 0
  var masks: [UInt32] = []
  var listeners: [UInt32: UInt32] = [:]
}

extension BREWRuntime {
  func createNet() throws -> UInt32 {
    let handle = try allocate(4)
    guard handle != 0 else { return 0 }
    let table = hleAddress(0x20f00)
    for offset in stride(from: UInt32(0), through: 0x2c, by: 4) {
      try memory.write32(table + offset, 0xf0270000 + offset)
    }
    try memory.write32(handle, table); netObjects[handle] = BREWNet(); return handle
  }

  // AEENet.h: INetMgr inherits IBase + SetMask, not QueryInterface. The
  // current guest network is offline; report that state and complete DNS
  // callbacks with ENETDOWN instead of claiming a working connection.
  func dispatchNet(_ offset: UInt32) throws {
    let handle = cpu.r[0]
    guard let object = netObjects[handle] else { throw EmulationError.invalid("Released INetMgr") }
    switch offset {
    case 0: object.references += 1; cpu.r[0] = object.references
    case 4:
      object.references -= 1; cpu.r[0] = object.references
      if object.references == 0 { netObjects.removeValue(forKey: handle); try free(handle) }
    case 8:
      var masks: [UInt32] = []
      if cpu.r[1] != 0 {
        for i in 0..<128 {
          let mask = try memory.read32(cpu.r[1] + UInt32(i * 4))
          if mask == 0 { object.masks = masks; cpu.r[0] = 0; return }
          masks.append(mask)
        }
        throw EmulationError.invalid("INetMgr masks without terminator")
      }
      object.masks = []; cpu.r[0] = 0
    case 0xc:
      let out = cpu.r[1], callback = cpu.r[3]
      guard out != 0 else { object.error = 0x203; return }
      _ = try memory.region(out, 20)
      try memory.write(out, data: Data(repeating: 0, count: 20))
      try memory.write32(out, 0x216); object.error = 0x216
      try scheduleGuestCallback(callback); cpu.r[0] = 0
    case 0x10: cpu.r[0] = object.error
    case 0x14: object.error = 0x216; cpu.r[0] = 0
    case 0x18:
      if cpu.r[1] != 0 { try memory.write(cpu.r[1], data: Data(repeating: 0, count: 32)) }
      cpu.r[0] = 4 // NET_PPP_CLOSED
    case 0x1c: cpu.r[0] = 0
    case 0x20:
      let old = object.linger; object.linger = UInt16(truncatingIfNeeded: cpu.r[1]); cpu.r[0] = UInt32(old)
    case 0x24:
      guard cpu.r[1] != 0 else { cpu.r[0] = 14; return }
      if cpu.r[3] != 0 { object.listeners[cpu.r[1]] = cpu.r[2] }
      else { object.listeners.removeValue(forKey: cpu.r[1]) }
      cpu.r[0] = 0
    case 0x28, 0x2c: cpu.r[0] = 20
    default: throw EmulationError.hle("INetMgr+" + offset.hex, cpu.r[14])
    }
  }
}

final class BREWWeb {
  var references: UInt32 = 1
  // Only scalar options are needed by the observed game startup. Values are
  // copied, never retained as pointers into the caller's temporary option array.
  var options: [(id: UInt32, value: UInt32)] = []
}

extension BREWRuntime {
  func createWeb() throws -> UInt32 {
    let handle = try allocate(4)
    guard handle != 0 else { return 0 }
    let table = hleAddress(0x20c00)
    for offset in stride(from: UInt32(0), through: 0x1c, by: 4) {
      try memory.write32(table + offset, 0xf0240000 + offset)
    }
    try memory.write32(handle, table)
    webObjects[handle] = BREWWeb()
    return handle
  }

  // Own IWeb/IxOpts scalar option ABI from the supplied AEEWeb.h/AEEIxOpts.h.
  // This is initialization support, not an HTTP implementation. Requests stop
  // explicitly until their response/cancellation contract is implemented.
  func dispatchWeb(_ offset: UInt32) throws {
    let handle = cpu.r[0]
    guard let object = webObjects[handle] else { throw EmulationError.invalid("Released IWeb") }
    switch offset {
    case 0: object.references += 1; cpu.r[0] = object.references
    case 4:
      object.references -= 1
      cpu.r[0] = object.references
      if object.references == 0 { webObjects.removeValue(forKey: handle); try free(handle) }
    case 8:
      let out = cpu.r[2]
      guard out != 0 else { cpu.r[0] = 14; return }
      _ = try memory.region(out, 4)
      let supported = cpu.r[1] == 0x01000001 || cpu.r[1] == 0x0102c269
      try memory.write32(out, supported ? handle : 0)
      if supported { object.references += 1 }
      cpu.r[0] = supported ? 0 : 3
    case 0x0c:
      let pointer = cpu.r[1]
      guard pointer != 0 else { cpu.r[0] = 14; return }
      var additions: [(id: UInt32, value: UInt32)] = []
      // Bound malformed unterminated arrays and total retained guest options.
      for index in 0...4096 {
        let address = UInt64(pointer) + UInt64(index * 8)
        guard address <= UInt64(UInt32.max) - 7 else { cpu.r[0] = 14; return }
        let id = try memory.read32(UInt32(address))
        if id == 0 {
          // Earlier items in one array have precedence; a newly added
          // array precedes older arrays. Do not reverse the input array.
          object.options.insert(contentsOf: additions, at: 0)
          cpu.r[0] = 0
          return
        }
        guard (0x20000...0x2ffff).contains(id) else {
          cpu.r[0] = 20 // EUNSUPPORTED: no pretend pointer/interface copying.
          return
        }
        guard object.options.count + additions.count < 4096 else { cpu.r[0] = 2; return }
        additions.append((id, try memory.read32(UInt32(address) + 4)))
      }
      cpu.r[0] = 14
    case 0x10, 0x14:
      let id = cpu.r[1], requested = Int(Int32(bitPattern: cpu.r[2]))
      let out = cpu.r[3]
      if offset == 0x14 {
        guard out != 0 else { cpu.r[0] = 14; return }
        _ = try memory.region(out, 8)
      }
      guard requested >= 0 else { cpu.r[0] = 1; return }
      var remaining = requested
      for index in object.options.indices where id == 1 || object.options[index].id == id {
        if remaining == 0 {
          let item = object.options[index]
          if offset == 0x10 { object.options.remove(at: index) }
          else {
            try memory.write32(out, item.id)
            try memory.write32(out + 4, item.value)
          }
          cpu.r[0] = 0
          return
        }
        remaining -= 1
      }
      cpu.r[0] = 1
    default: throw EmulationError.hle("IWeb+" + offset.hex, cpu.r[14])
    }
  }
}
