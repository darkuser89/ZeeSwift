import Foundation

extension BREWRuntime {
  func dispatchSignal(api: UInt32, offset: UInt32) throws {
    let object = cpu.r[0]
    if api == 0xf00c_0000 {
      switch offset {
      case 0: cpu.r[0] = 2
      case 4: cpu.r[0] = 1
      case 0x0c:
        let callback = cpu.r[1]
        let context = cpu.r[2]
        let out = cpu.r[3]
        let control = try argument(4)
        let handle = try allocate(16)
        guard handle != 0 else {
          cpu.r[0] = 2
          return
        }
        try memory.write32(handle, hleAddress(0x11000))
        for i in 0..<6 {
          try memory.write32(hleAddress(0x11000) + UInt32(i * 4), 0xf00d_0000 + UInt32(i * 4))
        }
        signals[handle] = Signal(
          callback: callback, context: context, references: out != 0 && control != 0 ? 2 : 1)
        if out != 0 { try memory.write32(out, handle) }
        if control != 0 { try memory.write32(control, handle) }
        cpu.r[0] = 0
      default: throw EmulationError.hle("ISignalCBFactory+" + offset.hex, cpu.r[14])
      }
      return
    }
    guard var signal = signals[object] else { throw EmulationError.invalid("ISignal handle") }
    switch offset {
    case 0:
      signal.references += 1
      cpu.r[0] = signal.references
    case 4:
      signal.references -= 1
      cpu.r[0] = signal.references
      if signal.references == 0 {
        signals.removeValue(forKey: object)
        return
      }
    case 8:
      if [UInt32(0x0102_85f5), 0x0104_1079].contains(cpu.r[1]) {
        try memory.write32(cpu.r[2], object)
        signal.references += 1
        cpu.r[0] = 0
      } else {
        try memory.write32(cpu.r[2], 0)
        cpu.r[0] = 3
      }
    case 0x0c:
      signal.pending = true
      cpu.r[0] = 0
    case 0x10:
      signal.callback = 0
      signal.pending = false
      signal.enabled = false
      cpu.r[0] = 0
    case 0x14:
      signal.enabled = true
      cpu.r[0] = 0
    default: throw EmulationError.hle("ISignalCtl+" + offset.hex, cpu.r[14])
    }
    if signal.pending && signal.enabled && signal.callback != 0 {
      signal.pending = false
      signal.enabled = false
      scheduleCallback(
        delay: 0, callback: signal.callback, context: signal.context, signal: object)
    }
    signals[object] = signal
  }
}
