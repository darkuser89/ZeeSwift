import Metal
import simd

/// Bounded batches of ES fixed-function drawing on Metal 4, completed at guest sync/readback.
/// CPU-side vertex transformation is HLE; rasterization, depth, texture sampling and blending run on the GPU.
final class Metal4GLESRenderer: GLESBackend {
  // User presentation choice. Guest texture parameters and minification stay intact.
  var pixelExactMagnification = false
  var temporalCaptureEnabled = false {
    didSet { if !temporalCaptureEnabled { temporalRenderer = nil } }
  }
  var needsTemporalIdentity: Bool { temporalCaptureEnabled }
  private let temporalTarget: Bool
  private var temporalRenderer: Metal4GLESRenderer?
  private let temporalHistory = GLESTemporalHistory()
  private var temporalMultisampleTargets: [MTLTexture] = []
  private var temporalTargets: [MTLTexture] = [] // motion, canonical depth, reactive mask
  private var temporalFrameInvalid = false
  private var previousTemporalScale: GLESSurfaceScale?
  private func prepareTemporalRenderer() throws {
    guard !temporalTarget, temporalCaptureEnabled else { return }
    if temporalRenderer == nil {
      temporalRenderer = try Metal4GLESRenderer(renderScale: renderScale, sampleCount: sampleCount, temporalTarget: true)
      try temporalRenderer?.resize(width: surfaceWidth, height: surfaceHeight)
      // Enabling mid-frame cannot reconstruct color/depth drawn before capture.
      // Wait for a full color clear rather than present a partial auxiliary image.
      temporalRenderer?.temporalFrameInvalid = true
    }
    temporalRenderer?.pixelExactMagnification = pixelExactMagnification
  }
  private func makeTemporalTargets() throws {
    for target in temporalTargets + temporalMultisampleTargets { residency.removeAllocation(target) }
    temporalTargets.removeAll(); temporalMultisampleTargets.removeAll()
    for format: MTLPixelFormat in [.rg16Float, .r32Float, .r8Unorm] {
      let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:color.width,height:color.height,mipmapped:false)
      desc.storageMode = .shared; desc.usage = [.renderTarget,.shaderRead]
      guard let target = device.makeTexture(descriptor:desc) else { throw EmulationError.unsupported("Temporal metadata texture") }
      temporalTargets.append(target); residency.addAllocation(target)
      if sampleCount > 1 {
        let multisample = try makeMultisampleTarget(format: format, width: color.width, height: color.height)
        temporalMultisampleTargets.append(multisample); residency.addAllocation(multisample)
      }
    }
    residency.commit(); temporalHistory.invalidate()
  }
  let device: MTLDevice
  let queue: MTL4CommandQueue
  let command: MTL4CommandBuffer
  let allocator: MTL4CommandAllocator
  let completion: MTLSharedEvent
  let residency: MTLResidencySet
  let compiler: MTL4Compiler
  let library: MTLLibrary
  let renderScale: Int
  let sampleCount: Int
  // Keep samples across guest flushes and partial clears. The resolved color is
  // only for readback/presentation; it never replaces the retained sample data.
  private var multisampleColor: MTLTexture?
  private var patchPipeline: MTLRenderPipelineState?
  private(set) var color: MTLTexture
  private(set) var depth: MTLTexture
  var surfaceWidth: Int { color.width / renderScale }
  var surfaceHeight: Int { color.height / renderScale }
  let white: MTLTexture
  var serial: UInt64 = 0
  private struct PipelineKey: Hashable {
    var blending: Bool
    var factors: SIMD2<UInt32>
    var mask: SIMD4<UInt32>
  }
  private var pipelines: [PipelineKey: MTLRenderPipelineState] = [:]
  private struct DepthKey: Hashable {
    var depth: SIMD2<UInt32>
    var stencil: GLESStencil?
  }
  private var depthStates: [DepthKey: MTLDepthStencilState] = [:]
  private let arguments: MTL4ArgumentTable
  private let uploadBuffer: MTLBuffer
  private var uploadOffset = 0
  private var encoder: MTL4RenderCommandEncoder?
  // Encoder state survives draws, but never a new render pass. Argument tables
  // still bind on each draw because their contents change independently.
  private var boundPipeline: MTLRenderPipelineState?
  private var boundDepth: MTLDepthStencilState?
  private var boundStencilReference: UInt32?
  private var boundViewport: SIMD4<Int32>?
  private var boundDepthRange: SIMD2<Float>?
  private var boundScissor: SIMD4<Int>?
  private var boundCull: MTLCullMode?
  private var boundWinding: MTLWinding?
  private(set) var stateChanges = 0
  private var recording = false
  private var batchDraws = 0
  private var batchPasses = 0
  private var batchTextures: [UUID: MTLTexture] = [:]
  private var largeUploads: [MTLBuffer] = []
  private var scaledColors: [Int: MTLTexture] = [:]
  private let stagedReadback: Bool
  /// Data snapshots may outlive the renderer and be released on the UI thread.
  /// Only an unleased slot can become a GPU destination again.
  private final class ReadbackSlot: @unchecked Sendable {
    let buffer: MTLBuffer
    private let lock = NSLock()
    private var leased = false
    init(_ buffer: MTLBuffer) { self.buffer = buffer }
    func claim() -> Bool {
      lock.lock(); defer { lock.unlock() }
      guard !leased else { return false }
      leased = true
      return true
    }
    func release() { lock.lock(); leased = false; lock.unlock() }
  }
  private var readbackSlots: [ReadbackSlot] = []
  private(set) var stagedReadbacks = 0
  private(set) var readbackPoolFallbacks = 0
  private var scalePipeline: MTLRenderPipelineState?
  private(set) var scalePasses = 0
  private var failed = false
  private(set) var submissions = 0
  private(set) var renderPasses = 0
  private(set) var bufferAllocations = 1
  private(set) var gpuWaitNanoseconds: UInt64 = 0
  // Optional diagnostics. Counter writes can perturb scheduling, so normal play
  // never creates a counter heap. CPU wait time is not GPU execution time.
  private let counterHeap: MTL4CounterHeap?
  private var profileStartGPU: UInt64 = 0
  private var profileStartHost: UInt64 = 0
  private(set) var gpuTimestampTicks: UInt64 = 0
  private(set) var gpuTimestampBatches = 0
  private(set) var invalidTimestampBatches = 0
  private(set) var textureUploadNanoseconds: UInt64 = 0
  private(set) var textureUploadBytes: UInt64 = 0
  private(set) var readbackNanoseconds: UInt64 = 0
  private(set) var readbackBytes: UInt64 = 0
  private(set) var depthStateCreations = 0
  private var textureCache: [UUID: MTLTexture] = [:]
  private var textureOrder: [UUID] = []
  private var cachedBytes = 0
  private let textureCacheLimit: Int
  private var batchTextureBytes = 0
  private var samplerCache: [SIMD4<UInt32>: MTLSamplerState] = [:]
  private(set) var textureUploads = 0
  struct Uniforms {
    var alphaFunction: UInt32
    var alphaReference: Float
    var textured: UInt32
    var environment: UInt32
    var environmentColor: SIMD4<Float>
    var second: SIMD4<UInt32>
    var environmentColor1: SIMD4<Float>
    var formats: SIMD4<UInt32>
    var fogParameters: SIMD4<Float>
    var fogColor: SIMD4<Float>
    var combine = GLESTextureCombine()
    var combine1 = GLESTextureCombine()
    var lighting = GLESLightingUniforms()
    var temporal = SIMD4<Float>(repeating: 0) // jitter pixels, enabled, reactive
    var lineRaster = SIMD4<Float>(repeating: 0) // replicated width, viewport width/height
  }
  init(uploadCapacity: Int = 8 * 1024 * 1024, textureCacheLimit: Int = 128 * 1024 * 1024,
    profiling: Bool = false, stagedReadback: Bool = true, renderScale: Int = 1, sampleCount: Int = 1, temporalTarget: Bool = false) throws {
    self.temporalTarget = temporalTarget
    guard uploadCapacity >= 256, textureCacheLimit > 0 else {
      throw EmulationError.invalid("GL buffer/cache size")
    }
    guard (1...4).contains(renderScale) else { throw EmulationError.invalid("Internal render scale") }
    guard [1, 2, 4].contains(sampleCount) else { throw EmulationError.invalid("MSAA sample count") }
    self.sampleCount = sampleCount
    self.renderScale = renderScale
    self.textureCacheLimit = textureCacheLimit
    self.stagedReadback = stagedReadback
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4),
      let queue = device.makeMTL4CommandQueue(), let command = device.makeCommandBuffer(),
      let completion = device.makeSharedEvent()
    else { throw EmulationError.unsupported("OpenGL ES HLE requires Metal 4") }
    guard device.supportsTextureSampleCount(sampleCount) else {
      throw EmulationError.unsupported("MSAA \(sampleCount)× is not supported on this GPU")
    }
    self.device = device
    self.queue = queue
    self.command = command
    self.completion = completion
    if profiling {
      let descriptor = MTL4CounterHeapDescriptor()
      descriptor.type = .timestamp
      descriptor.count = 2
      counterHeap = try device.makeCounterHeap(descriptor: descriptor)
      profileStartGPU = device.sampleTimestamps().gpu
      profileStartHost = DispatchTime.now().uptimeNanoseconds
    } else {
      counterHeap = nil
    }
    let tableDescriptor = MTL4ArgumentTableDescriptor()
    tableDescriptor.maxBufferBindCount = 5
    tableDescriptor.maxTextureBindCount = 2
    tableDescriptor.maxSamplerStateBindCount = 2
    arguments = try device.makeArgumentTable(descriptor: tableDescriptor)
    guard let uploadBuffer = device.makeBuffer(length: uploadCapacity, options: .storageModeShared)
    else { throw EmulationError.unsupported("GL upload buffer") }
    self.uploadBuffer = uploadBuffer
    allocator = try device.makeCommandAllocator(descriptor: MTL4CommandAllocatorDescriptor())
    compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: 640 * renderScale, height: 480 * renderScale, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = [.renderTarget, .shaderRead]
    guard let color = device.makeTexture(descriptor: descriptor) else {
      throw EmulationError.unsupported("GL color target")
    }
    self.color = color
    descriptor.pixelFormat = .depth32Float_stencil8
    descriptor.sampleCount = sampleCount
    descriptor.textureType = sampleCount > 1 ? .type2DMultisample : .type2D
    descriptor.storageMode = .private
    descriptor.usage = .renderTarget
    guard let depth = device.makeTexture(descriptor: descriptor) else {
      throw EmulationError.unsupported("GL depth target")
    }
    self.depth = depth
    descriptor.sampleCount = 1
    descriptor.textureType = .type2D
    descriptor.width = 1
    descriptor.height = 1
    descriptor.pixelFormat = .rgba8Unorm
    descriptor.storageMode = .shared
    descriptor.usage = .shaderRead
    guard let white = device.makeTexture(descriptor: descriptor) else {
      throw EmulationError.unsupported("GL default texture")
    }
    self.white = white
    var pixel: UInt32 = .max
    white.replace(
      region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
    residency = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
    for resource in [color, depth, white] { residency.addAllocation(resource) }
    residency.addAllocation(uploadBuffer)
    residency.commit()
    queue.addResidencySet(residency)
    let source = """
      #define TEMPORAL_TARGET \(temporalTarget ? 1 : 0)
      #include <metal_stdlib>
      using namespace metal;
      struct SurfaceVertex { float4 position [[position]]; };
      struct SurfaceScale { float4 source; float4 destination; };
      vertex SurfaceVertex surface_vertex(uint id [[vertex_id]]) {
          float2 p = id == 0 ? float2(-1,-1) : (id == 1 ? float2(3,-1) : float2(-1,3));
          return {float4(p,0,1)};
      }
      fragment float4 surface_fragment(SurfaceVertex v [[stage_in]],
          constant SurfaceScale& scale [[buffer(0)]], texture2d<float> image [[texture(0)]]) {
          float2 position = (v.position.xy - scale.destination.xy) / scale.destination.zw;
          if (any(position < 0) || any(position >= 1)) discard_fragment();
          float2 pixel = scale.source.xy + position * scale.source.zw;
          // Clamp to the crop's edge texel centers, not adjacent pixels outside the crop.
          pixel = clamp(pixel, scale.source.xy + 0.5, scale.source.xy + scale.source.zw - 0.5);
          constexpr sampler linearSample(coord::normalized, address::clamp_to_edge, filter::linear);
          return image.sample(linearSample, pixel / float2(image.get_width(), image.get_height()));
      }
      fragment float4 patch_fragment(SurfaceVertex v [[stage_in]], texture2d<float> patch [[texture(0)]],
          constant uint& scale [[buffer(0)]]) {
          float4 color = patch.read(uint2(v.position.xy) / scale);
          if (color.a == 0) discard_fragment();
          return color;
      }
      struct Input { float4 position; float4 color; float4 uv; float4 uv1; float4 fog; };
      struct Vertex { float4 position [[position]]; float4 color; float4 backColor; float4 uv; float4 uv1; float fogDistance; float pointSize [[point_size]]; float4 previousPosition; float4 currentPosition; };
      struct LightingVertex { float4 eyePosition; float4 normal; };
      struct Light { float4 ambient; float4 diffuse; float4 specular; float4 position; float4 direction; float4 attenuation; float4 spot; };
      struct Lighting { float4 ambient; float4 diffuse; float4 specular; float4 emission; float4 sceneAmbient; float4 controls; };
      struct Combine { uint4 functions; uint4 sourceRGB; uint4 sourceAlpha; uint4 operandRGB; uint4 operandAlpha; };
      struct Uniforms { uint alphaFunction; float alphaReference; uint textured; uint environment; float4 environmentColor; uint4 second; float4 environmentColor1; uint4 formats; float4 fogParameters; float4 fogColor; Combine combine; Combine combine1; Lighting lighting; float4 temporal; float4 lineRaster; };
      float3 unitDirection(float3 value) {
          float magnitude = length(value);
          return magnitude > 0 ? value / magnitude : float3(0);
      }
      float4 illuminate(float3 normal, float4 eyePosition, float4 color,
          constant Lighting& material, const device Light* lights) {
          float4 ambient = material.controls.z != 0 ? color : material.ambient;
          float4 diffuse = material.controls.z != 0 ? color : material.diffuse;
          float3 result = material.emission.rgb + ambient.rgb * material.sceneAmbient.rgb;
          float3 point = eyePosition.w != 0 ? eyePosition.xyz / eyePosition.w : eyePosition.xyz;
          for (uint index = 0; index < 8; ++index) {
              Light light = lights[index];
              if (light.attenuation.w == 0) continue;
              float3 delta = light.position.xyz;
              float attenuation = 1;
              if (light.position.w != 0) {
                  delta = light.position.xyz / light.position.w - point;
                  float distance = length(delta);
                  attenuation = 1 / max(dot(light.attenuation.xyz, float3(1,distance,distance*distance)), 1e-20f);
              }
              float3 direction = unitDirection(delta);
              float spot = 1;
              if (light.spot.y != 180) {
                  float cosine = max(dot(-direction, unitDirection(light.direction.xyz)), 0.0f);
                  spot = cosine >= cos(light.spot.y * 0.017453292519943295f)
                      ? (light.spot.x == 0 ? 1 : pow(cosine,light.spot.x)) : 0;
              }
              float facing = max(dot(normal,direction),0.0f);
              float specular = 0;
              if (facing > 0) {
                  float highlight = max(dot(normal,unitDirection(direction + float3(0,0,1))),0.0f);
                  specular = material.controls.w == 0 ? 1 : pow(highlight,material.controls.w);
              }
              result += attenuation * spot * (ambient.rgb * light.ambient.rgb
                  + facing * diffuse.rgb * light.diffuse.rgb + specular * material.specular.rgb * light.specular.rgb);
          }
          return saturate(float4(result,diffuse.a));
      }
      Vertex shadeVertex(uint id, const device Input* vertices,
          constant Uniforms& u, const device LightingVertex* lightingVertices,
          const device Light* lights, const device float4* history) {
          Input v = vertices[id]; Vertex o;
          o.position = v.position;
          o.currentPosition = v.position;
          o.previousPosition = u.temporal.z != 0 ? history[id] : v.position;
          if (u.temporal.z != 0) {
              o.position.xy += float2(2,-2) * u.temporal.xy * v.position.w / u.lineRaster.yz;
          }
          // GL uses [-w,w] clip depth; Metal uses [0,w].
          o.position.z = (v.position.z + v.position.w) * 0.5;
          // GLES 1.1 §2.12.5: clamp vertex colors even with lighting disabled,
          // before interpolation and texture modulation. Preserve raw current
          // color for state queries and the color-material lighting calculation.
          o.color = saturate(v.color); o.backColor = o.color;
          if (u.lighting.controls.x != 0) {
              LightingVertex lit = lightingVertices[id];
              o.color = illuminate(lit.normal.xyz, lit.eyePosition, v.color, u.lighting, lights);
              o.backColor = u.lighting.controls.y != 0
                  ? illuminate(-lit.normal.xyz, lit.eyePosition, v.color, u.lighting, lights) : o.color;
          }
          o.uv = v.uv; o.uv1 = v.uv1; o.fogDistance = v.fog.x; o.pointSize = u.lineRaster.w;
          return o;
      }
      Vertex mixVertex(Vertex a, Vertex b, float t) {
          Vertex o;
          o.position = mix(a.position,b.position,t);
          o.color = mix(a.color,b.color,t); o.backColor = mix(a.backColor,b.backColor,t);
          o.previousPosition = mix(a.previousPosition,b.previousPosition,t);
          o.currentPosition = mix(a.currentPosition,b.currentPosition,t);
          o.uv = mix(a.uv,b.uv,t); o.uv1 = mix(a.uv1,b.uv1,t);
          o.fogDistance = mix(a.fogDistance,b.fogDistance,t); o.pointSize = 1;
          return o;
      }
      vertex Vertex hle_vertex(uint id [[vertex_id]], uint instance [[instance_id]],
          const device Input* vertices [[buffer(0)]], constant Uniforms& u [[buffer(1)]],
          const device LightingVertex* lightingVertices [[buffer(2)]], const device Light* lights [[buffer(3)]], const device float4* history [[buffer(4)]]) {
          if (u.lineRaster.x <= 1) return shadeVertex(id,vertices,u,lightingVertices,lights,history);
          Vertex a = shadeVertex(id & ~1u,vertices,u,lightingVertices,lights,history);
          Vertex b = shadeVertex(id | 1u,vertices,u,lightingVertices,lights,history);
          // Clip the original segment before widening. Interpolate already-lit
          // endpoint attributes in homogeneous space, as for ordinary GPU clipping.
          float4 planes[6] = {float4(1,0,0,1),float4(-1,0,0,1),float4(0,1,0,1),
                              float4(0,-1,0,1),float4(0,0,1,0),float4(0,0,-1,1)};
          float lo=0, hi=1;
          bool outside=false;
          for (uint plane=0; plane<6; ++plane) {
              float da=dot(a.position,planes[plane]), db=dot(b.position,planes[plane]);
              if (da<0 && db<0) { outside=true; break; }
              if (da<0) lo=max(lo,da/(da-db));
              if (db<0) hi=min(hi,da/(da-db));
          }
          Vertex ca=mixVertex(a,b,lo), cb=mixVertex(a,b,hi);
          if (outside || lo>hi || ca.position.w<=0 || cb.position.w<=0) {
              ca.position=float4(2,2,2,1); return ca;
          }
          float2 delta=(cb.position.xy/cb.position.w-ca.position.xy/ca.position.w)*u.lineRaster.yz;
          uint minor=abs(delta.x)>=abs(delta.y) ? 1 : 0;
          Vertex o=(id & 1u) ? cb : ca;
          // GLES 1.1 section 3.4.2: offset/replicate along the minor axis.
          float displacement=float(instance)-(u.lineRaster.x-1)*0.5;
          o.position[minor] += 2*displacement*o.position.w/u.lineRaster[minor+1];
          return o;
      }
      float4 combineSource(uint source, float4 t, float4 previous, float4 primary, float4 constantColor) {
          if (source == 0x1702) return t;
          if (source == 0x8576) return constantColor;
          if (source == 0x8577) return primary;
          return previous;
      }
      float3 combineOperand(float4 value, uint operand) {
          if (operand == 0x0301) return 1 - value.rgb;
          if (operand == 0x0302) return float3(value.a);
          if (operand == 0x0303) return float3(1 - value.a);
          return value.rgb;
      }
      float3 combineFunction(uint mode, float3 a, float3 b, float3 c) {
          switch (mode) {
              case 0x1e01: return a;
              case 0x0104: return a + b;
              case 0x8574: return a + b - 0.5;
              case 0x8575: return a * c + b * (1 - c);
              case 0x84e7: return a - b;
              case 0x86ae: case 0x86af: return float3(4 * dot(a - 0.5, b - 0.5));
              default: return a * b;
          }
      }
      float4 textureStage(float4 incoming, float4 t, uint mode, uint format, float4 constantColor,
          float4 primary, constant Combine& combine) {
          if (mode == 0x8570) {
              if (format == 0x1906) t.rgb = 0;
              if (format == 0x1907 || format == 0x1909) t.a = 1;
              float3 rgbArgs[3]; float3 alphaArgs[3];
              for (uint i = 0; i < 3; ++i) {
                  rgbArgs[i] = combineOperand(combineSource(combine.sourceRGB[i],t,incoming,primary,constantColor),combine.operandRGB[i]);
                  alphaArgs[i] = combineOperand(combineSource(combine.sourceAlpha[i],t,incoming,primary,constantColor),combine.operandAlpha[i]);
              }
              float3 rgb = combineFunction(combine.functions.x,rgbArgs[0],rgbArgs[1],rgbArgs[2]);
              float alpha = combine.functions.x == 0x86af ? rgb.x
                  : combineFunction(combine.functions.y,alphaArgs[0],alphaArgs[1],alphaArgs[2]).x;
              return saturate(float4(rgb * float(combine.functions.z),alpha * float(combine.functions.w)));
          }

          float4 result = incoming;
          bool rgb = format != 0x1906;
          bool alpha = format == 0x1906 || format == 0x1908 || format == 0x190a;
          if (mode == 0x2101) {
              if (format == 0x1907) result.rgb = t.rgb;
              else if (format == 0x1908) result.rgb = mix(result.rgb,t.rgb,t.a);
          } else {
              if (rgb) {
                  if (mode == 0x1e01) result.rgb = t.rgb;
                  else if (mode == 0x0104) result.rgb += t.rgb;
                  else if (mode == 0x0be2) result.rgb = mix(result.rgb,constantColor.rgb,t.rgb);
                  else result.rgb *= t.rgb;
              }
              if (alpha) result.a = mode == 0x1e01 ? t.a : result.a * t.a;
          }
          return saturate(result);
      }
      #if TEMPORAL_TARGET
      struct FragmentOutput { float4 color [[color(0)]]; float2 motion [[color(1)]]; float depth [[color(2)]]; float reactive [[color(3)]]; };
      #else
      typedef float4 FragmentOutput;
      #endif
      fragment FragmentOutput hle_fragment(Vertex v [[stage_in]], bool front [[front_facing]], constant Uniforms& u [[buffer(1)]], texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]], texture2d<float> tex1 [[texture(1)]], sampler smp1 [[sampler(1)]]) {
          float4 primary = front ? v.color : v.backColor;
          float4 result = primary;
          if (u.textured) result = textureStage(result,tex.sample(smp,v.uv.xy / v.uv.w),u.environment,u.formats.x,u.environmentColor,primary,u.combine);
          if (u.second.x) result = textureStage(result,tex1.sample(smp1,v.uv1.xy / v.uv1.w),u.second.y,u.formats.y,u.environmentColor1,primary,u.combine1);
          if (u.fogParameters.x != 0) {
              float visibility;
              float distance = v.fogDistance;
              if (u.fogParameters.x == 0x2601) {
                  float range = u.fogParameters.w - u.fogParameters.z;
                  visibility = range != 0 ? (u.fogParameters.w - distance) / range : (distance < u.fogParameters.w ? 1 : 0);
              } else {
                  float opticalDepth = u.fogParameters.y * distance;
                  visibility = exp(u.fogParameters.x == 0x0801 ? -opticalDepth * opticalDepth : -opticalDepth);
              }
              result.rgb = mix(u.fogColor.rgb,result.rgb,saturate(visibility));
          }
          float a = result.a, r = u.alphaReference;
          bool pass = true;
          switch (u.alphaFunction) {
              case 0x0200: pass = false; break;
              case 0x0201: pass = a < r; break;
              case 0x0202: pass = a == r; break;
              case 0x0203: pass = a <= r; break;
              case 0x0204: pass = a > r; break;
              case 0x0205: pass = a != r; break;
              case 0x0206: pass = a >= r; break;
          }
          if (!pass) discard_fragment();
          #if TEMPORAL_TARGET
          FragmentOutput output;
          output.color = result;
          bool valid = v.previousPosition.w > 0 && all(isfinite(v.previousPosition));
          output.motion = valid ? v.previousPosition.xy / v.previousPosition.w - (v.position.xy - u.temporal.xy) : float2(0);
          output.depth = saturate(0.5 + 0.5 * v.currentPosition.z / v.currentPosition.w);
          output.reactive = valid ? u.temporal.w : 1;
          return output;
          #else
          return result;
          #endif
      }
      """
    let options = MTLCompileOptions()
    options.languageVersion = .version4_0
    library = try device.makeLibrary(source: source, options: options)
    if sampleCount > 1 {
      multisampleColor = try makeMultisampleTarget(format: .bgra8Unorm, width: color.width, height: color.height)
      residency.addAllocation(multisampleColor!); residency.commit()
    }
    if temporalTarget { try makeTemporalTargets() }
    try clear(mask: 0x4500, color: SIMD4(0, 0, 0, 1), depth: 1, stencil: 0)
  }
  /// No upload memory or allocator reuse until the entire batch has completed.
  /// Flush is allowed to complete synchronously; Finish and EGL waits require it.
  func finish() throws {
    guard !failed else { throw EmulationError.unsupported("GL Metal 4 GPU timeout") }
    guard recording else { return }
    encoder?.endEncoding()
    encoder = nil
    if let counterHeap { command.writeTimestamp(counterHeap: counterHeap, index: 1) }
    command.endCommandBuffer()
    recording = false
    residency.commit()
    queue.commit([command])
    submissions += 1
    serial &+= 1
    queue.signalEvent(completion, value: serial)
    let start = DispatchTime.now().uptimeNanoseconds
    let completed = completion.wait(untilSignaledValue: serial, timeoutMS: 5000)
    gpuWaitNanoseconds &+= DispatchTime.now().uptimeNanoseconds - start
    guard completed else {
      failed = true
      throw EmulationError.unsupported("GL Metal 4 GPU timeout")
    }
    if let counterHeap {
      if let data = try? counterHeap.resolveCounterRange(0..<2),
        data.count == 2 * MemoryLayout<MTL4TimestampHeapEntry>.stride {
        let pair = data.withUnsafeBytes {
          ($0.loadUnaligned(as: UInt64.self), $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
        }
        if pair.0 > 0, pair.1 >= pair.0 {
          gpuTimestampTicks &+= pair.1 - pair.0
          gpuTimestampBatches += 1
        } else { invalidTimestampBatches += 1 }
      } else { invalidTimestampBatches += 1 }
    }
    // An evicted image can still be referenced by an earlier draw in this batch.
    // Keep those textures alive and resident through GPU completion.
    for texture in batchTextures.values { residency.removeAllocation(texture) }
    for buffer in largeUploads { residency.removeAllocation(buffer) }
    residency.commit()
    batchTextures.removeAll(keepingCapacity: true)
    batchTextureBytes = 0
    largeUploads.removeAll(keepingCapacity: true)
    uploadOffset = 0
    batchDraws = 0
    batchPasses = 0
  }
  private func beginPass(_ descriptor: MTL4RenderPassDescriptor) throws -> MTL4RenderCommandEncoder
  {
    guard !failed else { throw EmulationError.unsupported("GL Metal 4 GPU timeout") }
    if !recording {
      allocator.reset()
      command.beginCommandBuffer(allocator: allocator)
      if let counterHeap { command.writeTimestamp(counterHeap: counterHeap, index: 0) }
      recording = true
    }
    guard let next = command.makeRenderCommandEncoder(descriptor: descriptor) else {
      throw EmulationError.unsupported("GL Metal 4 encoder")
    }
    if batchPasses > 0 {
      // Clear/load passes share color and depth. Metal 4 requires explicit ordering
      // across encoders, including attachment stores/loads.
      next.barrier(afterQueueStages: .all, beforeStages: .all, visibilityOptions: .device)
    }
    batchPasses += 1
    renderPasses += 1
    boundPipeline = nil
    boundDepth = nil
    boundStencilReference = nil
    boundViewport = nil
    boundDepthRange = nil
    boundScissor = nil
    boundCull = nil
    boundWinding = nil
    encoder = next
    return next
  }
  private func pass() -> MTL4RenderPassDescriptor {
    let pass = MTL4RenderPassDescriptor()
    pass.colorAttachments[0].texture = multisampleColor ?? color
    pass.colorAttachments[0].loadAction = .load
    pass.colorAttachments[0].storeAction = sampleCount > 1 ? .storeAndMultisampleResolve : .store
    pass.colorAttachments[0].resolveTexture = multisampleColor == nil ? nil : color
    for (index,target) in temporalTargets.enumerated() {
      pass.colorAttachments[index+1].texture = sampleCount > 1 ? temporalMultisampleTargets[index] : target
      pass.colorAttachments[index+1].loadAction = .load
      pass.colorAttachments[index+1].storeAction = sampleCount > 1 ? .storeAndMultisampleResolve : .store
      pass.colorAttachments[index+1].resolveTexture = sampleCount > 1 ? target : nil
    }
    pass.depthAttachment.texture = depth
    pass.depthAttachment.loadAction = .load
    pass.depthAttachment.storeAction = .store
    pass.stencilAttachment.texture = depth
    pass.stencilAttachment.loadAction = .load
    pass.stencilAttachment.storeAction = .store
    return pass
  }
  func clear(mask: UInt32, color value: SIMD4<Float>, depth valueDepth: Float, stencil: UInt32)
    throws
  {
    try prepareTemporalRenderer()
    try temporalRenderer?.clear(mask:mask,color:value,depth:valueDepth,stencil:stencil)
    let p = pass()
    if temporalTarget && mask & 0x4000 != 0 {
      temporalFrameInvalid = false
      for index in 1...3 {
        p.colorAttachments[index].loadAction = .clear
        p.colorAttachments[index].clearColor = MTLClearColorMake(index == 1 ? 0 : 1,0,0,0)
      }
    }
    if mask & 0x4000 != 0 {
      p.colorAttachments[0].loadAction = .clear
      p.colorAttachments[0].clearColor = MTLClearColorMake(
        Double(value.x), Double(value.y), Double(value.z), Double(value.w))
    }
    if mask & 0x0100 != 0 {
      p.depthAttachment.loadAction = .clear
      p.depthAttachment.clearDepth = Double(valueDepth)
    }
    if mask & 0x0400 != 0 {
      p.stencilAttachment.loadAction = .clear
      p.stencilAttachment.clearStencil = stencil & 0xff
    }
    encoder?.endEncoding()
    encoder = nil
    if batchPasses >= 128 { try finish() }
    _ = try beginPass(p)
  }
  func draw(_ draw: GLESDraw) throws {
    try prepareTemporalRenderer()
    try temporalRenderer?.draw(draw)
    var draw = draw
    let lineCopies = draw.mode == 1 || draw.mode == 3
      ? Int(max(1, min(GLESState.maximumLineWidth, draw.lineWidth.isFinite ? draw.lineWidth.rounded() : 1))) * renderScale : 1
    if lineCopies > 1 {
      let order: [Int]
      if draw.mode == 3 {
        order = draw.vertices.count >= 2 ? (0..<(draw.vertices.count-1)).flatMap { [$0,$0+1] } : []
      } else { order = Array(0..<(draw.vertices.count / 2 * 2)) }
      draw.vertices = order.map { draw.vertices[$0] }
      if let lighting = draw.lighting { draw.lighting?.vertices = order.map { lighting.vertices[$0] } }
      draw.mode = 1
    }
    // GLES 1.1 disables incomplete texture units; never sample unspecified GPU levels.
    if draw.texture?.samplingComplete == false { draw.texture = nil }
    if draw.texture1?.samplingComplete == false { draw.texture1 = nil }
    guard !draw.vertices.isEmpty, draw.viewport.z > 0, draw.viewport.w > 0 else { return }
    if draw.mode >= 4 && draw.enabled.contains(0x0b44) && draw.cull == 0x0408 { return }
    for (texture, environment) in [
      (draw.texture, draw.textureEnvironment), (draw.texture1, draw.textureEnvironment1),
    ] {
      if texture != nil && ![UInt32(0x2100), 0x2101, 0x1e01, 0x0104, 0x0be2, 0x8570].contains(environment) {
        throw EmulationError.unsupported("GL texture environment on Metal")
      }
    }
    let primitive: MTLPrimitiveType
    switch draw.mode {
    case 0: primitive = .point
    case 1: primitive = .line
    case 3: primitive = .lineStrip
    case 4: primitive = .triangle
    case 5: primitive = .triangleStrip
    default: throw EmulationError.unsupported("GL primitive")
    }
    guard !draw.enabled.contains(0x0b50) || draw.lighting != nil else {
      throw EmulationError.invalid("GL lighting data missing")
    }
    if let lighting = draw.lighting {
      guard lighting.vertices.count == draw.vertices.count && lighting.lights.count == 8 else {
        throw EmulationError.invalid("GL lighting buffer")
      }
    }
    let temporalData = temporalTarget ? temporalHistory.prepare(draw,width:color.width,height:color.height,scale:renderScale) : nil
    let vertexBytes = draw.vertices.count * MemoryLayout<GLESVertex>.stride
    let uniformOffset = (vertexBytes + 255) & ~255
    let lightingOffset = (uniformOffset + MemoryLayout<Uniforms>.stride + 255) & ~255
    let lightsOffset = lightingOffset + (draw.lighting?.vertices.count ?? 0) * MemoryLayout<GLESLightingVertex>.stride
    let historyOffset = (lightsOffset + (draw.lighting?.lights.count ?? 0) * MemoryLayout<GLESLight>.stride + 255) & ~255
    let uploadBytes = (historyOffset + (temporalData?.positions.count ?? 0) * MemoryLayout<SIMD4<Float>>.stride + 255) & ~255
    if batchDraws >= 256 || batchTextureBytes >= 64 * 1024 * 1024
      || uploadOffset + uploadBytes > uploadBuffer.length
    {
      try finish()
    }
    let buffer: MTLBuffer
    let offset: Int
    if uploadBytes > uploadBuffer.length {
      guard let large = device.makeBuffer(length: uploadBytes, options: .storageModeShared)
      else { throw EmulationError.unsupported("GL large vertex buffer") }
      buffer = large
      offset = 0
      largeUploads.append(large)
      residency.addAllocation(large)
      bufferAllocations += 1
    } else {
      buffer = uploadBuffer
      offset = uploadOffset
      uploadOffset += uploadBytes
    }
    draw.vertices.withUnsafeBytes {
      buffer.contents().advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: $0.count)
    }
    var uniforms = Uniforms(
      alphaFunction: draw.enabled.contains(0x0bc0) ? draw.alphaFunction : 0x0207,
      alphaReference: draw.alphaReference, textured: draw.texture == nil ? 0 : 1,
      environment: draw.textureEnvironment, environmentColor: draw.textureEnvironmentColor,
      second: SIMD4(draw.texture1 == nil ? 0 : 1, draw.textureEnvironment1, 0, 0),
      environmentColor1: draw.textureEnvironmentColor1,
      formats: SIMD4(draw.texture?.format ?? 0x1908, draw.texture1?.format ?? 0x1908, 0, 0),
      fogParameters: draw.fogParameters, fogColor: draw.fogColor,
      combine: draw.combine, combine1: draw.combine1,
      lighting: draw.lighting?.uniforms ?? GLESLightingUniforms(),
      temporal: temporalTarget ? SIMD4(temporalHistory.jitter.x,temporalHistory.jitter.y,1,temporalData!.reactive ? 1 : 0) : .zero,
      lineRaster: SIMD4(Float(lineCopies), Float(draw.viewport.z) * Float(renderScale),
        Float(draw.viewport.w) * Float(renderScale), Float(renderScale)))
    withUnsafeBytes(of: &uniforms) {
      buffer.contents().advanced(by: offset + uniformOffset).copyMemory(
        from: $0.baseAddress!, byteCount: $0.count)
    }
    if let lighting = draw.lighting {
      lighting.vertices.withUnsafeBytes {
        buffer.contents().advanced(by: offset + lightingOffset).copyMemory(from: $0.baseAddress!, byteCount: $0.count)
      }
      lighting.lights.withUnsafeBytes {
        buffer.contents().advanced(by: offset + lightsOffset).copyMemory(from: $0.baseAddress!, byteCount: $0.count)
      }
    }
    if let temporalData {
      temporalData.positions.withUnsafeBytes {
        buffer.contents().advanced(by:offset+historyOffset).copyMemory(from:$0.baseAddress!,byteCount:$0.count)
      }
    }
    arguments.setAddress(buffer.gpuAddress + UInt64(offset + (temporalTarget ? historyOffset : 0)), index:4)
    let sample0 = try makeSample(draw.texture)
    let sample1 = try makeSample(draw.texture1)
    arguments.setAddress(buffer.gpuAddress + UInt64(offset), index: 0)
    arguments.setAddress(buffer.gpuAddress + UInt64(offset + uniformOffset), index: 1)
    // Disabled lighting still binds valid memory; the shader branch performs no reads.
    arguments.setAddress(buffer.gpuAddress + UInt64(offset + (draw.lighting == nil ? 0 : lightingOffset)), index: 2)
    arguments.setAddress(buffer.gpuAddress + UInt64(offset + (draw.lighting == nil ? 0 : lightsOffset)), index: 3)
    arguments.setTexture(sample0.0.gpuResourceID, index: 0)
    arguments.setSamplerState(sample0.1.gpuResourceID, index: 0)
    arguments.setTexture(sample1.0.gpuResourceID, index: 1)
    arguments.setSamplerState(sample1.1.gpuResourceID, index: 1)
    let pipeline = try pipeline(draw)
    var stencil = draw.enabled.contains(0x0b90) ? draw.stencil : nil
    stencil?.reference = 0 // Dynamic encoder state; does not create a new depth/stencil object.
    let depthKey = DepthKey(depth: SIMD2<UInt32>(
      draw.enabled.contains(0x0b71) ? draw.depthFunction : 0x0207,
      draw.enabled.contains(0x0b71) && draw.depthWrite ? 1 : 0), stencil: stencil)
    let depthState: MTLDepthStencilState
    if let cached = depthStates[depthKey] {
      depthState = cached
    } else {
      let descriptor = MTLDepthStencilDescriptor()
      descriptor.isDepthWriteEnabled = depthKey.depth.y != 0
      descriptor.depthCompareFunction = try compare(depthKey.depth.x)
      if let stencil {
        let face = MTLStencilDescriptor()
        face.stencilCompareFunction = try compare(stencil.function)
        face.readMask = stencil.readMask; face.writeMask = stencil.writeMask
        face.stencilFailureOperation = try stencilOperation(stencil.fail)
        face.depthFailureOperation = try stencilOperation(stencil.depthFail)
        face.depthStencilPassOperation = try stencilOperation(stencil.pass)
        descriptor.frontFaceStencil = face; descriptor.backFaceStencil = face
      }
      guard let state = device.makeDepthStencilState(descriptor: descriptor) else {
        throw EmulationError.unsupported("GL depth test")
      }
      depthStates[depthKey] = state
      depthStateCreations += 1
      depthState = state
    }
    let encoder = try self.encoder ?? beginPass(pass())
    // Metal snapshots the argument table at draw time; buffer ranges stay immutable
    // until finish(), so different draws can safely share this one table.
    if boundPipeline !== pipeline {
      encoder.setRenderPipelineState(pipeline)
      boundPipeline = pipeline
      stateChanges += 1
    }
    if boundDepth !== depthState {
      encoder.setDepthStencilState(depthState)
      boundDepth = depthState
      stateChanges += 1
    }
    if stencil != nil && boundStencilReference != draw.stencil.reference {
      encoder.setStencilReferenceValue(draw.stencil.reference)
      boundStencilReference = draw.stencil.reference
      stateChanges += 1
    }
    encoder.setArgumentTable(arguments, stages: [.vertex, .fragment])
    if boundViewport != draw.viewport || boundDepthRange != draw.depthRange {
      encoder.setViewport(
        MTLViewport(
          originX: Double(draw.viewport.x) * Double(renderScale),
          originY: Double(Int32(surfaceHeight) - draw.viewport.y - draw.viewport.w) * Double(renderScale),
          width: Double(draw.viewport.z) * Double(renderScale),
          height: Double(draw.viewport.w) * Double(renderScale),
          znear: Double(draw.depthRange.x), zfar: Double(draw.depthRange.y)))
      boundViewport = draw.viewport
      boundDepthRange = draw.depthRange
      stateChanges += 1
    }
    let scissor: SIMD4<Int>
    if draw.enabled.contains(0x0c11) {
      let x = max(0, Int(draw.scissor.x))
      let y = max(0, surfaceHeight - Int(draw.scissor.y) - Int(draw.scissor.w))
      let right = min(surfaceWidth, Int(draw.scissor.x) + Int(draw.scissor.z))
      let bottom = min(surfaceHeight, surfaceHeight - Int(draw.scissor.y))
      guard right > x, bottom > y else { return }
      scissor = SIMD4(x, y, right - x, bottom - y)
    } else {
      scissor = SIMD4(0, 0, surfaceWidth, surfaceHeight)
    }
    if boundScissor != scissor {
      encoder.setScissorRect(MTLScissorRect(x: scissor.x * renderScale, y: scissor.y * renderScale,
        width: scissor.z * renderScale, height: scissor.w * renderScale))
      boundScissor = scissor
      stateChanges += 1
    }
    let cull: MTLCullMode = draw.enabled.contains(0x0b44) ? (draw.cull == 0x0404 ? .front : .back) : .none
    if boundCull != cull {
      encoder.setCullMode(cull)
      boundCull = cull
      stateChanges += 1
    }
    let winding: MTLWinding = draw.front == 0x0901 ? .counterClockwise : .clockwise
    if boundWinding != winding {
      encoder.setFrontFacing(winding)
      boundWinding = winding
      stateChanges += 1
    }
    encoder.drawPrimitives(
      primitiveType: primitive, vertexStart: 0, vertexCount: draw.vertices.count, instanceCount: lineCopies)
    batchDraws += 1
    // Bound oversized draws independently of the normal upload arena.
    if uploadBytes > uploadBuffer.length { try finish() }
  }
  private func makeSample(_ texture: GLESTexture?) throws -> (MTLTexture, MTLSamplerState) {
    var sampled = white
    var key = SIMD4(
      texture?.parameters[0x2800] ?? 0x2601, texture?.parameters[0x2801] ?? 0x2601,
      texture?.parameters[0x2802] ?? 0x2901, texture?.parameters[0x2803] ?? 0x2901)
    if pixelExactMagnification { key.x = 0x2600 }
    if let texture, texture.width > 0, texture.height > 0 {
      if let cached = textureCache[texture.imageID] {
        sampled = cached
      } else {
        let uploadStart = counterHeap == nil ? 0 : DispatchTime.now().uptimeNanoseconds
        let desc = MTLTextureDescriptor.texture2DDescriptor(
          pixelFormat: .rgba8Unorm, width: texture.width, height: texture.height, mipmapped: true)
        desc.storageMode = .shared
        desc.usage = .shaderRead
        guard let resource = device.makeTexture(descriptor: desc) else {
          throw EmulationError.unsupported("GL texture")
        }
        for level in 0..<texture.mipLevelCount {
          guard let image = texture.validImage(at: level) else { continue }
          image.pixels.withUnsafeBytes {
            resource.replace(
              region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: level,
              withBytes: $0.baseAddress!, bytesPerRow: image.width * 4)
          }
          textureUploadBytes &+= UInt64(image.width * image.height * 4)
        }
        if counterHeap != nil {
          textureUploadNanoseconds &+= DispatchTime.now().uptimeNanoseconds - uploadStart
        }
        // The active batch separately retains and registers sampled images, even
        // when a subsequent upload evicts one of them from this bounded cache.
        let bytes = textureBytes(resource)
        while cachedBytes + bytes > textureCacheLimit, !textureOrder.isEmpty {
          if let expired = textureCache.removeValue(forKey: textureOrder.removeFirst()) {
            cachedBytes -= textureBytes(expired)
          }
        }
        textureCache[texture.imageID] = resource
        textureOrder.append(texture.imageID)
        cachedBytes += bytes
        textureUploads += 1
        sampled = resource
      }
    }
    if let texture, sampled !== white, batchTextures[texture.imageID] == nil {
      batchTextures[texture.imageID] = sampled
      batchTextureBytes += textureBytes(sampled)
      residency.addAllocation(sampled)
    }
    if let cached = samplerCache[key] { return (sampled, cached) }
    let samplerDescriptor = MTLSamplerDescriptor()
    samplerDescriptor.supportArgumentBuffers = true
    samplerDescriptor.minFilter =
      [UInt32(0x2600), 0x2700, 0x2702].contains(key.y) ? .nearest : .linear
    switch key.y {
    case 0x2700, 0x2701: samplerDescriptor.mipFilter = .nearest
    case 0x2702, 0x2703: samplerDescriptor.mipFilter = .linear
    default: samplerDescriptor.mipFilter = .notMipmapped
    }
    samplerDescriptor.magFilter = key.x == 0x2600 ? .nearest : .linear
    samplerDescriptor.sAddressMode = key.z == 0x2901 ? .repeat : .clampToEdge
    samplerDescriptor.tAddressMode = key.w == 0x2901 ? .repeat : .clampToEdge
    guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
      throw EmulationError.unsupported("GL sampler")
    }
    samplerCache[key] = sampler
    return (sampled, sampler)
  }
  private func textureBytes(_ texture: MTLTexture) -> Int {
    (0..<texture.mipmapLevelCount).reduce(0) {
      $0 + max(1, texture.width >> $1) * max(1, texture.height >> $1) * 4
    }
  }
  private func stencilOperation(_ value: UInt32) throws -> MTLStencilOperation {
    switch value {
    case 0: return .zero
    case 0x1e00: return .keep
    case 0x1e01: return .replace
    case 0x1e02: return .incrementClamp
    case 0x1e03: return .decrementClamp
    case 0x150a: return .invert
    case 0x8507: return .incrementWrap
    case 0x8508: return .decrementWrap
    default: throw EmulationError.invalid("GL stencil operation " + value.hex)
    }
  }
  private func compare(_ value: UInt32) throws -> MTLCompareFunction {
    guard value >= 0x0200 && value <= 0x0207,
      let result = MTLCompareFunction(rawValue: UInt(value - 0x0200))
    else { throw EmulationError.invalid("GL depth comparison") }
    return result
  }
  private func factor(_ value: UInt32) throws -> MTLBlendFactor {
    switch value {
    case 0: return .zero
    case 1: return .one
    case 0x0300: return .sourceColor
    case 0x0301: return .oneMinusSourceColor
    case 0x0302: return .sourceAlpha
    case 0x0303: return .oneMinusSourceAlpha
    case 0x0304: return .destinationAlpha
    case 0x0305: return .oneMinusDestinationAlpha
    case 0x0306: return .destinationColor
    case 0x0307: return .oneMinusDestinationColor
    case 0x0308: return .sourceAlphaSaturated
    default: throw EmulationError.unsupported("GL blend factor " + value.hex)
    }
  }
  private func pipeline(_ draw: GLESDraw) throws -> MTLRenderPipelineState {
    let blending = draw.enabled.contains(0x0be2)
    let key = PipelineKey(
      blending: blending, factors: blending ? draw.blend : SIMD2(0, 0), mask: draw.colorMask)
    if let cached = pipelines[key] { return cached }
    let desc = MTL4RenderPipelineDescriptor()
    let vertex = MTL4LibraryFunctionDescriptor()
    vertex.library = library
    vertex.name = "hle_vertex"
    let fragment = MTL4LibraryFunctionDescriptor()
    fragment.library = library
    fragment.name = "hle_fragment"
    desc.vertexFunctionDescriptor = vertex
    desc.fragmentFunctionDescriptor = fragment
    desc.rasterSampleCount = sampleCount
    desc.colorAttachments[0].pixelFormat = .bgra8Unorm
    for (index,target) in temporalTargets.enumerated() {
      desc.colorAttachments[index+1].pixelFormat = target.pixelFormat
      desc.colorAttachments[index+1].blendingState = .disabled
      desc.colorAttachments[index+1].writeMask = .all
    }
    let attachment = desc.colorAttachments[0]!
    attachment.blendingState = blending ? .enabled : .disabled
    if blending {
      attachment.sourceRGBBlendFactor = try factor(draw.blend.x)
      attachment.destinationRGBBlendFactor = try factor(draw.blend.y)
      attachment.sourceAlphaBlendFactor = try factor(draw.blend.x)
      attachment.destinationAlphaBlendFactor = try factor(draw.blend.y)
    }
    var mask: MTLColorWriteMask = []
    if draw.colorMask.x != 0 { mask.insert(.red) }
    if draw.colorMask.y != 0 { mask.insert(.green) }
    if draw.colorMask.z != 0 { mask.insert(.blue) }
    if draw.colorMask.w != 0 { mask.insert(.alpha) }
    attachment.writeMask = mask
    let result = try compiler.makeRenderPipelineState(descriptor: desc, compilerTaskOptions: nil)
    pipelines[key] = result
    return result
  }
  func readback() throws -> Data { try readback(scale: nil) }

  func writeColorBuffer(_ pixels: Data, previous: Data) throws {
    let width = surfaceWidth, height = surfaceHeight
    guard pixels.count == width * height * 2, previous.count == pixels.count else {
      throw EmulationError.invalid("Writable EGL color buffer size")
    }
    guard pixels != previous else { return }
    try prepareTemporalRenderer()
    try temporalRenderer?.writeColorBuffer(pixels,previous:previous)
    if temporalTarget { temporalFrameInvalid = true; temporalHistory.invalidate() }
    try finish()
    if sampleCount > 1 {
      try patchMultisampleColor(pixels, previous: previous)
      return
    }
    // Upload only changed native pixels. Untouched high-resolution GPU pixels,
    // depth and stencil survive CPU writes to a portion of the mapped buffer.
    pixels.withUnsafeBytes { newBytes in previous.withUnsafeBytes { oldBytes in
      let src = newBytes.bindMemory(to: UInt16.self), old = oldBytes.bindMemory(to: UInt16.self)
      for y in 0..<height {
        var x = 0
        while x < width {
          if src[y * width + x] == old[y * width + x] { x += 1; continue }
          let start = x
          while x < width && src[y * width + x] != old[y * width + x] { x += 1 }
          let run = x - start, scaledWidth = run * renderScale
          var row = [UInt32](repeating: 0, count: scaledWidth * renderScale)
          for column in 0..<run {
            let native = UInt32(UInt16(littleEndian: src[y * width + start + column]))
            let r = (native >> 11) & 31, g = (native >> 5) & 63, b = native & 31
            let bgra = UInt32(0xff000000) | ((r << 3) | (r >> 2)) << 16 | ((g << 2) | (g >> 4)) << 8 | ((b << 3) | (b >> 2))
            for sy in 0..<renderScale { for sx in 0..<renderScale { row[sy * scaledWidth + column * renderScale + sx] = bgra } }
          }
          row.withUnsafeBytes { bytes in
            color.replace(region: MTLRegionMake2D(start * renderScale, y * renderScale, scaledWidth, renderScale),
              mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: scaledWidth * 4)
          }
        }
      }
    } }
  }

  private func makeMultisampleTarget(format: MTLPixelFormat, width: Int, height: Int) throws -> MTLTexture {
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
    desc.textureType = .type2DMultisample
    desc.sampleCount = sampleCount
    desc.storageMode = .private
    desc.usage = .renderTarget
    guard let texture = device.makeTexture(descriptor: desc) else {
      throw EmulationError.unsupported("MSAA target allocation")
    }
    return texture
  }

  private func patchMultisampleColor(_ pixels: Data, previous: Data) throws {
    let width = surfaceWidth, height = surfaceHeight
    var patch = [UInt32](repeating: 0, count: width * height)
    pixels.withUnsafeBytes { next in previous.withUnsafeBytes { old in
      for i in patch.indices {
        let value = UInt32(next.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self).littleEndian)
        guard value != UInt32(old.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self).littleEndian) else { continue }
        let r = (value >> 11) & 31, g = (value >> 5) & 63, b = value & 31
        patch[i] = 0xff000000 | ((r << 3) | (r >> 2)) << 16 | ((g << 2) | (g >> 4)) << 8 | ((b << 3) | (b >> 2))
      }
    } }
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    desc.storageMode = .shared; desc.usage = .shaderRead
    guard let texture = device.makeTexture(descriptor: desc) else { throw EmulationError.unsupported("MSAA CPU patch texture") }
    patch.withUnsafeBytes {
      texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4)
    }
    residency.addAllocation(texture); batchTextures[UUID()] = texture
    if patchPipeline == nil {
      let pipeline = MTL4RenderPipelineDescriptor()
      let vertex = MTL4LibraryFunctionDescriptor(); vertex.library = library; vertex.name = "surface_vertex"
      let fragment = MTL4LibraryFunctionDescriptor(); fragment.library = library; fragment.name = "patch_fragment"
      pipeline.vertexFunctionDescriptor = vertex; pipeline.fragmentFunctionDescriptor = fragment
      pipeline.rasterSampleCount = sampleCount
      pipeline.colorAttachments[0].pixelFormat = .bgra8Unorm
      patchPipeline = try compiler.makeRenderPipelineState(descriptor: pipeline, compilerTaskOptions: nil)
    }
    // finish() above guarantees offset zero is free. No depth/stencil attachment
    // is used, and unchanged pixels discard without touching any color sample.
    uploadBuffer.contents().storeBytes(of: UInt32(renderScale), as: UInt32.self)
    uploadOffset = 256
    arguments.setAddress(uploadBuffer.gpuAddress, index: 0)
    arguments.setTexture(texture.gpuResourceID, index: 0)
    let pass = MTL4RenderPassDescriptor()
    pass.colorAttachments[0].texture = multisampleColor!
    pass.colorAttachments[0].resolveTexture = color
    pass.colorAttachments[0].loadAction = .load
    pass.colorAttachments[0].storeAction = .storeAndMultisampleResolve
    let encoder = try beginPass(pass)
    encoder.setRenderPipelineState(patchPipeline!)
    encoder.setArgumentTable(arguments, stages: .fragment)
    encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(color.width), height: Double(color.height), znear: 0, zfar: 1))
    encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
    // A following guest draw needs the ordinary depth/stencil render pass.
    encoder.endEncoding(); self.encoder = nil
  }

  func resize(width: Int, height: Int) throws {
    guard (1...640).contains(width), (1...480).contains(height) else {
      throw EmulationError.invalid("Metal EGL surface size")
    }
    guard width != surfaceWidth || height != surfaceHeight else { return }
    try finish()
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
      width: width * renderScale, height: height * renderScale, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
    guard let nextColor = device.makeTexture(descriptor: descriptor) else {
      throw EmulationError.unsupported("Metal EGL color allocation")
    }
    descriptor.pixelFormat = .depth32Float_stencil8
    descriptor.sampleCount = sampleCount
    descriptor.textureType = sampleCount > 1 ? .type2DMultisample : .type2D
    descriptor.storageMode = .private; descriptor.usage = .renderTarget
    guard let nextDepth = device.makeTexture(descriptor: descriptor) else {
      throw EmulationError.unsupported("Metal EGL depth allocation")
    }
    let nextMultisample = sampleCount > 1
      ? try makeMultisampleTarget(format: .bgra8Unorm, width: nextColor.width, height: nextColor.height) : nil
    if let multisampleColor { residency.removeAllocation(multisampleColor) }
    multisampleColor = nextMultisample
    if let nextMultisample { residency.addAllocation(nextMultisample) }
    residency.removeAllocation(color); residency.removeAllocation(depth)
    for texture in scaledColors.values { residency.removeAllocation(texture) }
    for slot in readbackSlots { residency.removeAllocation(slot.buffer) }
    scaledColors.removeAll(); readbackSlots.removeAll()
    color = nextColor; depth = nextDepth
    residency.addAllocation(color); residency.addAllocation(depth); residency.commit()
    if temporalTarget { try makeTemporalTargets() }
    try temporalRenderer?.resize(width:width,height:height)
  }

  // Guest readbacks retain the logical surface resolution, independent of render scale.
  func readback(scale: GLESSurfaceScale?) throws -> Data {
    try readback(scale: scale, outputScale: 1)
  }
  func presentation(scale: GLESSurfaceScale?) throws -> RenderedFrame {
    var frame = RenderedFrame(pixels: try readback(scale: scale, outputScale: renderScale),
      width: color.width, height: color.height)
    if let temporalRenderer {
      frame.temporal = try temporalRenderer.temporalSnapshot(scale:scale)
    }
    return frame
  }
  private func temporalSnapshot(scale: GLESSurfaceScale?) throws -> TemporalFrame? {
    guard !temporalFrameInvalid else {
      temporalHistory.invalidate(); return nil
    }
    defer { temporalHistory.advance() }
    let pixels = try readback(scale:scale,outputScale:renderScale)
    func bytes(_ texture: MTLTexture, stride: Int) -> Data {
      var data = Data(count:texture.width*texture.height*stride)
      data.withUnsafeMutableBytes {
        texture.getBytes($0.baseAddress!,bytesPerRow:texture.width*stride,
          from:MTLRegionMake2D(0,0,texture.width,texture.height),mipmapLevel:0)
      }
      return data
    }
    var motion = bytes(temporalTargets[0],stride:4), depths = bytes(temporalTargets[1],stride:4)
    var reactive = bytes(temporalTargets[2],stride:1), jitter = temporalHistory.jitter
    let rectangle = SIMD4<Int32>(0,0,Int32(surfaceWidth),Int32(surfaceHeight))
    let identity = GLESSurfaceScale(source:rectangle,destination:rectangle)
    let transform = scale ?? identity
    let changedScale = previousTemporalScale != nil && previousTemporalScale != transform
    previousTemporalScale = transform
    if transform != identity {
      let w = color.width, h = color.height, factor = Float(renderScale)
      let source = SIMD4<Float>(Float(transform.source.x)*factor,
        Float(surfaceHeight-Int(transform.source.y+transform.source.w))*factor,
        Float(transform.source.z)*factor,Float(transform.source.w)*factor)
      let destination = SIMD4<Float>(Float(transform.destination.x)*factor,
        Float(surfaceHeight-Int(transform.destination.y+transform.destination.w))*factor,
        Float(transform.destination.z)*factor,Float(transform.destination.w)*factor)
      let ratio = SIMD2(destination.z/source.z,destination.w/source.w)
      jitter *= ratio
      let oldMotion=motion, oldDepth=depths, oldReactive=reactive
      motion=Data(count:w*h*4); depths=Data(count:w*h*4); reactive=Data(repeating:255,count:w*h)
      motion.withUnsafeMutableBytes { (outMotion: UnsafeMutableRawBufferPointer) in
        depths.withUnsafeMutableBytes { (outDepth: UnsafeMutableRawBufferPointer) in
          oldMotion.withUnsafeBytes { (inMotion: UnsafeRawBufferPointer) in
            oldDepth.withUnsafeBytes { (inDepth: UnsafeRawBufferPointer) in
          for y in 0..<h { for x in 0..<w {
            let i=y*w+x
            outDepth.storeBytes(of:Float(1),toByteOffset:i*4,as:Float.self)
            let u=(Float(x)+0.5-destination.x)/destination.z, v=(Float(y)+0.5-destination.y)/destination.w
            guard u>=0 && u<1 && v>=0 && v<1 else { continue }
            let sx=min(w-1,max(0,Int(source.x+u*source.z))), sy=min(h-1,max(0,Int(source.y+v*source.w)))
            let j=sy*w+sx
            outDepth.storeBytes(of:inDepth.loadUnaligned(fromByteOffset:j*4,as:Float.self),toByteOffset:i*4,as:Float.self)
            for c in 0..<2 {
              let value=Float(Float16(bitPattern:inMotion.loadUnaligned(fromByteOffset:j*4+c*2,as:UInt16.self)))*ratio[c]
              outMotion.storeBytes(of:Float16(value).bitPattern,toByteOffset:i*4+c*2,as:UInt16.self)
            }
            reactive[i]=oldReactive[j]
          } }
            }
          }
        }
      }
    }
    return TemporalFrame(color:pixels,depth:depths,motion:motion,reactive:reactive,
      width:color.width,height:color.height,jitter:jitter,generation:temporalHistory.generation,
      index:temporalHistory.index,reset:temporalHistory.requiresReset || changedScale)

  }
  private func readback(scale: GLESSurfaceScale?, outputScale: Int) throws -> Data {
    let width = surfaceWidth * outputScale, height = surfaceHeight * outputScale
    let byteCount = width * height * 4
    var target = color
    let rectangle = SIMD4<Int32>(0, 0, Int32(surfaceWidth), Int32(surfaceHeight))
    let identity = GLESSurfaceScale(source: rectangle, destination: rectangle)
    if let scale, !scale.isValid(width: surfaceWidth, height: surfaceHeight) { throw EmulationError.invalid("EGL scaling rectangles") }
    if outputScale != renderScale || (scale != nil && scale! != identity) {
      let scale = scale ?? identity
      if scaledColors[outputScale] == nil {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
          pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.storageMode = .shared
        desc.usage = .renderTarget
        guard let texture = device.makeTexture(descriptor: desc) else {
          throw EmulationError.unsupported("EGL scaling target")
        }
        scaledColors[outputScale] = texture
        residency.addAllocation(texture)
      }
      if scalePipeline == nil {
        let desc = MTL4RenderPipelineDescriptor()
        let vertex = MTL4LibraryFunctionDescriptor()
        vertex.library = library
        vertex.name = "surface_vertex"
        let fragment = MTL4LibraryFunctionDescriptor()
        fragment.library = library
        fragment.name = "surface_fragment"
        desc.vertexFunctionDescriptor = vertex
        desc.fragmentFunctionDescriptor = fragment
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        scalePipeline = try compiler.makeRenderPipelineState(
          descriptor: desc, compilerTaskOptions: nil)
      }
      // Append presentation to the drawing batch. The source texture is never overwritten.
      if uploadOffset + 256 > uploadBuffer.length { try finish() }
      let offset = uploadOffset
      uploadOffset += 256
      var source = SIMD4<Float>(scale.source)
      var destination = SIMD4<Float>(scale.destination)
      source.y = Float(surfaceHeight) - source.y - source.w
      destination.y = Float(surfaceHeight) - destination.y - destination.w
      source *= Float(renderScale)
      destination *= Float(outputScale)
      var values = [source, destination]
      values.withUnsafeMutableBytes {
        uploadBuffer.contents().advanced(by: offset).copyMemory(
          from: $0.baseAddress!, byteCount: $0.count)
      }
      arguments.setAddress(uploadBuffer.gpuAddress + UInt64(offset), index: 0)
      arguments.setTexture(color.gpuResourceID, index: 0)
      encoder?.endEncoding()
      encoder = nil
      let pass = MTL4RenderPassDescriptor()
      pass.colorAttachments[0].texture = scaledColors[outputScale]!
      pass.colorAttachments[0].loadAction = .clear
      pass.colorAttachments[0].storeAction = .store
      pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
      let encoder = try beginPass(pass)
      encoder.setRenderPipelineState(scalePipeline!)
      encoder.setArgumentTable(arguments, stages: .fragment)
      encoder.setViewport(
        MTLViewport(originX: 0, originY: 0, width: Double(width), height: Double(height), znear: 0, zfar: 1))
      encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
      scalePasses += 1
      target = scaledColors[outputScale]!
    }
    // Copy tiled GPU pixels into a leased linear buffer before the batch's
    // completion signal. Data owns the lease and keeps the Metal buffer alive;
    // no second CPU copy is needed. Three slots bound retained GPU storage.
    // If consumers retain all slots, use an owning direct copy without blocking
    // them or overwriting their images. Already-finished surfaces also use it.
    var slot: ReadbackSlot?
    if stagedReadback && recording {
      slot = readbackSlots.first(where: { $0.claim() })
      if slot == nil, readbackSlots.count < 3 {
        guard let buffer = device.makeBuffer(length: color.width * color.height * 4, options: .storageModeShared) else {
          throw EmulationError.unsupported("GL Metal 4 readback buffer")
        }
        let created = ReadbackSlot(buffer)
        _ = created.claim()
        readbackSlots.append(created)
        slot = created
        residency.addAllocation(buffer)
      }
      if slot == nil { readbackPoolFallbacks += 1 }
    }
    var handedToData = false
    defer { if !handedToData { slot?.release() } }
    if let slot {
      encoder?.endEncoding()
      encoder = nil
      guard let copy = command.makeComputeCommandEncoder() else {
        throw EmulationError.unsupported("GL Metal 4 copy encoder")
      }
      copy.barrier(afterQueueStages: .all, beforeStages: .blit, visibilityOptions: .device)
      copy.copy(sourceTexture: target, sourceSlice: 0, sourceLevel: 0,
        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: width, height: height, depth: 1),
        destinationBuffer: slot.buffer, destinationOffset: 0, destinationBytesPerRow: width * 4,
        destinationBytesPerImage: 0)
      copy.endEncoding()
      stagedReadbacks += 1
    }
    try finish()
    let readbackStart = counterHeap == nil ? 0 : DispatchTime.now().uptimeNanoseconds
    var output: Data
    if let slot {
      output = Data(bytesNoCopy: slot.buffer.contents(), count: byteCount,
        deallocator: .custom { _, _ in slot.release() })
      handedToData = true
    } else {
      output = Data(count: byteCount)
      output.withUnsafeMutableBytes {
        target.getBytes(
          $0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
      }
    }
    readbackBytes &+= UInt64(output.count)
    if counterHeap != nil {
      readbackNanoseconds &+= DispatchTime.now().uptimeNanoseconds - readbackStart
    }
    return output
  }
  /// GPU timestamp span, calibrated against monotonic host time across the run.
  /// Includes GPU scheduling gaps inside a batch, not queue latency before it.
  var profile: [String: Any] {
    var result: [String: Any] = [
      "sampleCount": sampleCount, "renderScale": renderScale, "renderWidth": color.width, "renderHeight": color.height,
      "enabled": counterHeap != nil, "submissions": submissions, "renderPasses": renderPasses,
      "bufferAllocations": bufferAllocations, "textureUploads": textureUploads,
      "textureUploadBytes": textureUploadBytes, "readbackBytes": readbackBytes,
      "cpuWaitMilliseconds": Double(gpuWaitNanoseconds) / 1e6,
      "stateChanges": stateChanges,
      "stagedReadbacks": stagedReadbacks,
      "readbackPoolSlots": readbackSlots.count, "readbackPoolFallbacks": readbackPoolFallbacks,
    ]
    if counterHeap != nil {
      let endGPU = device.sampleTimestamps().gpu
      let endHost = DispatchTime.now().uptimeNanoseconds
      result["textureUploadMilliseconds"] = Double(textureUploadNanoseconds) / 1e6
      result["readbackMilliseconds"] = Double(readbackNanoseconds) / 1e6
      result["gpuTimestampBatches"] = gpuTimestampBatches
      result["invalidTimestampBatches"] = invalidTimestampBatches
      if endGPU > profileStartGPU, endHost > profileStartHost {
        let nsPerTick = Double(endHost - profileStartHost) / Double(endGPU - profileStartGPU)
        result["gpuBatchMilliseconds"] = Double(gpuTimestampTicks) * nsPerTick / 1e6
        result["gpuNanosecondsPerTick"] = nsPerTick
      }
    }
    return result
  }
  deinit {
    // Discard unsubmitted work on stop. Submitted buffers remain alive until completion.
    if recording {
      encoder?.endEncoding()
      command.endCommandBuffer()
    }
    if serial > 0 { _ = completion.wait(untilSignaledValue: serial, timeoutMS: 5000) }
  }
}
