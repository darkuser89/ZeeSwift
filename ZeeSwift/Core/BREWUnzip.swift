import Foundation

final class BREWUnzipStream {
  var references: UInt32 = 1
  var data = Data()
  var position = 0
}

extension BREWRuntime {
  func createUnzipStream() throws -> UInt32 {
    let handle = try allocate(4)
    guard handle != 0 else { return 0 }
    // Reuse the original ABI table, but never another instance's cursor/data.
    try memory.write32(handle, memory.read32(resourceService))
    unzipStreams[handle] = BREWUnzipStream()
    return handle
  }

  func dispatchUnzip(_ offset: UInt32) throws {
    let handle = cpu.r[0]
    guard let object = unzipStreams[handle] else {
      throw EmulationError.invalid("IUnzipAStream object " + handle.hex)
    }
    switch offset {
    case 0:
      object.references += 1
      cpu.r[0] = object.references
    case 4:
      object.references -= 1
      cpu.r[0] = object.references
      if object.references == 0 {
        timers.removeAll { $0.stream == handle }
        unzipStreams.removeValue(forKey: handle)
        try free(handle)
      }
    case 0x14:
      let source = cpu.r[1]
      timers.removeAll { $0.stream == handle }
      object.data = Data()
      object.position = 0
      // Retained only as the probe's last-decoded diagnostic artifact.
      unzipData = Data()
      if source == 0 { return }
      let input: Data
      if let file = files[source] {
        input = file.data.subdata(in: file.position..<file.data.count)
      } else if let memoryStream = memoryStreams[source] {
        let count = memoryStream.size - memoryStream.position
        input = count == 0 ? Data() : try memory.data(
          memoryStream.buffer + memoryStream.position, count: Int(count))
      } else {
        throw EmulationError.unsupported("IUnzipAStream with guest IAStream " + source.hex)
      }
      var stream = z_stream()
      // zlib and gzip headers are specified by the stream contract.
      guard inflateInit2_(&stream, 47, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
      else { throw EmulationError.invalid("zlib initialization") }
      defer { inflateEnd(&stream) }
      var output = Data()
      var chunk = [UInt8](repeating: 0, count: 65536)
      try input.withUnsafeBytes { bytes in
        stream.next_in = UnsafeMutablePointer(
          mutating: bytes.bindMemory(to: UInt8.self).baseAddress)
        stream.avail_in = UInt32(input.count)
        var status = Z_OK
        while status != Z_STREAM_END {
          let used = chunk.withUnsafeMutableBufferPointer { buffer -> Int in
            stream.next_out = buffer.baseAddress
            stream.avail_out = UInt32(buffer.count)
            status = inflate(&stream, Z_NO_FLUSH)
            return buffer.count - Int(stream.avail_out)
          }
          guard status == Z_OK || status == Z_STREAM_END, used > 0 || status == Z_STREAM_END else {
            throw EmulationError.invalid("IUnzipAStream: invalid compressed data")
          }
          guard output.count + used <= 128 * 1024 * 1024 else {
            throw EmulationError.invalid("IUnzipAStream size limit")
          }
          output.append(contentsOf: chunk.prefix(used))
        }
      }
      if var file = files[source] {
        file.position += Int(stream.total_in)
        files[source] = file
      } else if let memoryStream = memoryStreams[source] {
        memoryStream.position += UInt32(stream.total_in)
      }
      unzipData = output
      object.data = output
      log.append("IUnzipAStream: \(stream.total_in) → \(output.count) Bytes")
    case 0x0c:
      let count = min(Int(cpu.r[2]), object.data.count - object.position)
      if count != 0 {
        try memory.write(
          cpu.r[1], data: object.data.subdata(in: object.position..<(object.position + count)))
      }
      object.position += count
      cpu.r[0] = UInt32(count)
    case 0x08:
      if cpu.r[1] != 0 {
        timers.removeAll { $0.stream == handle }
        scheduleCallback(delay: 0, callback: cpu.r[1], context: cpu.r[2], stream: handle)
      }
    case 0x10: timers.removeAll { $0.stream == handle }
    default: throw EmulationError.hle("IUnzipAStream+" + offset.hex, cpu.r[14])
    }
  }
}
