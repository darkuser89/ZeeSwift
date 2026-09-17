import Foundation

extension BREWRuntime {
  enum GLParameterFormat { case integer, fixed, float }

  func textureEnvironment(target: UInt32, name: UInt32, value: UInt32,
    format: GLParameterFormat, vector: Bool) throws {
    let scalarNames: Set<UInt32> = [0x2200, 0x8571, 0x8572, 0x8573, 0x0d1c,
      0x8580, 0x8581, 0x8582, 0x8588, 0x8589, 0x858a,
      0x8590, 0x8591, 0x8592, 0x8598, 0x8599, 0x859a]
    guard target == 0x2300, scalarNames.contains(name) || (vector && name == 0x2201)
    else { gl.setError(0x0500); return }
    if name == 0x2201 {
      _ = try memory.region(value, 16)
      let numbers = try (0..<4).map { index -> Float in
        let raw = try memory.read32(value + UInt32(index * 4))
        let number: Float
        switch format {
        case .integer: number = Float((2 * Double(Int32(bitPattern: raw)) + 1) / 4_294_967_295)
        case .fixed: number = GLESState.fixed(raw)
        case .float: number = Float(bitPattern: raw)
        }
        return min(1, max(0, number))
      }
      gl.textureEnvironmentColor = SIMD4(numbers[0], numbers[1], numbers[2], numbers[3])
      return
    }
    let raw = try vector ? memory.read32(value) : value
    let scale = name == 0x8573 || name == 0x0d1c
    let number: Double
    switch format {
    case .float: number = Double(Float(bitPattern: raw))
    case .fixed: number = scale ? Double(GLESState.fixed(raw)) : Double(raw)
    case .integer: number = Double(Int32(bitPattern: raw))
    }
    guard number.isFinite, number >= 0, number <= Double(UInt32.max), number.rounded(.towardZero) == number
    else { gl.setError(scale ? 0x0501 : 0x0500); return }
    let item = UInt32(number)
    var combine = gl.textureUnits[gl.activeTexture].combine
    let operations: Set<UInt32> = [0x1e01, 0x2100, 0x0104, 0x8574, 0x8575, 0x84e7]
    switch name {
    case 0x2200:
      guard [UInt32(0x2100),0x2101,0x1e01,0x0be2,0x0104,0x8570].contains(item)
      else { gl.setError(0x0500); return }
      gl.textureEnvironment = item
    case 0x8571, 0x8572:
      guard operations.contains(item) || (name == 0x8571 && (item == 0x86ae || item == 0x86af))
      else { gl.setError(0x0500); return }
      combine.functions[name == 0x8571 ? 0 : 1] = item
    case 0x8573, 0x0d1c:
      guard item == 1 || item == 2 || item == 4 else { gl.setError(0x0501); return }
      combine.functions[name == 0x8573 ? 2 : 3] = item
    case 0x8580...0x8582, 0x8588...0x858a:
      guard [UInt32(0x1702),0x8576,0x8577,0x8578].contains(item)
      else { gl.setError(0x0500); return }
      if name <= 0x8582 { combine.sourceRGB[Int(name - 0x8580)] = item }
      else { combine.sourceAlpha[Int(name - 0x8588)] = item }
    case 0x8590...0x8592:
      guard (0x0300...0x0303).contains(item) else { gl.setError(0x0500); return }
      combine.operandRGB[Int(name - 0x8590)] = item
    case 0x8598...0x859a:
      guard item == 0x0302 || item == 0x0303 else { gl.setError(0x0500); return }
      combine.operandAlpha[Int(name - 0x8598)] = item
    default: gl.setError(0x0500); return
    }
    gl.textureUnits[gl.activeTexture].combine = combine
  }

  // Original AEEGLESImageonEXT.h: the Zeebo's GLES 1.0 vendor interface exposes
  // texture parameter vectors separately from IGLES11. Share the actual state
  // implementation; unsupported palette/vendor-mesh features stay explicit.
  func dispatchImageonGraphics(_ offset: UInt32) throws {
    if offset <= 8 {
      try dispatchQGraphics(egl: false, offset: offset)
      return
    }
    if (0x1c...0x30).contains(offset), offset % 4 == 0 {
      let method = Int((offset - 0x1c) / 4)
      try dispatchBufferInterface(method)
      return
    }
    if offset == 0x40 {
      let pointer: UInt32
      switch cpu.r[1] {
      case 0x808e: pointer = gl.arrays[0x8074]?.address ?? 0
      case 0x808f: pointer = gl.arrays[0x8075]?.address ?? 0
      case 0x8090: pointer = gl.arrays[0x8076]?.address ?? 0
      case 0x8092: pointer = gl.textureUnits[gl.clientActiveTexture].array?.address ?? 0
      default: gl.setError(0x0500); cpu.r[0] = 0; return
      }
      try memory.write32(cpu.r[2], pointer)
      cpu.r[0] = 0
      return
    }
    if offset == 0x44 || offset == 0x48 {
      defer { cpu.r[0] = 0 }
      try textureEnvironment(target: cpu.r[1], name: cpu.r[2], value: cpu.r[3],
        format: .integer, vector: offset == 0x48)
      return
    }
    if offset == 0x5c {
      defer { cpu.r[0] = 0 }
      guard cpu.r[1] == 0x0404 || cpu.r[1] == 0x0405 else { gl.setError(0x0500); return }
      let values: [Float]
      let color: SIMD4<Float>
      switch cpu.r[2] {
      case 0x1200: color = gl.lighting.ambient
      case 0x1201: color = gl.lighting.diffuse
      case 0x1202: color = gl.lighting.specular
      case 0x1600: color = gl.lighting.emission
      case 0x1601: color = SIMD4(repeating: gl.lighting.controls.w)
      default: gl.setError(0x0500); return
      }
      values = cpu.r[2] == 0x1601 ? [color.x] : (0..<4).map { color[$0] }
      _ = try memory.region(cpu.r[3], values.count * 4)
      for (index, value) in values.enumerated() {
        try memory.write32(cpu.r[3] + UInt32(index * 4), value.bitPattern)
      }
      return
    }
    guard [0x4c, 0x50, 0x54, 0x58, 0x60, 0x64, 0x68].contains(offset) else {
      throw EmulationError.hle("IGLESImageonExt+" + offset.hex, cpu.r[14])
    }
    let format: GLParameterFormat = [0x54, 0x64].contains(offset) ? .float
      : ([0x58, 0x68].contains(offset) ? .fixed : .integer)
    try textureParameter(target: cpu.r[1], name: cpu.r[2], value: cpu.r[3],
      format: format, vector: offset != 0x4c, query: offset >= 0x60)
    cpu.r[0] = 0
  }

  // Integer crop state belongs to the texture object, including texture zero.
  // Validate all components before changing state or writing a guest output.
  func textureParameter(target: UInt32, name: UInt32, value: UInt32,
    format: GLParameterFormat, vector: Bool, query: Bool) throws {
    guard target == 0x0de1 else { gl.setError(0x0500); return }
    let crop = name == 0x8b9d
    guard crop ? vector : [0x2800, 0x2801, 0x2802, 0x2803, 0x8191].contains(name) else {
      gl.setError(0x0500); return
    }
    var texture = gl.textures[gl.boundTexture] ?? GLESTexture(width: 0, height: 0, pixels: Data())
    let count = crop ? 4 : 1
    if query {
      _ = try memory.data(value, count: count * 4)
      for index in 0..<count {
        let number = crop ? texture.cropRectangle[index] : Int32(texture.parameters[name] ?? 0)
        let raw: UInt32
        switch format {
        case .integer: raw = UInt32(bitPattern: number)
        case .float: raw = Float(number).bitPattern
        case .fixed: raw = crop ? UInt32(bitPattern: number) &<< 16 : UInt32(bitPattern: number)
        }
        try memory.write32(value + UInt32(index * 4), raw)
      }
      return
    }
    let raw = try vector ? (0..<count).map { try memory.read32(value + UInt32($0 * 4)) } : [value]
    var converted: [Int32] = []
    for word in raw {
      let number: Double
      switch format {
      case .integer: number = Double(Int32(bitPattern: word))
      case .float: number = Double(Float(bitPattern: word)).rounded()
      case .fixed: number = crop ? (Double(Int32(bitPattern: word)) / 65536).rounded()
        : Double(Int32(bitPattern: word))
      }
      guard number.isFinite, number >= Double(Int32.min), number <= Double(Int32.max) else {
        gl.setError(0x0501); return
      }
      converted.append(Int32(number))
    }
    if crop {
      texture.cropRectangle = SIMD4(converted[0], converted[1], converted[2], converted[3])
    } else {
      let parameter = UInt32(bitPattern: converted[0])
      let legal: [UInt32]
      switch name {
      case 0x2800: legal = [0x2600, 0x2601]
      case 0x2801: legal = [0x2600, 0x2601, 0x2700, 0x2701, 0x2702, 0x2703]
      case 0x8191: legal = [0, 1]
      default: legal = [0x2901, 0x812f]
      }
      guard legal.contains(parameter) else { gl.setError(0x0500); return }
      texture.parameters[name] = parameter
    }
    gl.textures[gl.boundTexture] = texture
  }

  // AEEGLES11Ext.h declares four palette methods before the eight DrawTex methods.
  // Palette functionality is not advertised and remains an explicit missing HLE.
  func dispatchDrawTexture(_ offset: UInt32, qualcomm: Bool) throws {
    if !qualcomm, offset >= 0x4c, offset <= 0x74, offset % 4 == 0 {
      try dispatchBuffer(Int((offset - 0x4c) / 4))
      return
    }
    if qualcomm && offset <= 8 {
      try dispatchQGraphics(egl: false, offset: offset)
      return
    }
    if !qualcomm && [0x3c, 0x40, 0x44, 0x48].contains(offset) {
      let methods: [UInt32] = [0x40, 0x44, 0x48, 0x5c]
      let args = try (0..<(offset == 0x3c ? 2 : 3)).map { try argument($0) }
      _ = try graphicsCall([imageonExtensionObject] + args) {
        try dispatchImageonGraphics(methods[Int((offset - 0x3c) / 4)])
      }
      return
    }
    if !qualcomm && offset >= 0x20 && offset <= 0x38 {
      let format: GLParameterFormat = [0x20, 0x2c].contains(offset) ? .float
        : ([0x28, 0x34].contains(offset) ? .fixed : .integer)
      try textureParameter(target: cpu.r[0], name: cpu.r[1], value: cpu.r[2],
        format: format, vector: offset != 0x38, query: offset >= 0x2c && offset <= 0x34)
      return
    }
    guard offset % 4 == 0, qualcomm ? (0x1c...0x38).contains(offset) : offset < 0x20 else {
      throw EmulationError.hle("GL DrawTexture+" + offset.hex, cpu.r[14])
    }
    let method = Int((qualcomm ? offset - 0x1c : offset) / 4)
    let vector = [3, 4, 5, 7].contains(method)
    let short = method == 0 || method == 3
    let fixed = method == 2 || method == 5
    let float = method == 6 || method == 7
    let first = qualcomm ? 1 : 0
    let pointer = try vector ? argument(first) : 0
    let values = try (0..<5).map { index -> Float in
      let word: UInt32
      if vector {
        let address = pointer + UInt32(index * (short ? 2 : 4))
        word = try short ? UInt32(memory.read16(address)) : memory.read32(address)
      } else { word = try argument(first + index) }
      if short { return Float(Int16(truncatingIfNeeded: word)) }
      if fixed { return GLESState.fixed(word) }
      if float { return Float(bitPattern: word) }
      return Float(Int32(bitPattern: word))
    }
    try syncEGLColorBuffer()
    try gl.drawTexture(x: values[0], y: values[1], z: values[2], width: values[3], height: values[4])
    if qualcomm { cpu.r[0] = 0 }
  }

  // Qualcomm's BREW graphics interfaces prepend pMe and return API values through
  // a final pointer. The older IGL/IEGL interfaces use the GL C calling convention.
  // These tables describe ABI arguments from the original interface declarations only.
  private static let glArgumentCounts = [
    1, 2, 2, 2, 1, 4, 1, 1, 1, 4, 4, 4, 8, 9, 8, 8, 1, 2, 1, 1, 2, 1, 1, 3, 4, 1, 1, 0, 0, 2, 2, 1,
    6, 2, 0, 2, 1,
    2, 2, 2, 3, 3, 1, 0, 1, 1, 3, 3, 1, 1, 5, 3, 3, 6, 2, 1, 2, 0, 0, 7, 4, 2, 3, 4, 1, 3, 1, 3, 4,
    3, 3, 9, 3, 9, 3, 4, 4,
  ]
  private static let eglArgumentCounts = [
    0, 1, 3, 1, 2, 4, 5, 4, 4, 4, 3, 2, 4, 4, 2, 4, 0, 1, 0, 4, 0, 1, 2, 3,
  ]
  private static let floatGLMethods: [UInt32] = [
    0x10, 0x20, 0x24, 0x30, 0x5c, 0x80, 0x84, 0x8c, 0xa4, 0xa8, 0xac, 0xb0, 0xb4, 0xbc,
    0xc4, 0xc8, 0xd0, 0xd4, 0xd8, 0xe0, 0xe8, 0xec, 0xfc, 0x104, 0x120, 0x124, 0x12c, 0x134,
  ]

  /// Adapt argument registers without overwriting the caller's stack arguments.
  private func graphicsCall(_ args: [UInt32], body: () throws -> Void) throws -> UInt32 {
    let registers = (0..<16).map { cpu.r[$0] }
    let status = cpu.cpsr
    defer {
      for i in 0..<16 { cpu.r[i] = registers[i] }
      cpu.cpsr = status
    }
    cpu.r[13] -= 64
    for (index, value) in args.enumerated() {
      if index < 4 {
        cpu.r[index] = value
      } else {
        try memory.write32(cpu.r[13] + UInt32((index - 4) * 4), value)
      }
    }
    try body()
    return cpu.r[0]
  }

  private func dispatchBufferInterface(_ method: Int) throws {
    let count = method == 3 || method == 4 ? 4 : (method == 9 ? 3 : 2)
    let args = try (1...count).map { try argument($0) }
    let output = method == 5 ? cpu.r[2] : 0
    if method == 5 { _ = try memory.region(output, 1) }
    let value = try graphicsCall(args) { try dispatchBuffer(method) }
    if method == 5 { try memory.write8(output, value) }
    cpu.r[0] = 0
  }

  func dispatchQGraphics(egl: Bool, offset: UInt32) throws {
    // Original AEEGLES11.h appends these entries after the complete GLES10 table.
    if !egl && offset >= 0x1dc {
      let method: Int?
      switch offset {
      case 0x1dc: method = 0
      case 0x1e0: method = 3
      case 0x1e4: method = 4
      case 0x1f0: method = 1
      case 0x1f8: method = 9
      case 0x200: method = 2
      case 0x224: method = 5
      case 0x210: try dispatchImageonGraphics(0x40); return
      default: method = nil
      }
      if let method { try dispatchBufferInterface(method); return }
    }
    switch offset {
    case 0:
      cpu.r[0] = 2
      return
    case 4:
      cpu.r[0] = 1
      return
    case 8:
      let object: UInt32
      switch cpu.r[1] {
      case 0x0103_d8ed, 0x0103_d8ee: object = qeglObject
      case 0x0103_d8dd, 0x0103_d8ea: object = qglesObject
      case 0x0103_d8eb: object = qglesExtensionObject
      case 0x0105_8546, 0x0104_59b1: object = imageonExtensionObject
      case 0x0105_1834, 0x0104_34cc: object = qsurfaceObject
      default: object = 0
      }
      try memory.write32(cpu.r[2], object)
      cpu.r[0] = object == 0 ? 3 : 0
      log.append("QEGL QueryInterface " + cpu.r[1].hex + " → " + object.hex)
      return
    default: break
    }
    if !egl && [0x1cc, 0x1d8, 0x21c, 0x220, 0x240, 0x244, 0x248].contains(offset) {
      let format: GLParameterFormat = [0x1cc, 0x1d8].contains(offset) ? .float
        : ([0x220, 0x248].contains(offset) ? .fixed : .integer)
      try textureParameter(target: cpu.r[1], name: cpu.r[2], value: cpu.r[3],
        format: format, vector: offset != 0x240, query: [0x1cc, 0x21c, 0x220].contains(offset))
      cpu.r[0] = 0
      return
    }
    let legacyOffset: UInt32
    let arity: Int
    let floating: Bool
    let returnsValue: Bool
    if egl {
      let index = Int(offset / 4) - 3
      guard Self.eglArgumentCounts.indices.contains(index) else {
        throw EmulationError.hle("IEGL10+" + offset.hex, cpu.r[14])
      }
      arity = Self.eglArgumentCounts[index]
      // IEGL has an extra GetProcAddress at +0x20; IEGL10 does not.
      legacyOffset = offset >= 0x20 ? offset + 4 : offset
      floating = false
      returnsValue = true
    } else {
      if offset < 0x7c {
        let index = Int(offset / 4) - 3
        guard Self.floatGLMethods.indices.contains(index) else {
          throw EmulationError.hle("IGLES10+" + offset.hex, cpu.r[14])
        }
        legacyOffset = Self.floatGLMethods[index]
        floating = true
      } else if offset == 0x170 {
        legacyOffset = 0x100
        floating = true
      } else {
        guard offset <= 0x1b0 else { throw EmulationError.hle("IGLES10+" + offset.hex, cpu.r[14]) }
        legacyOffset = offset - (offset < 0x170 ? 0x70 : 0x74)
        floating = false
      }
      arity = Self.glArgumentCounts[Int(legacyOffset / 4) - 3]
      returnsValue = legacyOffset == 0x94 || legacyOffset == 0x9c
    }
    let args = try (0..<arity).map { try argument($0 + 1) }
    let output = try returnsValue ? argument(arity + 1) : 0
    if returnsValue && output == 0 {
      cpu.r[0] = 14
      return
    }
    let result = try graphicsCall(args) {
      if egl {
        try dispatchEGL(legacyOffset)
      } else {
        try dispatchGL(legacyOffset, floatingPoint: floating)
      }
    }
    if returnsValue { try memory.write32(output, result) }
    if egl {
      let swaps = calls["IEGL10+0x00000064", default: 0]
      // Keep every error and setup result; successful per-frame swaps get samples.
      if offset != 0x64 || result != 1 || swaps <= 4 || swaps.nonzeroBitCount == 1 {
        log.append("QEGL+" + offset.hex + " → " + result.hex)
      }
    }
    cpu.r[0] = 0
  }

  func dispatchSurfaceManip(_ offset: UInt32) throws {
    if offset <= 8 {
      try dispatchQGraphics(egl: true, offset: offset)
      return
    }
    let arity: Int
    switch offset {
    case 0x0c: arity = 3
    case 0x10: arity = 4
    case 0x14: arity = 5
    case 0x18: arity = 3
    default: throw EmulationError.hle("IEGLSurfaceManip+" + offset.hex, cpu.r[14])
    }
    let args = try (0..<arity).map { try argument($0 + 1) }
    let output = try argument(arity + 1)
    guard output != 0 else {
      cpu.r[0] = 14
      return
    }
    _ = try memory.data(output, count: 4)
    let result = try graphicsCall(args) { try dispatchSurfaceScale(offset) }
    try memory.write32(output, result)
    cpu.r[0] = 0
  }

  // Own implementation of the four scale functions declared by the original
  // AEEEGLSurfaceManip.h / gles/EGLext.h. Other SurfaceManip features stay explicit.
  func dispatchSurfaceScale(_ offset: UInt32) throws {
    if offset == 0x1c { cpu.r[0] = try getEGLColorBuffer(); return }
    let display = cpu.r[0]
    let surface = cpu.r[1]
    func fail(_ error: UInt32) {
      gl.eglError = error
      cpu.r[0] = 0
    }
    guard display == 1 else {
      fail(0x3008)
      return
    }
    guard gl.eglInitialized else {
      fail(0x3001)
      return
    }
    guard surface != 0 && surface == gl.eglSurface else {
      fail(0x300d)
      return
    }
    func rectangle(_ address: UInt32) throws -> SIMD4<Int32> {
      let bytes = try memory.data(address, count: 16)
      return try SIMD4((0..<4).map { Int32(bitPattern: try bytes.u32($0 * 4)) })
    }
    func write(_ values: [Int32], to address: UInt32) throws {
      var data = Data()
      for value in values {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
      }
      try memory.write(address, data: data)
    }
    switch offset {
    case 0x0c:
      gl.eglScaleEnabled = cpu.r[2] != 0
      log.append("EGL scale enabled: \(gl.eglScaleEnabled)")
    case 0x10:
      // Zeebo Developer Guide 0.97, p. 52: either NULL rectangle selects
      // the full original surface, including smaller offscreen pbuffers.
      let full = SIMD4<Int32>(0, 0, gl.eglSurfaceSize.x, gl.eglSurfaceSize.y)
      let scale = try GLESSurfaceScale(
        source: cpu.r[2] == 0 ? full : rectangle(cpu.r[2]),
        destination: cpu.r[3] == 0 ? full : rectangle(cpu.r[3]))
      guard scale.isValid(width: Int(gl.eglSurfaceSize.x), height: Int(gl.eglSurfaceSize.y)) else {
        fail(0x300c)
        return
      }
      gl.eglScale = scale
      log.append("EGL scale: \(scale.source) → \(scale.destination)")
    case 0x14:
      let enabled = cpu.r[2]
      let source = cpu.r[3]
      let destination = try argument(4)
      guard enabled != 0 && source != 0 && destination != 0 else {
        fail(0x300c)
        return
      }
      // Preflight all outputs before writing any of them.
      _ = try memory.data(enabled, count: 4)
      _ = try memory.data(source, count: 16)
      _ = try memory.data(destination, count: 16)
      try memory.write32(enabled, gl.eglScaleEnabled ? 1 : 0)
      try write((0..<4).map { gl.eglScale.source[$0] }, to: source)
      try write((0..<4).map { gl.eglScale.destination[$0] }, to: destination)
    case 0x18:
      guard cpu.r[2] != 0 else {
        fail(0x300c)
        return
      }
      // 16.16 ratios cover every supported pair of 1...640 by 1...480 rectangles.
      try write(
        [
          102, 640 * 65536, 136, 480 * 65536,
          1, 640, 1, 480, 1, 640, 1, 480,
        ], to: cpu.r[2])
    default: throw EmulationError.hle("EGLSurfaceScale+" + offset.hex, cpu.r[14])
    }
    cpu.r[0] = 1
  }

}
