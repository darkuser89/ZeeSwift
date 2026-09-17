import Foundation

// Original BREW IAStream / IMemAStream declarations; own guest-memory adapter.
final class BREWMemoryStream {
  var references: UInt32 = 1
  var buffer: UInt32 = 0
  var size: UInt32 = 0
  var position: UInt32 = 0
  var ownsAllocation = false
  var freeCallback: UInt32 = 0
  var freeContext: UInt32 = 0
}

extension BREWRuntime {
  func createMemoryStream() throws -> UInt32 {
    let handle = try allocate(4)
    guard handle != 0 else { return 0 }
    let table: UInt32 = hleAddress(0x20500)
    for offset in stride(from: UInt32(0), through: 0x18, by: 4) {
      try memory.write32(table + offset, 0xf01a_0000 + offset)
    }
    try memory.write32(handle, table)
    memoryStreams[handle] = BREWMemoryStream()
    return handle
  }

  private func disposeMemoryStreamBuffer(_ object: BREWMemoryStream) throws {
    let buffer = object.buffer, owned = object.ownsAllocation
    let callback = object.freeCallback, context = object.freeContext
    // Detach before calling guest code, so reentrant release cannot free twice.
    object.buffer = 0; object.size = 0; object.position = 0
    object.ownsAllocation = false; object.freeCallback = 0; object.freeContext = 0
    if callback != 0 {
      let registers = (0..<16).map { cpu.r[$0] }, flags = cpu.cpsr
      defer {
        for i in 0..<16 { cpu.r[i] = registers[i] }
        cpu.cpsr = flags
      }
      _ = try invoke(callback, [context])
    } else if owned { try free(buffer) }
  }

  func releaseMemoryStream(_ handle: UInt32) throws -> UInt32 {
    guard let object = memoryStreams[handle] else {
      throw EmulationError.invalid("Released IMemAStream " + handle.hex)
    }
    object.references -= 1
    let remaining = object.references
    if remaining == 0 {
      timers.removeAll { $0.stream == handle }
      memoryStreams.removeValue(forKey: handle)
      defer { try? free(handle) }
      try disposeMemoryStreamBuffer(object)
    }
    return remaining
  }

  func dispatchMemoryStream(_ offset: UInt32) throws {
    let handle = cpu.r[0], p1 = cpu.r[1], p2 = cpu.r[2], p3 = cpu.r[3]
    guard let object = memoryStreams[handle] else {
      throw EmulationError.invalid("IMemAStream object " + handle.hex)
    }
    switch offset {
    case 0:
      object.references += 1
      cpu.r[0] = object.references
    case 4:
      cpu.r[0] = try releaseMemoryStream(handle)
    case 8:
      // A memory stream is immediately readable, including its EOF condition.
      timers.removeAll { $0.stream == handle }
      if p1 != 0 { scheduleCallback(delay: 0, callback: p1, context: p2, stream: handle) }
    case 0x0c:
      let count = min(p2, object.size - object.position)
      if count != 0 {
        let bytes = try memory.data(object.buffer + object.position, count: Int(count))
        try memory.write(p1, data: bytes)
        object.position += count
      }
      cpu.r[0] = count
    case 0x10:
      timers.removeAll { $0.stream == handle }
    case 0x14, 0x18:
      let fourth = try argument(4)
      let context = offset == 0x18 ? try argument(5) : 0
      guard p3 <= p2 else { throw EmulationError.invalid("IMemAStream offset outside buffer") }
      if p2 != 0 { _ = try memory.region(p1, Int(p2)) }
      if offset == 0x14 && p1 != 0 {
        guard let capacity = allocatedSize(p1), capacity >= Int(p2) else {
          throw EmulationError.invalid("IMemAStream.Set requires a dedicated guest allocation")
        }
      }
      try disposeMemoryStreamBuffer(object)
      guard memoryStreams[handle] === object else {
        throw EmulationError.invalid("IMemAStream released during Set")
      }
      object.buffer = p1; object.size = p2; object.position = p3
      // FREE and SYSFREE use the same checked guest allocator in this HLE.
      object.ownsAllocation = offset == 0x14
      object.freeCallback = offset == 0x18 ? fourth : 0
      object.freeContext = context
    default: throw EmulationError.hle("IMemAStream+" + offset.hex, cpu.r[14])
    }
  }
}
