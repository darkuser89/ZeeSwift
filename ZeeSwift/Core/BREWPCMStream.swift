import Foundation

final class BREWPCMStream {
  let source: UInt32
  let buffer: UInt32
  let callback: UInt32
  let capacity: Int
  let queueCapacity: Int
  let player: PCMStreamPlayer
  var waiting = false
  var ended = false
  var remainder = Data()
  var bytesRead: UInt64 = 0
  var reads: UInt64 = 0
  init(source: UInt32, buffer: UInt32, callback: UInt32, capacity: Int, player: PCMStreamPlayer) {
    self.source = source; self.buffer = buffer; self.callback = callback
    self.capacity = capacity; self.player = player
    // The guest transfer buffer limits one Read, not the native playback reserve.
    // Keep 100 ms ready across guest frame/timer callbacks without changing PCM.
    queueCapacity = max(capacity, player.format.sampleRate / 10 * player.format.bytesPerFrame)
  }
}

extension BREWRuntime {
  // Nested source methods may be ARM or Thumb and can themselves call HLE services.
  // Preserve the outer trap's return address, registers and flags.
  private func callPCMSource(_ source: UInt32, offset: UInt32, arguments: [UInt32] = []) throws -> UInt32 {
    let registers = (0..<16).map { cpu.r[$0] }, flags = cpu.cpsr
    defer {
      for i in 0..<16 { cpu.r[i] = registers[i] }
      cpu.cpsr = flags
    }
    let table = try memory.read32(source)
    return try invoke(memory.read32(table + offset), [source] + arguments, budget: 10_000_000)
  }

  func disposePCMStream(_ object: BREWMedia) throws {
    guard let stream = object.pcmStream else { return }
    object.pcmStream = nil
    stream.player.stop()
    try cancelGuestCallback(stream.callback)
    _ = try callPCMSource(stream.source, offset: 4)
    try free(stream.callback)
    try free(stream.buffer)
  }

  func setPCMStream(_ object: BREWMedia, handle: UInt32, descriptor pointer: UInt32,
    count: UInt32) throws -> UInt32 {
    guard count == 1, object.classID == 0x0100_5511 || object.classID == 0x0104_0046
    else { return 20 }
    // A forward-only ISource cannot satisfy a repeat mode configured before SetData.
    guard object.repeatCount == 1 else { return 20 }
    let descriptor = try memory.data(pointer, count: 36)
    guard try descriptor.u32(12) >= 36 else { return 14 }
    guard try descriptor.u32(0) == 0x0100_1012, try descriptor.u32(20) & 1 != 0
    else { return 20 }
    let source = try descriptor.u32(4), spec = try descriptor.u32(24)
    guard source != 0, spec != 0, try descriptor.u32(28) >= 32 else { return 14 }
    let capabilities = try descriptor.u32(16)
    guard capabilities == 0 || capabilities == 1 else { return 20 }
    let format: PCMStreamFormat
    do { format = try PCMStreamFormat(spec: memory.data(spec, count: 32)) }
    catch let error as EmulationError {
      if case .unsupported = error { return 20 }
      throw error
    }
    let table = try memory.read32(source)
    _ = try memory.region(table, 20)
    // Respect a supplied buffer hint, bounded to 256 KiB. By default use 100 ms.
    let requested = Int(try descriptor.u32(32))
    guard requested <= 256 * 1024 else { return 14 }
    let desired = requested == 0 ? format.sampleRate * format.bytesPerFrame / 10 : requested
    let capacity = max(format.bytesPerFrame, desired / format.bytesPerFrame * format.bytesPerFrame)
    let buffer = try allocate(UInt32(capacity)), callback = try allocate(28)
    guard buffer != 0, callback != 0 else {
      if buffer != 0 { try free(buffer) }; if callback != 0 { try free(callback) }
      return 2
    }
    var transferred = false
    defer { if !transferred { try? free(buffer); try? free(callback) } }
    let player = PCMStreamPlayer(format: format)
    try memory.write32(callback + 16, 0xf011_0038)
    try memory.write32(callback + 20, handle)
    _ = try callPCMSource(source, offset: 0)
    do { try disposePCMStream(object) }
    catch { _ = try? callPCMSource(source, offset: 4); throw error }
    object.player?.stop()
    object.pcmStream = BREWPCMStream(source: source, buffer: buffer, callback: callback,
      capacity: capacity, player: player)
    object.player = player
    object.descriptor = descriptor.prefix(12)
    object.state = 2
    object.configure()
    transferred = true
    log.append("IMedia PCM ISource: \(format.sampleRate) Hz, \(format.channels) channel(s), \(format.bits) bit, unsigned=\(format.unsigned), buffer \(capacity) bytes")
    return 0
  }

  func pumpPCMStreams() throws {
    for (handle, object) in Array(media) where object.state == 3 {
      guard let stream = object.pcmStream, !stream.waiting, !stream.ended else { continue }
      let frameBytes = stream.player.format.bytesPerFrame
      // The bounded native reserve is separate from the guest transfer allocation.
      // Assemble partial reads without dropping stereo frames or sample bytes.
      for _ in 0..<4 {
        let available = stream.queueCapacity - stream.player.pendingFrames * frameBytes - stream.remainder.count
        guard available > 0 else { break }
        // Several short scheduled buffers allow replenishment before the entire
        // queue drains, instead of introducing a gap at every buffer boundary.
        let request = min(stream.capacity, available, max(frameBytes,
          stream.player.format.sampleRate / 50 * frameBytes))
        let result = Int32(bitPattern: try callPCMSource(stream.source, offset: 0x0c,
          arguments: [stream.buffer, UInt32(request)]))
        guard media[handle] === object, object.pcmStream === stream, object.state == 3 else { break }
        stream.reads &+= 1
        if result > 0 {
          guard result <= request else { throw EmulationError.invalid("ISource.Read exceeds PCM buffer") }
          stream.bytesRead &+= UInt64(result)
          stream.remainder.append(try memory.data(stream.buffer, count: Int(result)))
          let bytes = stream.remainder.count / frameBytes * frameBytes
          if bytes > 0 {
            try stream.player.enqueue(Data(stream.remainder.prefix(bytes)))
            stream.remainder.removeFirst(bytes)
          }
        } else if result == -2 {
          stream.waiting = true
          _ = try callPCMSource(stream.source, offset: 0x10, arguments: [stream.callback])
          break
        } else {
          guard result == 0 || result == -1 else {
            throw EmulationError.invalid("ISource.Read status \(result)")
          }
          stream.ended = true
          if result == -1 || !stream.remainder.isEmpty {
            stream.player.stop()
            object.state = 2
            notifyMedia(handle, status: 3)
            log.append("IMedia PCM: stream error or incomplete sample")
            break
          }
          stream.player.finishSource()
          break
        }
      }
    }
  }
}
