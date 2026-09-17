import Foundation

final class HIDPadState {
  var connected: Bool
  var buttons = Set<Int>()
  var keyboard = Set<Int>()
  var controller = Set<Int>()
  var axes: [UInt32] = [128, 128, 128, 128]
  var events: [(button: Int, down: Bool, time: UInt32)] = []
  var signals: [UInt32: UInt32] = [:]
  var exclusive: UInt32 = 0
  init(connected: Bool = true) { self.connected = connected }
}

extension BREWRuntime {
  func hidDeviceAddress(player: Int) -> UInt32 { hidDevice + UInt32(player * 0x200) }
  func setControllerConnected(_ connected: Bool, player: Int) {
    guard !appletClosed, hidPads.indices.contains(player), hidPads[player].connected != connected else { return }
    let pad = hidPads[player]
    if !connected {
      pad.keyboard.removeAll()
      setControllerState(.init(), player: player)
      for button in pad.buttons.sorted() { updateButton(button, down: false, player: player) }
    }
    pad.connected = connected
    raiseSignal(pad.signals[0x14, default: 0])
    if hidConnections.count >= 256 { hidConnections.removeFirst(); hidConnectionsDropped = true }
    hidConnections.append((UInt32(player + 1), connected ? 0 : 47))
    raiseSignal(hidConnectSignal)
  }

  // Joystick UIDs, ordered by the Zeebo standard button enumeration.
  static let buttonUIDs: [UInt32] = [
    0x106c40a, 0x106c40b, 0x106c40c, 0x106c40d,
    0x106c406, 0x106c408, 0x106c407, 0x106c409, 0x106c402, 0x106c403, 0x106c404, 0x106c405,
    0x106c3fe, 0x106c3ff, 0x106c400, 0x106c401,
  ]
  func setButton(_ button: Int, down: Bool, player: Int = 0) {
    guard !appletClosed, hidPads.indices.contains(player), hidPads[player].connected, Self.buttonUIDs.indices.contains(button) else { return }
    let pad = hidPads[player]
    if down { pad.keyboard.insert(button) } else { pad.keyboard.remove(button) }
    updateButton(
      button, down: pad.keyboard.contains(button) || pad.controller.contains(button), player: player)
  }
  func setControllerState(_ state: NativeControllerState, player: Int = 0) {
    guard !appletClosed, hidPads.indices.contains(player), hidPads[player].connected else { return }
    let pad = hidPads[player]
    var buttons = state.buttons.filter { Self.buttonUIDs.indices.contains($0) }
    if state.automaticHomeRouting, buttons.remove(8) != nil {
      buttons.insert(ControllerMapping.defaultHomeButton(classID: package.classID))
    }
    let changed = pad.controller.symmetricDifference(buttons)
    pad.controller = buttons
    for button in changed.sorted() {
      updateButton(
        button, down: pad.keyboard.contains(button) || pad.controller.contains(button), player: player)
    }
    let axes = state.hidAxes
    if axes != pad.axes {
      pad.axes = axes
      raiseSignal(pad.signals[0x38, default: 0])
    }
  }
  private func updateButton(_ button: Int, down: Bool, player: Int) {
    let pad = hidPads[player]
    guard Self.buttonUIDs.indices.contains(button), pad.buttons.contains(button) != down else {
      return
    }
    if down { pad.buttons.insert(button) } else { pad.buttons.remove(button) }
    if pad.events.count >= 256 { pad.events.removeFirst() }
    pad.events.append((button, down, uptimeMilliseconds))
    raiseSignal(pad.signals[0x20, default: 0])
    // IHIDDevice.SetExclusiveLevel: default BREW events are generated at level
    // zero, alongside HID notifications. The primary virtual pad supplies the
    // foreground app's keys; exclusive HID clients suppress this system route.
    if player == 0, pad.exclusive == 0, let key = Self.padVirtualKeys[button] {
      if down {
        enqueueShellEvent(target: applet, code: 0x101, key: key)
        enqueueShellEvent(target: applet, code: 0x100, key: key)
      } else {
        enqueueShellEvent(target: applet, code: 0x102, key: key)
      }
    }
  }
  // AEEHIDDevice_Joystick.h UIDs -> AEEVCodes.h gamepad/directional keys.
  // Indices refer to HID buttons, not the numbers printed on a Z-Pad.
  static let padVirtualKeys: [Int: UInt32] = [
    0: 0xe063, 1: 0xe064, 2: 0xe065, 3: 0xe066,
    4: 0xe069, 5: 0xe06a, 9: 0xe030,
    12: 0xe031, 13: 0xe033, 14: 0xe032, 15: 0xe034,
  ]
  func raiseSignal(_ object: UInt32) {
    guard var signal = signals[object], signal.callback != 0 else { return }
    signal.pending = true
    if signal.enabled {
      signal.pending = false
      signal.enabled = false
      scheduleCallback(
        delay: 0, callback: signal.callback, context: signal.context, signal: object)
    }
    signals[object] = signal
  }
  private func hidInfo(_ address: UInt32) throws {
    try memory.write(address, data: Data(repeating: 0, count: 12))
    try memory.write32(address, 0x106c3fd)
    // Virtual Z-Pad; the host controller's USB identity is not exposed to the guest.
  }
  private func buttonInfo(_ address: UInt32, button: Int, down: Bool) throws {
    for (i, v) in [UInt32(button), down ? 1 : 0, Self.buttonUIDs[button], 0, 1].enumerated() {
      try memory.write32(address + UInt32(i * 4), v)
    }
  }
  func dispatchHID(_ offset: UInt32) throws {
    switch offset {
    case 0: cpu.r[0] = 2
    case 4: cpu.r[0] = 1
    case 0x0c:
      guard (1...2).contains(cpu.r[1]), hidPads[Int(cpu.r[1]-1)].connected else {
        try memory.write32(cpu.r[2], 0)
        cpu.r[0] = 15
        return
      }
      let device = hidDeviceAddress(player: Int(cpu.r[1] - 1))
      try memory.write32(device, device + 0x100)
      for i in 0..<20 {
        try memory.write32(device + 0x100 + UInt32(i * 4), 0xf00e_0000 + UInt32(i * 4))
      }
      try memory.write32(cpu.r[2], device)
      cpu.r[0] = 0
    case 0x10:
      guard (1...2).contains(cpu.r[1]), hidPads[Int(cpu.r[1]-1)].connected else {
        cpu.r[0] = 15
        return
      }
      try hidInfo(cpu.r[2])
      cpu.r[0] = 0
    case 0x14:
      guard !hidConnections.isEmpty else { cpu.r[0] = 47; return }
      let event = hidConnections.removeFirst()
      try memory.write32(cpu.r[1], event.handle)
      try memory.write32(cpu.r[2], event.status)
      if cpu.r[3] != 0 { try memory.write8(cpu.r[3], hidConnectionsDropped ? 1 : 0) }
      hidConnectionsDropped = false
      cpu.r[0] = 0
    case 0x18:
      hidConnectSignal = cpu.r[1]
      if !hidConnections.isEmpty { raiseSignal(hidConnectSignal) }
      cpu.r[0] = 0
    case 0x1c:
      let handles: [UInt32] = cpu.r[1] == 0 || cpu.r[1] == 0x106c3fd
        ? hidPads.indices.filter { hidPads[$0].connected }.map { UInt32($0 + 1) } : []
      try memory.write32(argument(4), UInt32(handles.count))
      if cpu.r[2] != 0, Int32(bitPattern: cpu.r[3]) > 0 {
        for (index, handle) in handles.prefix(Int(cpu.r[3])).enumerated() {
          try memory.write32(cpu.r[2] + UInt32(index * 4), handle)
        }
      }
      cpu.r[0] = 0
    default: throw EmulationError.hle("IHID+" + offset.hex, cpu.r[14])
    }
  }
  func dispatchHIDDevice(_ offset: UInt32) throws {
    guard let player = hidPads.indices.first(where: { hidDeviceAddress(player: $0) == cpu.r[0] }) else {
      cpu.r[0] = 15; return
    }
    let device = hidDeviceAddress(player: player)
    let pad = hidPads[player]
    switch offset {
    case 0: cpu.r[0] = 2
    case 4: cpu.r[0] = 1
    case 8:
      let match = cpu.r[1] == 0x106c38e
      try memory.write32(cpu.r[2], match ? device : 0)
      cpu.r[0] = match ? 0 : 3
    case 0x0c:
      try hidInfo(cpu.r[1])
      cpu.r[0] = 0
    case 0x10:
      try memory.write32(cpu.r[1], pad.connected ? 0 : 47)
      cpu.r[0] = 0
    case 0x14, 0x20, 0x38:
      pad.signals[offset] = cpu.r[1]
      if offset == 0x20 && !pad.events.isEmpty { raiseSignal(cpu.r[1]) }
      cpu.r[0] = 0
    case 0x18:
      let button = Int(cpu.r[1])
      guard Self.buttonUIDs.indices.contains(button) else {
        cpu.r[0] = 15
        return
      }
      try buttonInfo(cpu.r[2], button: button, down: pad.buttons.contains(button))
      cpu.r[0] = 0
    case 0x1c:
      try memory.write32(cpu.r[1], 16)
      cpu.r[0] = 0
    case 0x24:
      guard !pad.events.isEmpty else {
        cpu.r[0] = 47
        return
      }
      let event = pad.events.removeFirst()
      try buttonInfo(cpu.r[1], button: event.button, down: event.down)
      if cpu.r[2] != 0 { try memory.write32(cpu.r[2], event.time) }
      if cpu.r[3] != 0 { try memory.write8(cpu.r[3], 0) }
      cpu.r[0] = 0
    case 0x28, 0x2c, 0x30, 0x34:
      try memory.write(cpu.r[1], data: Data(repeating: 0, count: 100))
      if offset == 0x34 {
        for field in 1...24 { try memory.write32(cpu.r[1] + UInt32(field * 4), 0xffff_ffff) }
      }
      // Left X/Y occupy nX/nY, right X/Y occupy nZ/nRz.
      let fields: [UInt32] = [4, 8, 12, 24]
      let identifiers: [UInt32] = [0x0106_c4d0, 0x0106_c4d1, 0x0106_c4ce, 0x0106_c4cf]
      for index in 0..<4 {
        let value =
          offset == 0x28
          ? pad.axes[index] : (offset == 0x2c ? 0 : (offset == 0x30 ? 255 : identifiers[index]))
        try memory.write32(cpu.r[1] + fields[index], value)
      }
      cpu.r[0] = 0
    case 0x3c:
      pad.exclusive = cpu.r[1]
      cpu.r[0] = 0
    case 0x40:
      try memory.write32(cpu.r[1], pad.exclusive)
      cpu.r[0] = 0
    default: throw EmulationError.hle("IHIDDevice+" + offset.hex, cpu.r[14])
    }
  }
}
