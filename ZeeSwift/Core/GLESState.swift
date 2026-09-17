import Foundation
import simd

/// Original fixed-function OpenGL ES state. Guest pointers are decoded before submission.
/// The backend receives values, never addresses into emulated memory.
struct GLESVertex {
  var position: SIMD4<Float>
  var color: SIMD4<Float>
  var uv: SIMD4<Float>
  var uv1 = SIMD4<Float>(0, 0, 0, 1)
  var fog = SIMD4<Float>(repeating: 0)
}
// Packed float4 records shared with the Metal shader. No guest pointers escape.
struct GLESLight {
  var ambient = SIMD4<Float>(0, 0, 0, 1)
  var diffuse = SIMD4<Float>(0, 0, 0, 1)
  var specular = SIMD4<Float>(0, 0, 0, 1)
  var position = SIMD4<Float>(0, 0, 1, 0)
  var direction = SIMD4<Float>(0, 0, -1, 0)
  var attenuation = SIMD4<Float>(1, 0, 0, 0) // constant, linear, quadratic, enabled
  var spot = SIMD4<Float>(0, 180, 0, 0) // exponent, cutoff in degrees
}
struct GLESLightingUniforms {
  var ambient = SIMD4<Float>(0.2, 0.2, 0.2, 1)
  var diffuse = SIMD4<Float>(0.8, 0.8, 0.8, 1)
  var specular = SIMD4<Float>(0, 0, 0, 1)
  var emission = SIMD4<Float>(0, 0, 0, 1)
  var sceneAmbient = SIMD4<Float>(0.2, 0.2, 0.2, 1)
  var controls = SIMD4<Float>(0, 0, 0, 0) // enabled, two-sided, color material, shininess
}
struct GLESLightingVertex {
  var eyePosition: SIMD4<Float>
  var normal: SIMD4<Float>
}
struct GLESLightingDraw {
  var uniforms: GLESLightingUniforms
  var lights: [GLESLight]
  var vertices: [GLESLightingVertex]
}
struct GLESTexture {
  struct Image {
    let width: Int
    let height: Int
    let pixels: Data
    let format: UInt32
    let internalFormat: UInt32
  }
  private(set) var imageID = UUID()
  var cropRectangle = SIMD4<Int32>(repeating: 0)
  private(set) var images: [Int: Image]
  var width: Int { images[0]?.width ?? 0 }
  var height: Int { images[0]?.height ?? 0 }
  var pixels: Data { images[0]?.pixels ?? Data() }
  var format: UInt32 { images[0]?.format ?? 0x1908 }
  var parameters: [UInt32: UInt32] = [
    0x2800: 0x2601, 0x2801: 0x2702, 0x2802: 0x2901, 0x2803: 0x2901,
  ]
  init(
    width: Int, height: Int, pixels: Data, format: UInt32 = 0x1908,
    internalFormat: UInt32? = nil
  ) {
    images = [
      0: Image(
        width: width, height: height, pixels: pixels, format: format,
        internalFormat: internalFormat ?? format)
    ]
  }
  mutating func setImage(_ image: Image, level: Int) {
    images[level] = image
    imageID = UUID()  // Old draw snapshots and GPU cache entries keep their own immutable images.
  }
  var mipLevelCount: Int {
    let dimension = max(width, height)
    return dimension > 0 ? Int.bitWidth - dimension.leadingZeroBitCount : 0
  }
  func validImage(at level: Int) -> Image? {
    guard level >= 0, level < mipLevelCount, let image = images[level],
      image.width == max(1, width >> level), image.height == max(1, height >> level),
      image.internalFormat == images[0]?.internalFormat,
      image.pixels.count == image.width * image.height * 4
    else { return nil }
    return image
  }
  var samplingComplete: Bool {
    guard width > 0, height > 0, validImage(at: 0) != nil else { return false }
    let filter = parameters[0x2801] ?? 0x2702
    return filter == 0x2600 || filter == 0x2601
      || (0..<mipLevelCount).allSatisfy { validImage(at: $0) != nil }
  }
  mutating func generateMipmaps() {
    guard var previous = images[0], mipLevelCount > 1 else { return }
    for level in 1..<mipLevelCount {
      let width = max(1, previous.width / 2)
      let height = max(1, previous.height / 2)
      var pixels = Data(count: width * height * 4)
      for y in 0..<height {
        for x in 0..<width {
          for channel in 0..<4 {
            var sum = 0
            var count = 0
            for sy in y * previous.height / height..<(y + 1) * previous.height / height {
              for sx in x * previous.width / width..<(x + 1) * previous.width / width {
                sum += Int(previous.pixels[(sy * previous.width + sx) * 4 + channel])
                count += 1
              }
            }
            pixels[(y * width + x) * 4 + channel] = UInt8((sum + count / 2) / count)
          }
        }
      }
      previous = Image(
        width: width, height: height, pixels: pixels,
        format: previous.format, internalFormat: previous.internalFormat)
      images[level] = previous
    }
    imageID = UUID()
  }
}
// Five 16-byte vectors shared with the own Metal combiner uniform layout.
struct GLESTextureCombine: Equatable {
  var functions = SIMD4<UInt32>(0x2100, 0x2100, 1, 1) // RGB, alpha, RGB scale, alpha scale
  var sourceRGB = SIMD4<UInt32>(0x1702, 0x8578, 0x8576, 0)
  var sourceAlpha = SIMD4<UInt32>(0x1702, 0x8578, 0x8576, 0)
  var operandRGB = SIMD4<UInt32>(0x0300, 0x0300, 0x0302, 0)
  var operandAlpha = SIMD4<UInt32>(0x0302, 0x0302, 0x0302, 0)
}
struct GLESStencil: Hashable {
  var function: UInt32 = 0x0207
  var reference: UInt32 = 0
  var readMask: UInt32 = 0xff
  var writeMask: UInt32 = 0xff
  var fail: UInt32 = 0x1e00
  var depthFail: UInt32 = 0x1e00
  var pass: UInt32 = 0x1e00
}
struct GLESDraw {
  var vertices: [GLESVertex]
  var mode: UInt32
  var texture: GLESTexture?
  var enabled: Set<UInt32>
  var viewport: SIMD4<Int32>
  var scissor: SIMD4<Int32>
  var depthFunction: UInt32
  var depthWrite: Bool
  var blend: SIMD2<UInt32>
  var cull: UInt32
  var front: UInt32
  var alphaFunction: UInt32
  var alphaReference: Float
  var colorMask: SIMD4<UInt32>
  var textureEnvironment: UInt32
  var textureEnvironmentColor: SIMD4<Float>
  var texture1: GLESTexture? = nil
  var textureEnvironment1: UInt32 = 0x2100
  var textureEnvironmentColor1 = SIMD4<Float>(repeating: 0)
  var combine = GLESTextureCombine()
  var combine1 = GLESTextureCombine()
  var fogParameters = SIMD4<Float>(0, 1, 0, 1)  // mode, density, start, end
  var fogColor = SIMD4<Float>(repeating: 0)
  var depthRange = SIMD2<Float>(0, 1)
  var lighting: GLESLightingDraw? = nil
  var lineWidth: Float = 1
  var stencil = GLESStencil()
  var temporalIdentity: UInt64 = 0
}
// EGL surface rectangles use pixel coordinates from the lower left. Metal readback
// starts at the upper left; presentation converts the rectangle origins once.
struct GLESSurfaceScale: Equatable {
  static let full = SIMD4<Int32>(0, 0, 640, 480)
  var source = full
  var destination = full
  var isValid: Bool {
    isValid(width: 640, height: 480)
  }
  func isValid(width: Int, height: Int) -> Bool {
    source.x >= 0 && source.y >= 0 && source.z > 0 && source.w > 0
      && Int64(source.x) + Int64(source.z) <= width
      && Int64(source.y) + Int64(source.w) <= height
      && destination.z > 0 && destination.z <= width
      && destination.w > 0 && destination.w <= height
  }
  var isIdentity: Bool { source == Self.full && destination == Self.full }
}

protocol GLESBackend: AnyObject {
  var needsTemporalIdentity: Bool { get }
  func writeColorBuffer(_ pixels: Data, previous: Data) throws
  func resize(width: Int, height: Int) throws
  func clear(mask: UInt32, color: SIMD4<Float>, depth: Float, stencil: UInt32) throws
  func draw(_ draw: GLESDraw) throws
  func presentation(scale: GLESSurfaceScale?) throws -> RenderedFrame
  func readback() throws -> Data
  func readback(scale: GLESSurfaceScale?) throws -> Data
  func finish() throws
}

extension GLESBackend {
  var needsTemporalIdentity: Bool { false }
  func writeColorBuffer(_ pixels: Data, previous: Data) throws {
    throw EmulationError.unsupported("Writable EGL color buffer")
  }
  func resize(width: Int, height: Int) throws {
    guard width == 640, height == 480 else {
      throw EmulationError.unsupported("Graphics backend surface size \(width)×\(height)")
    }
  }
  func presentation(scale: GLESSurfaceScale?) throws -> RenderedFrame {
    RenderedFrame(pixels: try readback(scale: scale))
  }
  func readback(scale: GLESSurfaceScale?) throws -> Data {
    guard scale == nil || scale!.isIdentity else {
      throw EmulationError.unsupported("EGL scaling requires a scaling graphics backend")
    }
    return try readback()
  }
  func finish() throws {}
}

final class GLESState {
  // HLE viewport limit, within the Metal 4 backend's supported raster dimensions.
  static let maximumViewportDimension: Int32 = 16_384
  // Boia Cross nests projection and texture matrices three levels deep.
  // ES permits stacks larger than its minimum; advertise the actual capacity.
  static let maximumMatrixStackDepth = 32
  struct ArrayPointer {
    var size: Int
    var type: UInt32
    var stride: Int
    var address: UInt32
    var buffer: UInt32 = 0
  }
  struct BufferObject {
    var address: UInt32 = 0
    var size: UInt32 = 0
    var usage: UInt32 = 0x88e4
    var access: UInt32 = 0x88ba
    var mapped = false
  }
  var buffers: [UInt32: BufferObject] = [:]
  var bufferNames: Set<UInt32> = []
  var nextBuffer: UInt32 = 1
  var arrayBuffer: UInt32 = 0
  var elementBuffer: UInt32 = 0

  func bufferAddress(_ name: UInt32, offset: UInt64, count: Int) throws -> UInt32 {
    guard let buffer = buffers[name], !buffer.mapped,
      offset <= UInt64(buffer.size), UInt64(count) <= UInt64(buffer.size) - offset
    else { throw EmulationError.invalid("GL buffer range") }
    return buffer.address + UInt32(offset)
  }
  struct TextureUnit {
    var enabled = false
    var clientEnabled = false
    var array: ArrayPointer? = nil
    var coordinate = SIMD4<Float>(0, 0, 0, 1)
    var matrices = [matrix_identity_float4x4]
    var binding: UInt32 = 0
    var combine = GLESTextureCombine()
    var environment: UInt32 = 0x2100
    var environmentColor = SIMD4<Float>(repeating: 0)
  }
  var textureUnits = [TextureUnit(), TextureUnit()]
  var activeTexture = 0
  var clientActiveTexture = 0
  func selectTexture(_ target: UInt32, client: Bool) {
    guard target >= 0x84c0, target < 0x84c0 + UInt32(textureUnits.count) else {
      setError(0x0500)
      return
    }
    if client {
      clientActiveTexture = Int(target - 0x84c0)
    } else {
      activeTexture = Int(target - 0x84c0)
    }
  }
  func setEnabled(_ capability: UInt32, _ value: Bool, client: Bool = false) {
    if client && capability == 0x8078 {
      textureUnits[clientActiveTexture].clientEnabled = value
    } else if !client && capability == 0x0de1 {
      textureUnits[activeTexture].enabled = value
    } else if client {
      if value { clients.insert(capability) } else { clients.remove(capability) }
    } else {
      if capability == 0x0b57 && value {
        lighting.ambient = color; lighting.diffuse = color
      }
      if value { enabled.insert(capability) } else { enabled.remove(capability) }
    }
  }
  var backend: GLESBackend?
  var enabled: Set<UInt32> = [0x0bd0]  // Dither
  var clients: Set<UInt32> = []
  var arrays: [UInt32: ArrayPointer] = [:]
  var matrixMode: UInt32 = 0x1700
  var matrices: [UInt32: [simd_float4x4]] = [
    0x1700: [matrix_identity_float4x4], 0x1701: [matrix_identity_float4x4],
  ]
  var lighting = GLESLightingUniforms()
  var lights: [GLESLight] = (0..<8).map { index in
    var light = GLESLight()
    if index == 0 { light.diffuse = SIMD4(repeating: 1); light.specular = SIMD4(repeating: 1) }
    return light
  }
  var shadeModel: UInt32 = 0x1d01
  var color = SIMD4<Float>(repeating: 1) {
    didSet {
      if enabled.contains(0x0b57) { lighting.ambient = color; lighting.diffuse = color }
    }
  }
  var normal = SIMD3<Float>(0, 0, 1)
  var fogMode: UInt32 = 0x0800
  var fogDensity: Float = 1
  var fogStart: Float = 0
  var fogEnd: Float = 1
  var fogColor = SIMD4<Float>(repeating: 0)
  var clearColor = SIMD4<Float>(repeating: 0)
  var clearDepth: Float = 1
  var clearStencil: UInt32 = 0
  var stencil = GLESStencil()
  var viewport = SIMD4<Int32>(0, 0, 640, 480)
  var depthRange = SIMD2<Float>(0, 1)
  var scissor = SIMD4<Int32>(0, 0, 640, 480)
  var depthFunction: UInt32 = 0x0201
  var depthWrite = true
  var lineWidth: Float = 1
  static let maximumLineWidth: Float = 64
  var blend = SIMD2<UInt32>(1, 0)
  var cull: UInt32 = 0x0405
  var front: UInt32 = 0x0901
  var alphaFunction: UInt32 = 0x0207
  var alphaReference: Float = 0
  var colorMask = SIMD4<UInt32>(repeating: 1)
  var textureEnvironment: UInt32 {
    get { textureUnits[activeTexture].environment }
    set { textureUnits[activeTexture].environment = newValue }
  }
  var textureEnvironmentColor: SIMD4<Float> {
    get { textureUnits[activeTexture].environmentColor }
    set { textureUnits[activeTexture].environmentColor = newValue }
  }
  var unpackAlignment = 4
  var boundTexture: UInt32 {
    get { textureUnits[activeTexture].binding }
    set { textureUnits[activeTexture].binding = newValue }
  }
  var textures: [UInt32: GLESTexture] = [:]
  var generated: Set<UInt32> = []
  var nextTexture: UInt32 = 1
  var parameters: [UInt32: [UInt32]] = [:]
  var error: UInt32 = 0
  var draws: UInt64 = 0
  var eglInitialized = false
  var eglContext: UInt32 = 0
  var eglSurface: UInt32 = 0
  var eglSurfaceSize = SIMD2<Int32>(640, 480)
  var surfaceSize = SIMD2<Int32>(640, 480)
  var surfaceRectangle: SIMD4<Int32> { SIMD4(0, 0, surfaceSize.x, surfaceSize.y) }
  var contextHasBeenCurrent = false
  var eglCurrent: UInt32 = 0
  var eglScale = GLESSurfaceScale()
  var eglScaleEnabled = false
  var eglError: UInt32 = 0x3000
  func setError(_ value: UInt32) { if error == 0 { error = value } }
  func clear(_ requestedMask: UInt32) throws {
    guard requestedMask & ~UInt32(0x4500) == 0 else {
      setError(0x0501)
      return
    }
    guard let backend else { throw EmulationError.unsupported("GL Clear requires Metal 4") }
    var mask = depthWrite ? requestedMask : requestedMask & ~UInt32(0x0100)
    if stencil.writeMask == 0 { mask &= ~UInt32(0x0400) }
    guard mask != 0 else { return }
    let clipped = enabled.contains(0x0c11)
    let full =
      !clipped
      || (scissor.x <= 0 && scissor.y <= 0
        && Int64(scissor.x) + Int64(scissor.z) >= surfaceSize.x && Int64(scissor.y) + Int64(scissor.w) >= surfaceSize.y)
    let allColors = (0..<4).allSatisfy { colorMask[$0] != 0 }
    if full && (allColors || mask & 0x4000 == 0) && (mask & 0x0400 == 0 || stencil.writeMask == 0xff) {
      try backend.clear(mask: mask, color: clearColor, depth: clearDepth, stencil: clearStencil)
      return
    }
    // A clear ignores viewport, transforms, blending and alpha/depth comparisons,
    // but respects scissor, color mask and depth mask. Rasterize its rectangle on GPU.
    let vertices: [GLESVertex] = [SIMD2<Float>(-1, -1), SIMD2(1, -1), SIMD2(-1, 1), SIMD2(1, 1)].map
    {
      GLESVertex(
        position: SIMD4($0.x, $0.y, clearDepth * 2 - 1, 1), color: clearColor, uv: SIMD4(0, 0, 0, 1)
      )
    }
    try backend.draw(
      GLESDraw(
        vertices: vertices, mode: 5, texture: nil,
        enabled: mask & 0x0400 == 0 ? [0x0c11, 0x0b71] : [0x0c11, 0x0b71, 0x0b90], viewport: surfaceRectangle,
        scissor: clipped ? scissor : surfaceRectangle, depthFunction: 0x0207,
        depthWrite: mask & 0x100 != 0,
        blend: SIMD2(1, 0), cull: 0x0405, front: 0x0901, alphaFunction: 0x0207, alphaReference: 0,
        colorMask: mask & 0x4000 != 0 ? colorMask : SIMD4(repeating: 0),
        textureEnvironment: 0x2100, textureEnvironmentColor: SIMD4(repeating: 0),
        stencil: GLESStencil(reference: clearStencil & 0xff, writeMask: stencil.writeMask, pass: 0x1e01)))
  }
  static func fixed(_ value: UInt32) -> Float { Float(Int32(bitPattern: value)) / 65536 }
  var matrixStack: [simd_float4x4] {
    get { matrixMode == 0x1702 ? textureUnits[activeTexture].matrices : matrices[matrixMode]! }
    set {
      if matrixMode == 0x1702 {
        textureUnits[activeTexture].matrices = newValue
      } else {
        matrices[matrixMode] = newValue
      }
    }
  }
  var matrix: simd_float4x4 {
    get { matrixStack.last! }
    set { matrixStack[matrixStack.count - 1] = newValue }
  }
  func multiply(_ value: simd_float4x4) { matrix = matrix * value }
  func readArray(
    _ array: ArrayPointer, index: Int, memory: GuestMemory, defaults: SIMD4<Float>,
    normalized: Bool = false
  ) throws -> SIMD4<Float> {
    let size: Int
    switch array.type {
    case 0x1400, 0x1401: size = 1
    case 0x1402, 0x1403: size = 2
    case 0x1406, 0x140c: size = 4
    default: throw EmulationError.unsupported("GL array type " + array.type.hex)
    }
    let stride = array.stride == 0 ? array.size * size : array.stride
    var offset = UInt64(array.address) + UInt64(index) * UInt64(stride)
    if array.buffer != 0 {
      offset = UInt64(try bufferAddress(array.buffer, offset: offset, count: array.size * size))
    }
    guard offset + UInt64(array.size * size) <= UInt64(UInt32.max) else {
      throw EmulationError.invalid("GL array range")
    }
    var result = defaults
    for component in 0..<array.size {
      let p = UInt32(offset) + UInt32(component * size)
      switch array.type {
      case 0x1400:
        result[component] = Float(Int8(truncatingIfNeeded: try memory.read8(p)))
        if normalized { result[component] = max(-1, result[component] / 127) }
      case 0x1401:
        result[component] = Float(try memory.read8(p))
        if normalized { result[component] /= 255 }
      case 0x1402:
        result[component] = Float(Int16(truncatingIfNeeded: try memory.read16(p)))
        if normalized { result[component] = max(-1, result[component] / 32767) }
      case 0x1403:
        result[component] = Float(try memory.read16(p))
        if normalized { result[component] /= 65535 }
      case 0x1406: result[component] = Float(bitPattern: try memory.read32(p))
      default: result[component] = Self.fixed(try memory.read32(p))
      }
    }
    return result
  }
  static func lightParameterCount(_ name: UInt32) -> Int? {
    switch name {
    case 0x1200...0x1203: return 4
    case 0x1204: return 3
    case 0x1205...0x1209: return 1
    default: return nil
    }
  }
  static func materialParameterCount(_ name: UInt32) -> Int? {
    switch name {
    case 0x1200...0x1202, 0x1600, 0x1602: return 4
    case 0x1601: return 1
    default: return nil
    }
  }
  static func linearPart(_ matrix: simd_float4x4) -> simd_float3x3 {
    simd_float3x3(SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
      SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
      SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z))
  }
  func setLight(_ index: Int, parameter: UInt32, values: [Float]) {
    guard lights.indices.contains(index), let count = Self.lightParameterCount(parameter), values.count == count
    else { setError(0x0500); return }
    let scalar = values[0]
    if (parameter == 0x1205 && !(0...128).contains(scalar))
      || (parameter == 0x1206 && scalar != 180 && !(0...90).contains(scalar))
      || ((0x1207...0x1209).contains(parameter) && !(scalar >= 0)) {
      setError(0x0501); return
    }
    let value = SIMD4(values[0], count > 1 ? values[1] : 0, count > 2 ? values[2] : 0, count > 3 ? values[3] : 0)
    switch parameter {
    case 0x1200: lights[index].ambient = value
    case 0x1201: lights[index].diffuse = value
    case 0x1202: lights[index].specular = value
    case 0x1203: lights[index].position = matrices[0x1700]!.last! * value
    case 0x1204:
      let direction = Self.linearPart(matrices[0x1700]!.last!) * SIMD3(value.x, value.y, value.z)
      lights[index].direction = SIMD4(direction, 0)
    case 0x1205: lights[index].spot.x = scalar
    case 0x1206: lights[index].spot.y = scalar
    case 0x1207...0x1209: lights[index].attenuation[Int(parameter - 0x1207)] = scalar
    default: break
    }
  }
  func setMaterial(_ parameter: UInt32, values: [Float]) {
    guard let count = Self.materialParameterCount(parameter), values.count == count else { setError(0x0500); return }
    if parameter == 0x1601 {
      guard (0...128).contains(values[0]) else { setError(0x0501); return }
      lighting.controls.w = values[0]; return
    }
    let value = SIMD4(values[0], values[1], values[2], values[3])
    switch parameter {
    case 0x1200: if !enabled.contains(0x0b57) { lighting.ambient = value }
    case 0x1201: if !enabled.contains(0x0b57) { lighting.diffuse = value }
    case 0x1202: lighting.specular = value
    case 0x1600: lighting.emission = value
    case 0x1602:
      if !enabled.contains(0x0b57) { lighting.ambient = value; lighting.diffuse = value }
    default: break
    }
  }
  func draw(mode: UInt32, indices: [Int], memory: GuestMemory) throws {
    if !buffers.isEmpty {
      for (slot, array) in arrays where array.buffer != 0 && clients.contains(slot) {
        if buffers[array.buffer]?.mapped == true { setError(0x0502); return }
      }
      for unit in textureUnits where unit.clientEnabled {
        if let array = unit.array, array.buffer != 0, buffers[array.buffer]?.mapped == true {
          setError(0x0502); return
        }
      }
    }
    guard clients.contains(0x8074), let positions = arrays[0x8074] else {
      setError(0x0502)
      return
    }
    guard mode <= 6 else {
      setError(0x0500)
      return
    }
    // Each enabled feature must have a real implementation before a draw can proceed.
    for feature: UInt32 in [0x0bf2] where enabled.contains(feature) {
      throw EmulationError.unsupported("GL drawing feature " + feature.hex)
    }
    let modelView = matrices[0x1700]!.last!
    let transform = matrices[0x1701]!.last! * modelView
    let lit = enabled.contains(0x0b50)
    let linear = Self.linearPart(modelView)
    // Singular normals are undefined in GLES, but may not terminate rendering.
    let normalMatrix = lit && abs(simd_determinant(linear)) > Float.leastNormalMagnitude
      ? simd_transpose(simd_inverse(linear)) : matrix_identity_float3x3
    let rescaleLength = simd_length(normalMatrix.columns.2)
    let rescale: Float = enabled.contains(0x803a) && rescaleLength > 0 ? 1 / rescaleLength : 1
    var primitive = mode
    var order: [Int]?
    var shadeOrder: [Int]?
    if shadeModel == 0x1d00 {
      var groups: [[Int]] = []
      switch mode {
      case 0: groups = indices.indices.map { [$0] }
      case 1: groups = stride(from: 0, to: max(0, indices.count - 1), by: 2).map { [$0, $0 + 1] }
      case 2, 3:
        if indices.count >= 2 {
          groups = (0..<(indices.count - 1)).map { [$0, $0 + 1] }
          if mode == 2 { groups.append([indices.count - 1, 0]) }
        }
        primitive = 1
      case 4: groups = stride(from: 0, to: max(0, indices.count - 2), by: 3).map { [$0, $0 + 1, $0 + 2] }
      case 5, 6:
        if indices.count >= 3 {
          groups = (0..<(indices.count - 2)).map { i in
            mode == 6 ? [0, i + 1, i + 2] : (i % 2 == 0 ? [i, i + 1, i + 2] : [i + 1, i, i + 2])
          }
        }
        primitive = 4
      default: break
      }
      order = groups.flatMap { $0 }
      shadeOrder = groups.flatMap { group in Array(repeating: group.last!, count: group.count) }
    } else if mode == 6 {
      order = indices.count >= 3 ? (1..<(indices.count - 1)).flatMap { [0, $0, $0 + 1] } : []
      shadeOrder = order; primitive = 4
    } else if mode == 2, !indices.isEmpty {
      order = Array(indices.indices) + [0]; shadeOrder = order; primitive = 3
    }
    let vertexCount = order?.count ?? indices.count
    var lightingVertices: [GLESLightingVertex] = []
    if lit { lightingVertices.reserveCapacity(vertexCount) }
    var vertices: [GLESVertex] = []
    vertices.reserveCapacity(vertexCount)
    for outputIndex in 0..<vertexCount {
      let inputIndex = order?[outputIndex] ?? outputIndex
      let index = indices[inputIndex]
      let shadingIndex = indices[shadeOrder?[outputIndex] ?? inputIndex]
      let position = try readArray(
        positions, index: index, memory: memory, defaults: SIMD4(0, 0, 0, 1))
      let vertexColor =
        try clients.contains(0x8076) && arrays[0x8076] != nil
        ? readArray(
          arrays[0x8076]!, index: shadingIndex, memory: memory, defaults: color, normalized: true) : color
      let uv = try textureUnits.map { unit in
        let coordinate =
          try unit.clientEnabled && unit.array != nil
          ? readArray(unit.array!, index: index, memory: memory, defaults: SIMD4(0, 0, 0, 1))
          : unit.coordinate
        return unit.matrices.last! * coordinate
      }
      if lit {
        let lightingPosition = shadingIndex == index ? position : try readArray(
          positions, index: shadingIndex, memory: memory, defaults: SIMD4(0, 0, 0, 1))
        var n = SIMD4(normal, 0)
        if clients.contains(0x8075), let pointer = arrays[0x8075] {
          n = try readArray(pointer, index: shadingIndex, memory: memory, defaults: n)
          // GLES 1.1 table 2.7 uses signed component conversion for normals.
          if pointer.type == 0x1400 || pointer.type == 0x1402 {
            let divisor: Float = pointer.type == 0x1400 ? 255 : 65535
            for component in 0..<3 { n[component] = (2 * n[component] + 1) / divisor }
          }
        }
        var transformed = (normalMatrix * SIMD3(n.x, n.y, n.z)) * rescale
        if enabled.contains(0x0ba1), simd_length_squared(transformed) > 0 { transformed = simd_normalize(transformed) }
        lightingVertices.append(GLESLightingVertex(eyePosition: modelView * lightingPosition, normal: SIMD4(transformed, 0)))
      }
      vertices.append(
        GLESVertex(
          position: transform * position, color: vertexColor, uv: uv[0], uv1: uv[1],
          fog: SIMD4(abs((matrices[0x1700]!.last! * position).z), 0, 0, 0)))
    }
    var lightingDraw: GLESLightingDraw?
    if lit {
      var uniforms = lighting
      uniforms.controls.x = 1
      // Lines and points always use the front color.
      if primitive < 4 { uniforms.controls.y = 0 }
      uniforms.controls.z = enabled.contains(0x0b57) ? 1 : 0
      var sources = lights
      for index in sources.indices { sources[index].attenuation.w = enabled.contains(0x4000 + UInt32(index)) ? 1 : 0 }
      lightingDraw = GLESLightingDraw(uniforms: uniforms, lights: sources, vertices: lightingVertices)
    }
    guard let backend else {
      throw EmulationError.unsupported("OpenGL ES requires the Metal 4 graphics backend")
    }
    // Opaque source/topology identity, not a dereferenceable host pointer.
    var identity: UInt64 = 14695981039346656037
    if backend.needsTemporalIdentity {
    for value in [UInt64(positions.address), UInt64(positions.buffer), UInt64(positions.type),
                  UInt64(positions.size), UInt64(positions.stride), UInt64(mode)] {
      identity = (identity ^ value) &* 1099511628211
    }
    for index in indices { identity = (identity ^ UInt64(index)) &* 1099511628211 }
    } else { identity = 0 }
    try backend.draw(
      GLESDraw(
        vertices: vertices, mode: primitive,
        texture: textureUnits[0].enabled ? textures[textureUnits[0].binding] : nil,
        enabled: enabled,
        viewport: viewport, scissor: scissor, depthFunction: depthFunction, depthWrite: depthWrite,
        blend: blend, cull: cull, front: front, alphaFunction: alphaFunction,
        alphaReference: alphaReference, colorMask: colorMask,
        textureEnvironment: textureUnits[0].environment,
        textureEnvironmentColor: textureUnits[0].environmentColor,
        texture1: textureUnits[1].enabled ? textures[textureUnits[1].binding] : nil,
        textureEnvironment1: textureUnits[1].environment,
        textureEnvironmentColor1: textureUnits[1].environmentColor,
        combine: textureUnits[0].combine, combine1: textureUnits[1].combine,
        fogParameters: SIMD4(
          enabled.contains(0x0b60) ? Float(fogMode) : 0, fogDensity, fogStart, fogEnd),
        fogColor: fogColor, depthRange: depthRange, lighting: lightingDraw, lineWidth: lineWidth, stencil: stencil, temporalIdentity: identity
      ))
    if enabled.contains(0x0b57), clients.contains(0x8076), let last = vertices.last { color = last.color }
    draws &+= 1
  }

  // Own OES_draw_texture implementation from the Khronos extension contract.
  // Window coordinates bypass vertex arrays, matrices, lighting and face culling.
  // The ordinary fragment pipeline still handles texture stages, fog and tests.
  func drawTexture(x: Float, y: Float, z: Float, width: Float, height: Float) throws {
    guard [x, y, z, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else {
      setError(0x0501)
      return
    }
    for feature: UInt32 in [0x0bf2] where enabled.contains(feature) {
      throw EmulationError.unsupported("GL drawing feature " + feature.hex)
    }
    let corners: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)]
    let vertices = corners.map { corner in
      let coordinates = textureUnits.map { unit -> SIMD4<Float> in
        guard let texture = textures[unit.binding], texture.width > 0, texture.height > 0 else {
          return SIMD4(0, 0, 0, 1)
        }
        let crop = texture.cropRectangle
        return SIMD4(
          (Float(crop.x) + corner.x * Float(crop.z)) / Float(texture.width),
          (Float(crop.y) + corner.y * Float(crop.w)) / Float(texture.height), 0, 1)
      }
      return GLESVertex(
        position: SIMD4((x + corner.x * width) * 2 / Float(surfaceSize.x) - 1,
          (y + corner.y * height) * 2 / Float(surfaceSize.y) - 1, min(1, max(0, z)) * 2 - 1, 1),
        color: color, uv: coordinates[0], uv1: coordinates[1])
    }
    guard let backend else {
      throw EmulationError.unsupported("OpenGL ES requires the Metal 4 graphics backend")
    }
    try backend.draw(GLESDraw(
      vertices: vertices, mode: 5,
      texture: textureUnits[0].enabled ? textures[textureUnits[0].binding] : nil,
      enabled: enabled.subtracting([0x0b44, 0x0b50, 0x8037]),
      viewport: surfaceRectangle, scissor: scissor,
      depthFunction: depthFunction, depthWrite: depthWrite,
      blend: blend, cull: cull, front: front, alphaFunction: alphaFunction,
      alphaReference: alphaReference, colorMask: colorMask,
      textureEnvironment: textureUnits[0].environment,
      textureEnvironmentColor: textureUnits[0].environmentColor,
      texture1: textureUnits[1].enabled ? textures[textureUnits[1].binding] : nil,
      textureEnvironment1: textureUnits[1].environment,
      textureEnvironmentColor1: textureUnits[1].environmentColor,
        combine: textureUnits[0].combine, combine1: textureUnits[1].combine,
      fogParameters: SIMD4(enabled.contains(0x0b60) ? Float(fogMode) : 0, fogDensity, fogStart, fogEnd),
      fogColor: fogColor, depthRange: depthRange, stencil: stencil))
    draws &+= 1
  }
}

/// Match the original submitted topology across swaps. Ambiguous/new geometry
/// rejects history rather than borrowing another object's motion.
final class GLESTemporalHistory {
  private struct Key: Hashable {
    let source: UInt64
    let texture: UUID?
    let texture1: UUID?
    let mode: UInt32
    let count: Int
    let occurrence: Int
  }
  private struct Geometry {
    let positions: [SIMD4<Float>]
    let viewport: SIMD4<Int32>
    let appearance: UInt64
  }
  private var previous: [Key: Geometry] = [:]
  private var current: [Key: Geometry] = [:]
  private var occurrences: [Key: Int] = [:]
  private var storedVertices = 0
  private var previousOccurrences: [Key:Int] = [:]
  private var seenVertices = 0
  private var cutVertices = 0
  private var matchedVertices = 0
  var requiresReset: Bool { reset || (seenVertices > 0 && cutVertices * 2 > seenVertices)
    || (!previous.isEmpty && seenVertices > 0 && matchedVertices == 0) }
  private(set) var generation = UUID()
  private(set) var index: UInt64 = 0
  private(set) var reset = true
  var jitter: SIMD2<Float> {
    func halton(_ n: Int, base: Int) -> Float {
      var n = n, weight: Float = 1, result: Float = 0
      while n > 0 { weight /= Float(base); result += weight * Float(n % base); n /= base }
      return result - 0.5
    }
    let phase = Int(index % 16) + 1
    return SIMD2(halton(phase,base:2),halton(phase,base:3))
  }
  func invalidate() {
    previous.removeAll(); current.removeAll(); occurrences.removeAll()
    storedVertices = 0; seenVertices = 0; cutVertices = 0; matchedVertices = 0
    previousOccurrences.removeAll(); generation = UUID(); index = 0; reset = true
  }
  func prepare(_ draw: GLESDraw, width: Int, height: Int, scale: Int) -> (positions: [SIMD4<Float>], reactive: Bool) {
    let base = Key(source:draw.temporalIdentity,texture:draw.texture?.imageID,
      texture1:draw.texture1?.imageID,mode:draw.mode,count:draw.vertices.count,occurrence:0)
    let occurrence = occurrences[base,default:0]
    occurrences[base] = occurrence + 1
    let key = Key(source:base.source,texture:base.texture,texture1:base.texture1,mode:base.mode,count:base.count,occurrence:occurrence)
    var appearance: UInt64 = 14695981039346656037
    for vertex in draw.vertices {
      for vector in [vertex.color,vertex.uv,vertex.uv1] {
        for i in 0..<4 { appearance = (appearance ^ UInt64(vector[i].bitPattern)) &* 1099511628211 }
      }
    }
    let geometry = Geometry(positions:draw.vertices.map(\.position),viewport:draw.viewport,appearance:appearance)
    let old = previous[key]
    let valid = old != nil && old!.positions.count == geometry.positions.count
      && old!.viewport == geometry.viewport && draw.temporalIdentity != 0
    seenVertices += geometry.positions.count
    if valid { matchedVertices += geometry.positions.count }
    // Repeated source/topology cannot identify reordered instances reliably.
    // Reject those pixels instead of assigning one instance another's motion.
    let ambiguous = occurrence > 0 || previousOccurrences[base,default:0] > 1
    if occurrence > 0 && previousOccurrences[base,default:0] < 2 { reset = true }
    var reactive = !valid || ambiguous || old?.appearance != geometry.appearance
      || draw.enabled.contains(0x0be2) || !draw.enabled.contains(0x0b71)
    let previousPositions = valid ? old!.positions : geometry.positions
    var result: [SIMD4<Float>] = []
    result.reserveCapacity(previousPositions.count)
    for (prior, now) in zip(previousPositions, geometry.positions) {
      var prior = prior
      if !prior.x.isFinite || !prior.y.isFinite || !prior.w.isFinite || prior.w <= 0
        || !now.w.isFinite || now.w <= 0 {
        prior = now; reactive = true
      } else if abs(prior.x/prior.w-now.x/now.w) > 0.75 || abs(prior.y/prior.w-now.y/now.w) > 0.75 {
        // A cut/teleport cannot safely reuse this draw's previous samples.
        reactive = true; cutVertices += 1
      }
      let w = prior.w
      let x = ((prior.x+w)*0.5*Float(draw.viewport.z)+Float(draw.viewport.x)*w)*Float(scale)
      let y = Float(height)*w-((prior.y+w)*0.5*Float(draw.viewport.w)+Float(draw.viewport.y)*w)*Float(scale)
      result.append(SIMD4(x,y,prior.z,w))
    }
    if storedVertices + geometry.positions.count <= 1_000_000 {
      current[key] = geometry; storedVertices += geometry.positions.count
    } else { reactive = true }
    return (result,reactive)
  }
  func advance() {
    previous = current; current.removeAll(keepingCapacity:true)
    previousOccurrences = occurrences
    occurrences.removeAll(keepingCapacity:true); storedVertices = 0
    seenVertices = 0; cutVertices = 0; matchedVertices = 0
    index &+= 1; reset = false
  }
}
