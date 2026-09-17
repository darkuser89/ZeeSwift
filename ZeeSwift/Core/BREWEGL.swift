import Foundation

extension BREWRuntime {
  // Original EGLext.h: eglGetColorBufferQUALCOMM(void) returns native storage.
  // Z-Wheel copies top-down RGB565 rows both into and out of that storage.
  func syncEGLColorBuffer() throws {
    guard eglColorBuffer != 0, !eglColorBufferSnapshot.isEmpty, let backend = gl.backend else { return }
    let pixels = try memory.data(eglColorBuffer, count: eglColorBufferSnapshot.count)
    guard pixels != eglColorBufferSnapshot else { return }
    try backend.writeColorBuffer(pixels, previous: eglColorBufferSnapshot)
    eglColorBufferSnapshot = pixels
  }
  func releaseEGLColorBuffer() throws {
    if eglColorBuffer != 0 { try free(eglColorBuffer) }
    eglColorBuffer = 0; eglColorBufferSnapshot = Data()
  }
  func getEGLColorBuffer() throws -> UInt32 {
    guard gl.eglCurrent != 0, gl.eglSurface != 0, let backend = gl.backend else { return 0 }
    try syncEGLColorBuffer()
    let bgra = try backend.readback()
    let count = Int(gl.surfaceSize.x) * Int(gl.surfaceSize.y)
    guard bgra.count == count * 4 else { throw EmulationError.invalid("EGL color buffer dimensions") }
    if eglColorBuffer == 0 {
      eglColorBuffer = try allocate(UInt32(count * 2))
      guard eglColorBuffer != 0 else { return 0 }
    }
    var pixels = Data(count: count * 2)
    pixels.withUnsafeMutableBytes { destination in
      bgra.withUnsafeBytes { source in
        let src = source.bindMemory(to: UInt8.self), dst = destination.bindMemory(to: UInt8.self)
        for i in 0..<count {
          let native = UInt16(src[i * 4 + 2] >> 3) << 11 | UInt16(src[i * 4 + 1] >> 2) << 5 | UInt16(src[i * 4] >> 3)
          dst[i * 2] = UInt8(truncatingIfNeeded: native); dst[i * 2 + 1] = UInt8(native >> 8)
        }
      }
    }
    try memory.write(eglColorBuffer, data: pixels); eglColorBufferSnapshot = pixels
    return eglColorBuffer
  }
  func dispatchEGL(_ offset: UInt32) throws {
    let r = (0..<4).map { cpu.r[$0] }
    let config: [UInt32: UInt32] = [
      0x3020: 16, 0x3021: 0, 0x3022: 5, 0x3023: 6, 0x3024: 5, 0x3025: 24, 0x3026: 8, 0x3027: 0x3038,
      0x3028: 1, 0x3031: 0, 0x3032: 0, 0x3033: 5, 0x302e: 0,
      0x302a: 480, 0x302b: 640 * 480, 0x302c: 640,
    ]
    func fail(_ error: UInt32) {
      gl.eglError = error
      cpu.r[0] = 0
    }
    if offset >= 0x14 && offset != 0x20 && offset != 0x58 && offset != 0x50 && offset != 0x54
      && offset != 0x60 && offset != 0x64
    {
      guard r[0] == 1 else {
        fail(0x3008)
        return
      }
    }
    switch offset {
    case 0: cpu.r[0] = 2
    case 4: cpu.r[0] = 1
    case 8:
      try memory.write32(r[2], r[1] == 0x0101_4bc4 ? eglObject : 0)
      cpu.r[0] = r[1] == 0x0101_4bc4 ? 0 : 3
    case 0x0c:
      cpu.r[0] = gl.eglError
      gl.eglError = 0x3000
    case 0x10: cpu.r[0] = 1
    case 0x14:
      gl.eglInitialized = true
      if r[1] != 0 { try memory.write32(r[1], 1) }
      if r[2] != 0 { try memory.write32(r[2], 0) }
      cpu.r[0] = 1
    case 0x18:
      try releaseEGLColorBuffer()
      gl.eglInitialized = false
      gl.eglContext = 0
      gl.eglSurface = 0
      gl.eglScale = GLESSurfaceScale()
      gl.eglScaleEnabled = false
      gl.eglCurrent = 0
      cpu.r[0] = 1
    case 0x1c:
      switch r[1] {
      case 0x3053: cpu.r[0] = try guestString("ZeeSwift")
      case 0x3054: cpu.r[0] = try guestString("1.0")
      case 0x3055: cpu.r[0] = try guestString("EGL_QUALCOMM_surface_scale EGL_QUALCOMM_get_color_buffer ")
      default: fail(0x300c)
      }
    case 0x20:
      let functions: [String: UInt32] = [
        "eglSurfaceScaleEnableQUALCOMM": 0xf014_000c,
        "eglSetSurfaceScaleQUALCOMM": 0xf014_0010,
        "eglGetSurfaceScaleQUALCOMM": 0xf014_0014,
        "eglGetSurfaceScaleCapsQUALCOMM": 0xf014_0018,
        "eglGetColorBufferQUALCOMM": 0xf014_001c,
        "glDrawTexsOES": 0xf01e_0000, "glDrawTexiOES": 0xf01e_0004,
        "glDrawTexxOES": 0xf01e_0008, "glDrawTexsvOES": 0xf01e_000c,
        "glDrawTexivOES": 0xf01e_0010, "glDrawTexxvOES": 0xf01e_0014,
        "glDrawTexfOES": 0xf01e_0018, "glDrawTexfvOES": 0xf01e_001c,
        "glTexParameterfv": 0xf01e_0020, "glTexParameteriv": 0xf01e_0024,
        "glTexParameterxv": 0xf01e_0028, "glGetTexParameterfv": 0xf01e_002c,
        "glGetTexParameteriv": 0xf01e_0030, "glGetTexParameterxv": 0xf01e_0034,
        "glTexParameteri": 0xf01e_0038,
        "glGetPointerv": 0xf01e_003c, "glTexEnvi": 0xf01e_0040,
        "glTexEnviv": 0xf01e_0044, "glGetMaterialfv": 0xf01e_0048,
      ]
      let bufferMethods = ["BindBuffer", "DeleteBuffers", "GenBuffers", "BufferData", "BufferSubData",
        "IsBuffer", "GetBufferSubData", "MapBuffer", "UnmapBuffer", "GetBufferParameteriv", "GetBufferPointerv"]
      guard r[0] != 0 else { cpu.r[0] = 0; return }
      let name = try memory.string(r[0])
      if let method = bufferMethods.firstIndex(where: { name == "gl" + $0 || name == "gl" + $0 + "ARB" }) {
        cpu.r[0] = 0xf01e004c + UInt32(method * 4)
      } else { cpu.r[0] = functions[name] ?? 0 }
    case 0x24, 0x28:
      let output = offset == 0x24 ? r[1] : r[2]
      let size = offset == 0x24 ? r[2] : r[3]
      let count = try offset == 0x24 ? r[3] : argument(4)
      var matches = true
      if offset == 0x28 && r[1] != 0 {
        var terminated = false
        for i in 0..<128 {
          let key = try memory.read32(r[1] + UInt32(i * 8))
          if key == 0x3038 {
            terminated = true
            break
          }
          let value = try memory.read32(r[1] + UInt32(i * 8 + 4))
          log.append("EGL config " + key.hex + " requested " + value.hex)
          if value == UInt32.max { continue }
          guard let actual = config[key] else {
            fail(0x3004)
            return
          }
          if key == 0x3033 {
            matches = matches && actual & value == value
          } else if key == 0x3028 || key == 0x3027 {
            matches = matches && actual == value
          } else {
            matches = matches && actual >= value
          }
        }
        guard terminated else { throw EmulationError.invalid("EGL attribute list") }
      }
      try memory.write32(count, matches ? 1 : 0)
      if matches && output != 0 && size > 0 { try memory.write32(output, 1) }
      cpu.r[0] = 1
    case 0x2c:
      guard r[1] == 1, let value = config[r[2]] else {
        fail(0x3004)
        return
      }
      try memory.write32(r[3], value)
      cpu.r[0] = 1
    case 0x30:
      guard gl.eglInitialized, r[1] == 1 else {
        fail(0x3005)
        return
      }
      try releaseEGLColorBuffer()
      gl.eglSurface = 2
      gl.eglSurfaceSize = SIMD2(640, 480)
      gl.eglScale = GLESSurfaceScale()
      gl.eglScaleEnabled = false
      cpu.r[0] = 2
    case 0x38:
      guard gl.eglInitialized, r[1] == 1 else {
        fail(0x3005)
        return
      }
      var width: UInt32 = 0
      var height: UInt32 = 0
      if r[2] != 0 {
        var terminated = false
        for i in 0..<128 {
          let key = try memory.read32(r[2] + UInt32(i * 8))
          if key == 0x3038 {
            terminated = true
            break
          }
          let value = try memory.read32(r[2] + UInt32(i * 8 + 4))
          switch key {
          case 0x3057: width = value
          case 0x3056: height = value
          case 0x3058: break
          default:
            fail(0x3004)
            return
          }
        }
        guard terminated else { throw EmulationError.invalid("EGL pbuffer attributes") }
      }
      guard width > 0, height > 0, width <= 640, height <= 480 else {
        fail(0x3003)
        return
      }
      // The GLES backend renders into a real offscreen Metal color/depth target.
      try releaseEGLColorBuffer()
      gl.eglSurface = 2
      gl.eglSurfaceSize = SIMD2(Int32(width), Int32(height))
      let rectangle = SIMD4<Int32>(0, 0, Int32(width), Int32(height))
      gl.eglScale = GLESSurfaceScale(source: rectangle, destination: rectangle)
      gl.eglScaleEnabled = false
      cpu.r[0] = 2
    case 0x3c:
      guard r[1] == gl.eglSurface, r[1] != 0 else {
        fail(0x300d)
        return
      }
      try releaseEGLColorBuffer()
      gl.eglSurface = 0
      gl.eglScale = GLESSurfaceScale()
      gl.eglScaleEnabled = false
      cpu.r[0] = 1
    case 0x40:
      guard r[1] == gl.eglSurface, r[1] != 0 else {
        fail(0x300d)
        return
      }
      let value: UInt32
      switch r[2] {
      case 0x3057: value = UInt32(gl.eglSurfaceSize.x)
      case 0x3056: value = UInt32(gl.eglSurfaceSize.y)
      case 0x3028: value = 1
      default:
        fail(0x3004)
        return
      }
      try memory.write32(r[3], value)
      cpu.r[0] = 1
    case 0x44:
      guard gl.eglInitialized, r[1] == 1, r[2] == 0 else {
        fail(0x3005)
        return
      }
      gl.eglContext = 3
      gl.contextHasBeenCurrent = false
      cpu.r[0] = 3
    case 0x48:
      guard r[1] == gl.eglContext, r[1] != 0 else {
        fail(0x3006)
        return
      }
      gl.eglContext = 0
      gl.eglCurrent = 0
      cpu.r[0] = 1
    case 0x4c:
      if r[1] == 0 && r[2] == 0 && r[3] == 0 {
        gl.eglCurrent = 0
        cpu.r[0] = 1
        return
      }
      guard r[3] == gl.eglContext, r[1] == gl.eglSurface, r[2] == gl.eglSurface, r[3] != 0 else {
        fail(0x3009)
        return
      }
      try gl.backend?.resize(width: Int(gl.eglSurfaceSize.x), height: Int(gl.eglSurfaceSize.y))
      gl.surfaceSize = gl.eglSurfaceSize
      if !gl.contextHasBeenCurrent {
        gl.viewport = gl.surfaceRectangle; gl.scissor = gl.surfaceRectangle
        gl.contextHasBeenCurrent = true
      }
      gl.eglCurrent = r[3]
      cpu.r[0] = 1
    case 0x50: cpu.r[0] = gl.eglCurrent
    case 0x54: cpu.r[0] = gl.eglCurrent == 0 ? 0 : gl.eglSurface
    case 0x58: cpu.r[0] = gl.eglCurrent == 0 ? 0 : 1
    case 0x5c:
      guard r[1] == gl.eglContext, r[2] == 0x3028 else {
        fail(0x3004)
        return
      }
      try memory.write32(r[3], 1)
      cpu.r[0] = 1
    case 0x60, 0x64:
      try syncEGLColorBuffer()
      try gl.backend?.finish()  // eglWaitGL / eglWaitNative
      if eglColorBuffer != 0 { _ = try getEGLColorBuffer() }
      cpu.r[0] = 1
    case 0x68:
      guard gl.eglCurrent != 0, r[1] == gl.eglSurface else {
        fail(0x300d)
        return
      }
      guard let backend = gl.backend else {
        throw EmulationError.unsupported("EGL SwapBuffers requires Metal 4")
      }
      try syncEGLColorBuffer()
      frames.publish(
        try backend.presentation(scale: gl.eglScaleEnabled ? gl.eglScale : nil), session: frameSession)
      guestFrames &+= 1
      cpu.r[0] = 1
    default: throw EmulationError.hle("IEGL+" + offset.hex, cpu.r[14])
    }
  }
}
