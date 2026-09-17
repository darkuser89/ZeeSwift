import Foundation
import simd

extension BREWRuntime {
  func argument(_ index: Int) throws -> UInt32 {
    index < 4 ? cpu.r[index] : try memory.read32(cpu.r[13] + UInt32((index - 4) * 4))
  }
  func guestString(_ string: String) throws -> UInt32 {
    let data = Data(string.utf8) + Data([0])
    let p = try allocate(UInt32(data.count))
    try memory.write(p, data: data)
    return p
  }
  func dispatchGL(_ offset: UInt32, floatingPoint: Bool = false) throws {
    if [UInt32(0x1c), 0x68, 0x6c, 0x78, 0x7c].contains(offset) { try syncEGLColorBuffer() }
    let r = (0..<4).map { cpu.r[$0] }
    let previousError = gl.error
    defer {
      if previousError == 0 && gl.error != 0 && graphicsErrorLogCount < 16 {
        log.append(
          "GL error " + gl.error.hex + " from IGL+" + offset.hex + " args "
            + r.map(\.hex).joined(separator: ","))
        graphicsErrorLogCount += 1
      }
    }
    func number(_ value: UInt32) -> Float {
      floatingPoint ? Float(bitPattern: value) : GLESState.fixed(value)
    }
    func fixed(_ index: Int) throws -> Float { number(try argument(index)) }
    func enumerant(_ raw: UInt32) throws -> UInt32 {
      guard floatingPoint else { return raw }
      let value = Double(Float(bitPattern: raw))
      guard value.isFinite, value >= 0, value <= Double(UInt32.max) else {
        throw EmulationError.invalid("GL floating-point enum")
      }
      return UInt32(value)
    }
    func vector(_ p: UInt32, _ count: Int) throws -> [UInt32] {
      try (0..<count).map { try memory.read32(p + UInt32($0 * 4)) }
    }
    func setArray(_ slot: UInt32, size: Int, type: UInt32, stride: UInt32, address: UInt32) throws {
      guard size >= 2 && size <= 4, stride <= 65536 else {
        gl.setError(0x0501)
        return
      }
      let array = GLESState.ArrayPointer(
        size: size, type: type, stride: Int(stride), address: address, buffer: gl.arrayBuffer)
      if slot == 0x8078 {
        gl.textureUnits[gl.clientActiveTexture].array = array
      } else {
        gl.arrays[slot] = array
      }
    }
    switch offset {
    case 0: cpu.r[0] = 2
    case 4: cpu.r[0] = 1
    case 8:
      try memory.write32(r[2], r[1] == 0x0101_4bc3 ? glObject : 0)
      cpu.r[0] = r[1] == 0x0101_4bc3 ? 0 : 3
    case 0x0c, 0x2c: gl.selectTexture(r[0], client: offset == 0x2c)
    case 0x10:
      gl.alphaFunction = r[0]
      gl.alphaReference = min(1, max(0, try fixed(1)))
    case 0x14:
      if r[0] == 0x0de1 {
        gl.boundTexture = r[1]
        gl.generated.insert(r[1])
      } else {
        gl.setError(0x0500)
      }
    case 0x18: gl.blend = SIMD2(r[0], r[1])
    case 0x1c:
      try gl.clear(r[0])
    case 0x20: gl.clearColor = SIMD4(try fixed(0), try fixed(1), try fixed(2), try fixed(3))
    case 0x24: gl.clearDepth = min(1, max(0, try fixed(0)))
    case 0x28: gl.clearStencil = r[0]
    case 0x30: gl.color = SIMD4(try fixed(0), try fixed(1), try fixed(2), try fixed(3))
    case 0x34: gl.colorMask = SIMD4(r[0], r[1], r[2], r[3])
    case 0x38: try setArray(0x8076, size: Int(r[0]), type: r[1], stride: r[2], address: r[3])
    case 0x3c:
      guard r[0] == 0x0de1 else {
        gl.setError(0x0500)
        return
      }
      let level = Int(Int32(bitPattern: r[1]))
      let paletted = (0x8b90...0x8b99).contains(r[2])
      guard paletted || ATCTexture.formats.contains(r[2]) else {
        gl.setError(0x0500)
        return
      }
      guard try argument(5) == 0 else {
        gl.setError(paletted ? 0x0502 : 0x0501)
        return
      }
      let size = try argument(6)
      let pointer = try argument(7)
      let width = Int(r[3])
      let height = Int(try argument(4))
      guard size <= 16 * 1024 * 1024, width > 0, height > 0,
        width <= 2048, height <= 2048,
        paletted ? (level <= 0 && level >= -11) : (level >= 0 && level <= 11),
        paletted || (width <= 2048 >> level && height <= 2048 >> level)
      else {
        gl.setError(0x0501)
        return
      }
      let data = try memory.data(pointer, count: Int(size))
      var texture = gl.textures[gl.boundTexture] ?? GLESTexture(width: 0, height: 0, pixels: Data())
      do {
        if paletted {
          for (index, image) in try PalettedTexture.decodeLevels(
            format: r[2], width: width,
            height: height, level: level, data: data
          ).enumerated() {
            texture.setImage(image, level: index)
          }
        } else {
          let decoded = try ATCTexture.decode(
            format: r[2], width: width, height: height, data: data)
          texture.setImage(decoded.images[0]!, level: level)
        }
      } catch EmulationError.invalid {
        gl.setError(0x0501)
        return
      }
      gl.textures[gl.boundTexture] = texture
    case 0x40:
      // AMD_compressed_ATC_texture forbids subimage updates, even for a whole block.
      guard ATCTexture.formats.contains(try argument(6)) else {
        throw EmulationError.hle("IGL+" + offset.hex, cpu.r[14])
      }
      gl.setError(0x0502)
    case 0x48:
      guard let image = gl.textures[gl.boundTexture]?.images[Int(r[1])],
        ATCTexture.formats.contains(image.internalFormat) else {
        throw EmulationError.hle("IGL+" + offset.hex, cpu.r[14])
      }
      gl.setError(0x0502)
    case 0x4c: gl.cull = r[0]
    case 0x50:
      guard r[0] <= 65536 else {
        gl.setError(0x0501)
        return
      }
      for name in try vector(r[1], Int(r[0])) {
        gl.textures.removeValue(forKey: name)
        gl.generated.remove(name)
        for unit in gl.textureUnits.indices where gl.textureUnits[unit].binding == name {
          gl.textureUnits[unit].binding = 0
        }
      }
    case 0x54: gl.depthFunction = r[0]
    case 0x58: gl.depthWrite = r[0] != 0
    case 0x5c:
      let near = number(r[0]), far = number(r[1])
      guard !near.isNaN && !far.isNaN else {
        throw EmulationError.unsupported("GL DepthRange with NaN")
      }
      gl.depthRange = SIMD2(min(1, max(0, near)), min(1, max(0, far)))
    case 0x60: gl.setEnabled(r[0], false)
    case 0x64: gl.setEnabled(r[0], false, client: true)
    case 0x68:
      guard r[1] <= 1_000_000, r[2] <= 1_000_000 else {
        gl.setError(0x0501)
        return
      }
      try gl.draw(mode: r[0], indices: Array(Int(r[1])..<(Int(r[1]) + Int(r[2]))), memory: memory)
    case 0x6c:
      guard r[1] <= 1_000_000 else {
        gl.setError(0x0501)
        return
      }
      guard r[2] == 0x1401 || r[2] == 0x1403 else {
        gl.setError(0x0500)
        return
      }
      if gl.elementBuffer != 0 && gl.buffers[gl.elementBuffer]?.mapped == true {
        gl.setError(0x0502); return
      }
      let pointer = try gl.elementBuffer == 0 || r[1] == 0 ? r[3]
        : gl.bufferAddress(gl.elementBuffer, offset: UInt64(r[3]), count: Int(r[1]) * (r[2] == 0x1401 ? 1 : 2))
      let indices = try (0..<r[1]).map {
        Int(try r[2] == 0x1401 ? memory.read8(pointer + $0) : memory.read16(pointer + $0 * 2))
      }
      try gl.draw(mode: r[0], indices: indices, memory: memory)
    case 0x70: gl.setEnabled(r[0], true)
    case 0x74: gl.setEnabled(r[0], true, client: true)
    case 0x78, 0x7c:
      try gl.backend?.finish()  // glFinish / glFlush
      if offset == 0x78, eglColorBuffer != 0 { _ = try getEGLColorBuffer() }
    case 0x80, 0x84:
      let raw = try offset == 0x84 ? memory.read32(r[1]) : r[1]
      switch r[0] {
      case 0x0b65:
        let mode = try enumerant(raw)
        if [UInt32(0x0800), 0x0801, 0x2601].contains(mode) {
          gl.fogMode = mode
        } else {
          gl.setError(0x0500)
        }
      case 0x0b62:
        let density = number(raw)
        if density >= 0 { gl.fogDensity = density } else { gl.setError(0x0501) }
      case 0x0b63: gl.fogStart = number(raw)
      case 0x0b64: gl.fogEnd = number(raw)
      case 0x0b66 where offset == 0x84:
        let color = try vector(r[1], 4).map { min(1, max(0, number($0))) }
        gl.fogColor = SIMD4(color[0], color[1], color[2], color[3])
      default: gl.setError(0x0500)
      }
    case 0xc0: gl.parameters[r[0]] = [r[1]]
    case 0x10c:
      if r[0] == 0x1d00 || r[0] == 0x1d01 { gl.shadeModel = r[0] } else { gl.setError(0x0500) }
    case 0xa4, 0xa8:
      let count = r[0] == 0x0b53 ? 4 : r[0] == 0x0b52 ? 1 : 0
      guard count > 0, offset == 0xa8 || count == 1 else { gl.setError(0x0500); return }
      let values = try (offset == 0xa8 ? vector(r[1], count) : [r[1]]).map(number)
      if count == 1 { gl.lighting.controls.y = values[0] != 0 ? 1 : 0 }
      else { gl.lighting.sceneAmbient = SIMD4(values[0], values[1], values[2], values[3]) }
    case 0x88: gl.front = r[0]
    case 0x8c, 0xe0:
      let l = try fixed(0)
      let rr = try fixed(1)
      let b = try fixed(2)
      let t = try fixed(3)
      let n = try fixed(4)
      let f = try fixed(5)
      guard l != rr, b != t, n != f else {
        gl.setError(0x0501)
        return
      }
      var m = matrix_identity_float4x4
      if offset == 0xe0 {
        m.columns.0.x = 2 / (rr - l)
        m.columns.1.y = 2 / (t - b)
        m.columns.2.z = -2 / (f - n)
        m.columns.3 = SIMD4(-(rr + l) / (rr - l), -(t + b) / (t - b), -(f + n) / (f - n), 1)
      } else {
        guard n > 0, f > 0 else {
          gl.setError(0x0501)
          return
        }
        m.columns.0.x = 2 * n / (rr - l)
        m.columns.1.y = 2 * n / (t - b)
        m.columns.2 = SIMD4((rr + l) / (rr - l), (t + b) / (t - b), -(f + n) / (f - n), -1)
        m.columns.3 = SIMD4(0, 0, -2 * f * n / (f - n), 0)
      }
      gl.multiply(m)
    case 0x90:
      guard r[0] <= 65536 else {
        gl.setError(0x0501)
        return
      }
      for i in 0..<r[0] {
        while gl.generated.contains(gl.nextTexture) { gl.nextTexture += 1 }
        try memory.write32(r[1] + i * 4, gl.nextTexture)
        gl.generated.insert(gl.nextTexture)
        gl.nextTexture += 1
      }
    case 0x94:
      cpu.r[0] = gl.error
      gl.error = 0
    case 0x98:
      let values: [UInt32]
      switch r[0] {
      case 0x0d33: values = [2048]
      case 0x0d3a: values = [UInt32](repeating: UInt32(GLESState.maximumViewportDimension), count: 2)
      case 0x0d36, 0x0d38, 0x0d39: values = [UInt32(GLESState.maximumMatrixStackDepth)]
      case 0x84e2: values = [UInt32(gl.textureUnits.count)]
      case 0x84e0: values = [0x84c0 + UInt32(gl.activeTexture)]
      case 0x84e1: values = [0x84c0 + UInt32(gl.clientActiveTexture)]
      case 0x0d31: values = [8]
      case 0x0b21: values = [UInt32(clamping: Int64(min(Double(Int32.max), Double(gl.lineWidth.rounded()))))]
      case 0x846e: values = [1, UInt32(GLESState.maximumLineWidth)]
      case 0x0d50, 0x0d52: values = [5]
      case 0x0d51: values = [6]
      case 0x0d53: values = [0]
      case 0x0d57: values = [8]
      case 0x0b91: values = [gl.clearStencil & 0xff]
      case 0x0b92: values = [gl.stencil.function]
      case 0x0b93: values = [gl.stencil.readMask]
      case 0x0b94: values = [gl.stencil.fail]
      case 0x0b95: values = [gl.stencil.depthFail]
      case 0x0b96: values = [gl.stencil.pass]
      case 0x0b97: values = [gl.stencil.reference]
      case 0x0b98: values = [gl.stencil.writeMask]
      case 0x0b90: values = [gl.enabled.contains(0x0b90) ? 1 : 0]
      case 0x86a2: values = [UInt32(ATCTexture.formats.count)]
      case 0x86a3: values = ATCTexture.formats
      case 0x0d56: values = [24]
      case 0x0ba2: values = (0..<4).map { UInt32(bitPattern: gl.viewport[$0]) }
      case 0x0ba0: values = [gl.matrixMode]
      case 0x8069: values = [gl.boundTexture]
      case 0x8894: values = [gl.arrayBuffer]
      case 0x8895: values = [gl.elementBuffer]
      case 0x8896: values = [gl.arrays[0x8074]?.buffer ?? 0]
      case 0x8897: values = [gl.arrays[0x8075]?.buffer ?? 0]
      case 0x8898: values = [gl.arrays[0x8076]?.buffer ?? 0]
      case 0x889a: values = [gl.textureUnits[gl.clientActiveTexture].array?.buffer ?? 0]
      default: throw EmulationError.unsupported("glGetIntegerv " + r[0].hex)
      }
      _ = try memory.region(r[1], values.count * 4)
      for (i, v) in values.enumerated() { try memory.write32(r[1] + UInt32(i * 4), v) }
    case 0x9c:
      let value: String
      switch r[0] {
      case 0x1f00: value = "ZeeSwift"
      case 0x1f01: value = "Original HLE / Metal 4"
      case 0x1f02: value = "OpenGL ES-CL 1.0"
      // The original BREW extension resolver searches for space-terminated tokens.
      // Older Zeebo modules query the ATI name. BREW glESext.h assigns its
      // RGB/RGBA formats the same 0x8c92/0x8c93 tokens handled by our ATC decoder.
      case 0x1f03: value = "GL_OES_draw_texture GL_ATI_imageon_misc GL_ARB_vertex_buffer_object GL_AMD_compressed_ATC_texture GL_ATI_texture_compression_atitc "
      default:
        gl.setError(0x0500)
        cpu.r[0] = 0
        return
      }
      cpu.r[0] = try guestString(value)
    case 0xa0: gl.parameters[r[0]] = [r[1]]  // Hint affects quality only.
    case 0xac, 0xb0, 0xc4, 0xc8:
      let light = offset == 0xac || offset == 0xb0
      let vectorCall = offset == 0xb0 || offset == 0xc8
      guard light ? (0x4000..<0x4008).contains(r[0]) : r[0] == 0x0408,
        let count = light ? GLESState.lightParameterCount(r[1]) : GLESState.materialParameterCount(r[1]),
        vectorCall || count == 1 else { gl.setError(0x0500); return }
      let values = try (vectorCall ? vector(r[2], count) : [r[2]]).map(number)
      if light { gl.setLight(Int(r[0] - 0x4000), parameter: r[1], values: values) }
      else { gl.setMaterial(r[1], values: values) }
    case 0xb4:
      let width = try fixed(0)
      guard width.isFinite, width > 0 else { gl.setError(0x0501); return }
      gl.lineWidth = width
    case 0xe8:
      if try fixed(0) != 1 { throw EmulationError.unsupported("GL line/point size") }
    case 0xb8: gl.matrix = matrix_identity_float4x4
    case 0xbc, 0xd0:
      let v = try vector(r[0], 16).map(number)
      let m = simd_float4x4(
        SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]),
        SIMD4(v[8], v[9], v[10], v[11]), SIMD4(v[12], v[13], v[14], v[15]))
      if offset == 0xbc { gl.matrix = m } else { gl.multiply(m) }
    case 0xcc:
      if (0x1700...0x1702).contains(r[0]) { gl.matrixMode = r[0] } else { gl.setError(0x0500) }
    case 0xd4:
      if r[0] >= 0x84c0 && r[0] < 0x84c0 + UInt32(gl.textureUnits.count) {
        gl.textureUnits[Int(r[0] - 0x84c0)].coordinate = SIMD4(
          try fixed(1), try fixed(2), try fixed(3), try fixed(4))
      } else {
        gl.setError(0x0500)
      }
    case 0xd8: gl.normal = SIMD3(try fixed(0), try fixed(1), try fixed(2))
    case 0xdc:
      guard [UInt32(0x1400), 0x1402, 0x1406, 0x140c].contains(r[0]) else { gl.setError(0x0500); return }
      try setArray(0x8075, size: 3, type: r[0], stride: r[1], address: r[2])
    case 0xe4:
      if r[0] == 0x0cf5, [1, 2, 4, 8].contains(r[1]) {
        gl.unpackAlignment = Int(r[1])
      } else {
        gl.setError(0x0500)
      }
    case 0xec: gl.parameters[0x8038] = [r[0], r[1]]
    case 0xf0:
      if gl.matrixStack.count > 1 {
        gl.matrixStack.removeLast()
      } else {
        gl.setError(0x0504)
      }
    case 0xf4:
      if gl.matrixStack.count < GLESState.maximumMatrixStackDepth {
        gl.matrixStack.append(gl.matrix)
      } else {
        gl.setError(0x0503)
      }
    case 0xfc:
      let axis = SIMD3(try fixed(1), try fixed(2), try fixed(3))
      if simd_length(axis) > 0 {
        gl.multiply(
          simd_float4x4(
            simd_quatf(angle: try fixed(0) * Float.pi / 180, axis: simd_normalize(axis))))
      }
    case 0x100: gl.parameters[0x80aa] = [r[0], r[1]]
    case 0x104:
      var m = matrix_identity_float4x4
      m.columns.0.x = try fixed(0)
      m.columns.1.y = try fixed(1)
      m.columns.2.z = try fixed(2)
      gl.multiply(m)
    case 0x108:
      gl.scissor = SIMD4(
        Int32(bitPattern: r[0]), Int32(bitPattern: r[1]), Int32(bitPattern: r[2]),
        Int32(bitPattern: r[3]))
    case 0x110:
      guard (0x0200...0x0207).contains(r[0]) else { gl.setError(0x0500); return }
      gl.stencil.function = r[0]
      gl.stencil.reference = UInt32(max(0, min(255, Int32(bitPattern: r[1]))))
      gl.stencil.readMask = r[2] & 0xff
    case 0x114: gl.stencil.writeMask = r[0] & 0xff
    case 0x118:
      let operations: Set<UInt32> = [0, 0x1e00, 0x1e01, 0x1e02, 0x1e03, 0x150a, 0x8507, 0x8508]
      guard r.prefix(3).allSatisfy({ operations.contains($0) }) else { gl.setError(0x0500); return }
      gl.stencil.fail = r[0]; gl.stencil.depthFail = r[1]; gl.stencil.pass = r[2]
    case 0x11c: try setArray(0x8078, size: Int(r[0]), type: r[1], stride: r[2], address: r[3])
    case 0x120, 0x124:
      try textureEnvironment(target: r[0], name: r[1], value: r[2],
        format: floatingPoint ? .float : .fixed, vector: offset == 0x124)
    case 0x128: try uploadGLTexture()
    case 0x12c:
      try textureParameter(target: r[0], name: r[1], value: r[2],
        format: floatingPoint ? .float : .fixed, vector: false, query: false)
    case 0x130: try updateGLTexture()
    case 0x134:
      var m = matrix_identity_float4x4
      m.columns.3 = SIMD4(try fixed(0), try fixed(1), try fixed(2), 1)
      gl.multiply(m)
    case 0x138: try setArray(0x8074, size: Int(r[0]), type: r[1], stride: r[2], address: r[3])
    case 0x13c:
      let width = Int32(bitPattern: r[2]), height = Int32(bitPattern: r[3])
      guard width >= 0, height >= 0 else { gl.setError(0x0501); return }
      gl.viewport = SIMD4(
        Int32(bitPattern: r[0]), Int32(bitPattern: r[1]),
        min(width, GLESState.maximumViewportDimension), min(height, GLESState.maximumViewportDimension))
    default: throw EmulationError.hle("IGL+" + offset.hex, cpu.r[14])
    }
  }
  func uploadGLTexture() throws {
    let target = try argument(0)
    let level = try argument(1)
    let width = Int(try argument(3))
    let height = Int(try argument(4))
    let border = try argument(5)
    let format = try argument(6)
    let type = try argument(7)
    let pixels = try argument(8)
    guard target == 0x0de1 else {
      gl.setError(0x0500)
      return
    }
    if ATCTexture.formats.contains(try argument(2)) || ATCTexture.formats.contains(format) {
      gl.setError(0x0502)
      return
    }
    guard level <= 11, width <= 2048 >> level, height <= 2048 >> level, border == 0 else {
      gl.setError(0x0501)
      return
    }
    guard let output = try decodeGLPixels(
      width: width, height: height, format: format, type: type, pixels: pixels,
      allowNull: true) else { return }
    let image = GLESTexture(
      width: width, height: height, pixels: output, format: format)
    var texture = gl.textures[gl.boundTexture] ?? GLESTexture(width: 0, height: 0, pixels: Data())
    texture.setImage(image.images[0]!, level: Int(level))
    if level == 0 && texture.parameters[0x8191] == 1 { texture.generateMipmaps() }
    gl.textures[gl.boundTexture] = texture
  }

  // IGL uses the C ABI; QGLES adapts pMe and stack arguments before dispatch.
  func updateGLTexture() throws {
    let target = try argument(0), level = try argument(1)
    let x = Int(Int32(bitPattern: try argument(2)))
    let y = Int(Int32(bitPattern: try argument(3)))
    let width = Int(Int32(bitPattern: try argument(4)))
    let height = Int(Int32(bitPattern: try argument(5)))
    let format = try argument(6), type = try argument(7), pixels = try argument(8)
    guard target == 0x0de1 else { gl.setError(0x0500); return }
    if ATCTexture.formats.contains(format)
      || ATCTexture.formats.contains(gl.textures[gl.boundTexture]?.images[Int(level)]?.internalFormat ?? 0) {
      gl.setError(0x0502); return
    }
    guard level <= 11, x >= 0, y >= 0, width >= 0, height >= 0 else {
      gl.setError(0x0501); return
    }
    guard var texture = gl.textures[gl.boundTexture], let image = texture.images[Int(level)],
      image.width > 0, image.height > 0, image.internalFormat == format else {
      gl.setError(0x0502); return
    }
    guard x + width <= image.width, y + height <= image.height else {
      gl.setError(0x0501); return
    }
    guard let patch = try decodeGLPixels(
      width: width, height: height, format: format, type: type, pixels: pixels,
      allowNull: false) else { return }
    guard width > 0, height > 0 else { return }
    var updated = image.pixels
    updated.withUnsafeMutableBytes { destination in
      patch.withUnsafeBytes { source in
        for row in 0..<height {
          destination.baseAddress!.advanced(by: ((y + row) * image.width + x) * 4)
            .copyMemory(from: source.baseAddress!.advanced(by: row * width * 4), byteCount: width * 4)
        }
      }
    }
    texture.setImage(.init(width: image.width, height: image.height, pixels: updated,
      format: image.format, internalFormat: image.internalFormat), level: Int(level))
    if level == 0 && texture.parameters[0x8191] == 1 { texture.generateMipmaps() }
    gl.textures[gl.boundTexture] = texture
  }

  /// Decode a complete, checked guest pixel rectangle before changing texture state.
  /// Row padding is skipped and no padding is required after the final row.
  private func decodeGLPixels(width: Int, height: Int, format: UInt32, type: UInt32,
    pixels: UInt32, allowNull: Bool) throws -> Data? {
    let components: Int
    switch format {
    case 0x1906, 0x1909: components = 1
    case 0x190a: components = 2
    case 0x1907: components = 3
    case 0x1908: components = 4
    default: gl.setError(0x0500); return nil
    }
    let packed = [UInt32(0x8363), 0x8033, 0x8034].contains(type)
    guard packed || type == 0x1401 else { gl.setError(0x0500); return nil }
    guard !packed || (type == 0x8363 ? format == 0x1907 : format == 0x1908) else {
      gl.setError(0x0502); return nil
    }
    var output = Data(repeating: 0, count: width * height * 4)
    guard width > 0, height > 0, !allowNull || pixels != 0 else { return output }
    let bytesPerPixel = packed ? 2 : components
    let rowBytes = width * bytesPerPixel
    let stride = (rowBytes + gl.unpackAlignment - 1) & ~(gl.unpackAlignment - 1)
    let region = try memory.region(pixels, (height - 1) * stride + rowBytes)
    let source = region.bytes.advanced(by: Int(pixels - region.base))
    output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
      if packed {
        PackedPixels.decode(source: source, destination: destination.baseAddress!,
          width: width, height: height, stride: stride, type: type)
        return
      }
      let bytes = destination.bindMemory(to: UInt8.self)
      for y in 0..<height {
        for x in 0..<width {
          let p = source.advanced(by: y * stride + x * bytesPerPixel)
          var color = SIMD4<UInt32>(0, 0, 0, 255)
          do {
            let v = UInt32(p.load(as: UInt8.self))
            switch format {
            case 0x1906: color = SIMD4(255, 255, 255, v)
            case 0x1909, 0x190a:
              color = SIMD4(v, v, v, format == 0x190a ? UInt32(p.load(fromByteOffset: 1, as: UInt8.self)) : 255)
            default:
              color = SIMD4(v, UInt32(p.load(fromByteOffset: 1, as: UInt8.self)),
                UInt32(p.load(fromByteOffset: 2, as: UInt8.self)),
                components == 4 ? UInt32(p.load(fromByteOffset: 3, as: UInt8.self)) : 255)
            }
          }
          for c in 0..<4 { bytes[(y * width + x) * 4 + c] = UInt8(color[c]) }
        }
      }
    }
    return output
  }

}
