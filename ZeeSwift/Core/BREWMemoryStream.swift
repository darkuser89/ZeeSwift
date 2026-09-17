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

// Original BREW ISourceUtil / ISource adapter. Games such as Prey keep their
// decoded sound bank in guest memory and pass an ISource to the PCM media API.
final class BREWMemorySource {
  enum Backing {
    case memory(buffer: UInt32, size: UInt32)
    case stream(UInt32)
  }
  var references: UInt32 = 1
  let backing: Backing
  var position: UInt32 = 0

  init(buffer: UInt32, size: UInt32) {
    backing = .memory(buffer: buffer, size: size)
  }

  init(stream: UInt32) { backing = .stream(stream) }
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

  func createSourceUtility() throws -> UInt32 {
    let handle = try allocate(4)
    guard handle != 0 else { return 0 }
    let table = hleAddress(0x22200)
    for offset in stride(from: UInt32(0), through: 0x18, by: 4) {
      try memory.write32(table + offset, 0xf036_0000 + offset)
    }
    try memory.write32(handle, table)
    sourceUtilities[handle] = 1
    return handle
  }

  private func createMemorySource(buffer: UInt32, size: UInt32) throws -> UInt32 {
    let handle = try allocate(4)
    guard handle != 0 else { return 0 }
    let table = hleAddress(0x22300)
    for offset in stride(from: UInt32(0), through: 0x10, by: 4) {
      try memory.write32(table + offset, 0xf037_0000 + offset)
    }
    try memory.write32(handle, table)
    memorySources[handle] = BREWMemorySource(buffer: buffer, size: size)
    return handle
  }

  private func createStreamSource(stream: UInt32) throws -> UInt32 {
    let handle = try allocate(4)
    guard handle != 0 else { return 0 }
    let table = hleAddress(0x22300)
    for offset in stride(from: UInt32(0), through: 0x10, by: 4) {
      try memory.write32(table + offset, 0xf037_0000 + offset)
    }
    try memory.write32(handle, table)
    memorySources[handle] = BREWMemorySource(stream: stream)
    return handle
  }

  // SourceFromAStream must retain and drive arbitrary synchronous IAStream
  // implementations, including IFile and IMemAStream. Preserve the outer HLE
  // call while invoking the nested guest/HLE vtable method.
  private func callSourceStream(_ stream: UInt32, offset: UInt32,
    arguments: [UInt32] = []) throws -> UInt32
  {
    let registers = (0..<16).map { cpu.r[$0] }, flags = cpu.cpsr
    defer {
      for i in 0..<16 { cpu.r[i] = registers[i] }
      cpu.cpsr = flags
    }
    let table = try memory.read32(stream)
    let entry = try memory.read32(table + offset)
    guard entry != 0 else { throw EmulationError.invalid("IAStream vtable slot " + offset.hex) }
    return try invoke(entry, [stream] + arguments, budget: 10_000_000)
  }

  func dispatchSourceUtility(_ offset: UInt32) throws {
    let handle = cpu.r[0], interface = cpu.r[1], output = cpu.r[2]
    guard let references = sourceUtilities[handle] else {
      throw EmulationError.invalid("Released ISourceUtil object")
    }
    switch offset {
    case 0:
      sourceUtilities[handle] = references + 1
      cpu.r[0] = references + 1
    case 4:
      let remaining = references - 1
      cpu.r[0] = remaining
      if remaining == 0 {
        sourceUtilities.removeValue(forKey: handle)
        try free(handle)
      } else { sourceUtilities[handle] = remaining }
    case 8:
      guard output != 0 else { cpu.r[0] = 14; return }
      let matches = interface == 0x0100_1011 || interface == 0x0100_0001
      try memory.write32(output, matches ? handle : 0)
      if matches {
        sourceUtilities[handle] = references + 1
        cpu.r[0] = 0
      } else { cpu.r[0] = 3 }
    case 0x14:
      // ISourceUtil_SourceFromMemory(me, data, size, freeFn, freeData, out).
      let freeFunction = cpu.r[3]
      let freeContext = try argument(4)
      let sourceOutput = try argument(5)
      guard sourceOutput != 0 else { cpu.r[0] = 14; return }
      _ = try memory.region(sourceOutput, 4)
      try memory.write32(sourceOutput, 0)
      guard cpu.r[2] == 0 || cpu.r[1] != 0 else { cpu.r[0] = 14; return }
      if cpu.r[2] != 0 { _ = try memory.region(cpu.r[1], Int(cpu.r[2])) }
      // The SDK permits null ownership hooks, which is the form used by Prey.
      // Unknown guest free-function ABIs are deliberately not guessed.
      guard freeFunction == 0 && freeContext == 0 else { cpu.r[0] = 20; return }
      let source = try createMemorySource(buffer: cpu.r[1], size: cpu.r[2])
      guard source != 0 else { cpu.r[0] = 2; return }
      try memory.write32(sourceOutput, source)
      cpu.r[0] = 0
    case 0x18:
      // ISourceUtil_SourceFromAStream(me, stream, out). IFile implements the
      // IAStream contract used here by Z-Wheel; retain it for the ISource life.
      let stream = cpu.r[1], sourceOutput = cpu.r[2]
      guard sourceOutput != 0 else { cpu.r[0] = 14; return }
      _ = try memory.region(sourceOutput, 4)
      try memory.write32(sourceOutput, 0)
      guard stream != 0 else { cpu.r[0] = 14; return }
      let table = try memory.read32(stream)
      _ = try memory.region(table, 16)
      guard try memory.read32(table) != 0, try memory.read32(table + 4) != 0,
        try memory.read32(table + 0x0c) != 0 else { cpu.r[0] = 20; return }
      _ = try callSourceStream(stream, offset: 0)
      let source: UInt32
      do { source = try createStreamSource(stream: stream) }
      catch {
        _ = try? callSourceStream(stream, offset: 4)
        throw error
      }
      guard source != 0 else {
        _ = try callSourceStream(stream, offset: 4)
        cpu.r[0] = 2
        return
      }
      try memory.write32(sourceOutput, source)
      cpu.r[0] = 0
    default:
      // Other constructors must report unsupported rather than fabricate a source.
      cpu.r[0] = 20
    }
  }

  func dispatchMemorySource(_ offset: UInt32) throws {
    let handle = cpu.r[0], interface = cpu.r[1], output = cpu.r[2]
    guard let source = memorySources[handle] else {
      throw EmulationError.invalid("Released ISource object")
    }
    switch offset {
    case 0:
      source.references += 1
      cpu.r[0] = source.references
    case 4:
      source.references -= 1
      cpu.r[0] = source.references
      if source.references == 0 {
        memorySources.removeValue(forKey: handle)
        defer { try? free(handle) }
        if case .stream(let stream) = source.backing {
          _ = try callSourceStream(stream, offset: 4)
        }
      }
    case 8:
      guard output != 0 else { cpu.r[0] = 14; return }
      let matches = interface == 0x0100_1012 || interface == 0x0100_0001
      try memory.write32(output, matches ? handle : 0)
      if matches {
        source.references += 1
        cpu.r[0] = 0
      } else { cpu.r[0] = 3 }
    case 0x0c:
      switch source.backing {
      case .memory(let buffer, let size):
        let count = min(cpu.r[2], size - source.position)
        if count != 0 {
          let bytes = try memory.data(buffer + source.position, count: Int(count))
          try memory.write(cpu.r[1], data: bytes)
          source.position += count
        }
        cpu.r[0] = count
      case .stream(let stream):
        cpu.r[0] = try callSourceStream(stream, offset: 0x0c,
          arguments: [cpu.r[1], cpu.r[2]])
      }
    case 0x10:
      if cpu.r[1] != 0 { try scheduleGuestCallback(cpu.r[1]) }
      cpu.r[0] = 0
    default: throw EmulationError.hle("ISource+" + offset.hex, cpu.r[14])
    }
  }
}
