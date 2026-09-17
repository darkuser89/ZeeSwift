import Foundation

extension BREWRuntime {
  // Own ARM ABI adapter for ARB buffer objects and the documented QUALCOMM methods.
  // Stores live in checked guest allocations so mapped addresses remain guest addresses.
  func dispatchBuffer(_ method: Int) throws {
    let a = try (0..<4).map { try argument($0) }
    cpu.r[0] = 0
    if method == 5 { cpu.r[0] = gl.buffers[a[0]] == nil ? 0 : 1; return }
    if method == 1 || method == 2 {
      guard a[0] <= 65536 else { gl.setError(0x0501); return }
      guard a[0] > 0 else { return }
      _ = try memory.region(a[1], Int(a[0]) * 4)
      if method == 2 {
        for i in 0..<a[0] {
          while gl.bufferNames.contains(gl.nextBuffer) || gl.nextBuffer == 0 { gl.nextBuffer &+= 1 }
          let name = gl.nextBuffer
          gl.bufferNames.insert(name); gl.nextBuffer &+= 1
          try memory.write32(a[1] + i * 4, name)
        }
      } else {
        let names = try (0..<a[0]).map { try memory.read32(a[1] + $0 * 4) }
        for name in names where name != 0 {
          if let old = gl.buffers.removeValue(forKey: name), old.address != 0 { try free(old.address) }
          gl.bufferNames.remove(name)
          if gl.arrayBuffer == name { gl.arrayBuffer = 0 }
          if gl.elementBuffer == name { gl.elementBuffer = 0 }
          for key in Array(gl.arrays.keys) where gl.arrays[key]?.buffer == name { gl.arrays[key]?.buffer = 0 }
          for i in gl.textureUnits.indices where gl.textureUnits[i].array?.buffer == name {
            gl.textureUnits[i].array?.buffer = 0
          }
        }
      }
      return
    }
    guard a[0] == 0x8892 || a[0] == 0x8893 else { gl.setError(0x0500); return }
    if method == 0 {
      if a[1] != 0 {
        gl.bufferNames.insert(a[1])
        if gl.buffers[a[1]] == nil { gl.buffers[a[1]] = GLESState.BufferObject() }
      }
      if a[0] == 0x8892 { gl.arrayBuffer = a[1] } else { gl.elementBuffer = a[1] }
      return
    }
    let name = a[0] == 0x8892 ? gl.arrayBuffer : gl.elementBuffer
    guard var buffer = gl.buffers[name] else { gl.setError(0x0502); return }
    switch method {
    case 3:
      guard Int32(bitPattern: a[1]) >= 0 else { gl.setError(0x0501); return }
      guard [0x88e0, 0x88e1, 0x88e2, 0x88e4, 0x88e5, 0x88e6, 0x88e8, 0x88e9, 0x88ea].contains(a[3])
      else { gl.setError(0x0500); return }
      guard a[1] <= 32 * 1024 * 1024 else { gl.setError(0x0505); return }
      let bytes = a[2] == 0 || a[1] == 0 ? nil : try memory.data(a[2], count: Int(a[1]))
      let pointer = try allocate(max(1, a[1]))
      guard pointer != 0 else { gl.setError(0x0505); return }
      if let bytes { try memory.write(pointer, data: bytes) }
      if buffer.address != 0 { try free(buffer.address) }
      buffer = GLESState.BufferObject(address: pointer, size: a[1], usage: a[3])
    case 4, 6:
      guard Int32(bitPattern: a[1]) >= 0, Int32(bitPattern: a[2]) >= 0,
        UInt64(a[1]) + UInt64(a[2]) <= UInt64(buffer.size)
      else { gl.setError(0x0501); return }
      guard !buffer.mapped else { gl.setError(0x0502); return }
      if a[2] > 0 {
        let source = method == 4 ? a[3] : buffer.address + a[1]
        let destination = method == 4 ? buffer.address + a[1] : a[3]
        try memory.write(destination, data: memory.data(source, count: Int(a[2])))
      }
    case 7:
      guard [0x88b8, 0x88b9, 0x88ba].contains(a[1]) else { gl.setError(0x0500); return }
      guard !buffer.mapped else { gl.setError(0x0502); return }
      if buffer.address == 0 { buffer.address = try allocate(1) }
      guard buffer.address != 0 else { gl.setError(0x0505); return }
      buffer.mapped = true; buffer.access = a[1]; cpu.r[0] = buffer.address
    case 8:
      guard buffer.mapped else { gl.setError(0x0502); return }
      buffer.mapped = false; cpu.r[0] = 1
    case 9, 10:
      let value: UInt32
      switch (method, a[1]) {
      case (9, 0x8764): value = buffer.size
      case (9, 0x8765): value = buffer.usage
      case (9, 0x88bb): value = buffer.access
      case (9, 0x88bc): value = buffer.mapped ? 1 : 0
      case (10, 0x88bd): value = buffer.mapped ? buffer.address : 0
      default: gl.setError(0x0500); return
      }
      try memory.write32(a[2], value)
    default: throw EmulationError.unsupported("GL buffer method \(method)")
    }
    gl.buffers[name] = buffer
  }
}
