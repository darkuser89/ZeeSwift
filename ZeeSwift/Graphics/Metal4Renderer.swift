import MetalKit
import MetalFX

/// All GPU submissions, pipeline compilation and resource binding use Metal 4.
final class Metal4Renderer: NSObject, MTKViewDelegate {
  let device: MTLDevice
  private let queue: MTL4CommandQueue
  private let command: MTL4CommandBuffer
  private let allocator: MTL4CommandAllocator
  private let completion: MTLSharedEvent
  private let residency: MTLResidencySet
  private let arguments: MTL4ArgumentTable
  private let compiler: MTL4Compiler
  private let metalFXFence: MTLFence
  private var spatialScaler: MTL4FXSpatialScaler?
  private var scaledTexture: MTLTexture?
  private var scaledUpload: Int?
  var metalFXMode = MetalFXMode.off
  static var supportsMetalFX: Bool {
    MTLCreateSystemDefaultDevice().map { MTLFXSpatialScalerDescriptor.supportsMetal4FX($0) } ?? false
  }
  private(set) var metalFXPasses = 0
  private(set) var metalFXCreations = 0
  var metalFXOutputSize: SIMD2<Int>? { scaledTexture.map { SIMD2($0.width, $0.height) } }
  private var temporalUpscaler: Metal4TemporalUpscaler?
  private var temporalFrame: TemporalFrame?
  var temporalPasses: Int { temporalUpscaler?.passes ?? 0 }
  var temporalResets: Int { temporalUpscaler?.resets ?? 0 }
  private(set) var activeMetalFXMode = MetalFXMode.off
  static var supportsTemporal: Bool {
    MTLCreateSystemDefaultDevice().map { MTLFXTemporalScalerDescriptor.supportsMetal4FX($0) } ?? false
  }
  private let temporalPipeline: MTLRenderPipelineState
  private let pipeline: MTLRenderPipelineState
  private var texture: MTLTexture
  var uploadedSize: SIMD2<Int> { SIMD2(texture.width, texture.height) }
  private let frames: FrameStore
  var windowScaling = WindowScaling.preserveAspect
  private var serial: UInt64 = 0
  private var uploadedSequence: UInt64?
  private(set) var frameUploads = 0
  private(set) var failure: String?
  var onFailure: ((String) -> Void)?
  init(frames: FrameStore) throws {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else {
      throw EmulationError.unsupported("Metal 4 requires macOS 26 and a compatible Apple GPU")
    }
    self.device = device
    self.frames = frames
    guard let queue = device.makeMTL4CommandQueue(), let command = device.makeCommandBuffer(),
      let completion = device.makeSharedEvent(), let metalFXFence = device.makeFence()
    else { throw EmulationError.unsupported("Metal 4 queue/command buffer") }
    self.queue = queue
    self.command = command
    self.completion = completion
    self.metalFXFence = metalFXFence
    allocator = try device.makeCommandAllocator(descriptor: MTL4CommandAllocatorDescriptor())
    let desc = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: FrameStore.width, height: FrameStore.height, mipmapped: false
    )
    desc.storageMode = .shared
    desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
    guard let texture = device.makeTexture(descriptor: desc) else {
      throw EmulationError.unsupported("Framebuffer texture")
    }
    self.texture = texture
    let residencyDesc = MTLResidencySetDescriptor()
    residencyDesc.initialCapacity = 4
    residency = try device.makeResidencySet(descriptor: residencyDesc)
    residency.addAllocation(texture)
    residency.commit()
    queue.addResidencySet(residency)
    let tableDesc = MTL4ArgumentTableDescriptor()
    tableDesc.maxTextureBindCount = 1
    arguments = try device.makeArgumentTable(descriptor: tableDesc)
    arguments.setTexture(texture.gpuResourceID, index: 0)
    let source = """
      #include <metal_stdlib>
      using namespace metal;
      struct ScreenVertex { float4 position [[position]]; float2 uv; };
      vertex ScreenVertex screen_vertex(uint id [[vertex_id]]) {
          float2 uv = float2((id << 1) & 2, id & 2);
          ScreenVertex out;
          out.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
          out.uv = uv;
          return out;
      }
      fragment float4 screen_fragment(ScreenVertex in [[stage_in]], texture2d<float> image [[texture(0)]]) {
          constexpr sampler pointSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
          return float4(image.sample(pointSampler, in.uv).rgb, 1);
      }
      fragment float4 screen_temporal_fragment(ScreenVertex in [[stage_in]], texture2d<float> image [[texture(0)]]) {
          constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
          float3 c=max(image.sample(s,in.uv).rgb,0.0);
          return float4(saturate(select(1.055*pow(c,float3(1.0/2.4))-0.055,12.92*c,c<=0.0031308)),1);
      }
      """
    let options = MTLCompileOptions()
    options.languageVersion = .version4_0
    let library = try device.makeLibrary(source: source, options: options)
    let vertex = MTL4LibraryFunctionDescriptor()
    vertex.library = library
    vertex.name = "screen_vertex"
    let fragment = MTL4LibraryFunctionDescriptor()
    fragment.library = library
    fragment.name = "screen_fragment"
    let pipelineDesc = MTL4RenderPipelineDescriptor()
    pipelineDesc.vertexFunctionDescriptor = vertex
    pipelineDesc.fragmentFunctionDescriptor = fragment
    pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
    compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
    pipeline = try compiler.makeRenderPipelineState(
      descriptor: pipelineDesc, compilerTaskOptions: nil)
    fragment.name = "screen_temporal_fragment"
    // Metal copies function descriptors on assignment. Reassign after changing
    // the entry point so linear Temporal output is encoded back to SDR.
    pipelineDesc.fragmentFunctionDescriptor = fragment
    temporalPipeline = try compiler.makeRenderPipelineState(descriptor:pipelineDesc,compilerTaskOptions:nil)
    super.init()
  }
  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
  func draw(in view: MTKView) {
    guard failure == nil else { return }
    // One frame in flight: deterministic ownership while the HLE renderer is under development.
    if serial > 0, !completion.wait(untilSignaledValue: serial, timeoutMS: 1000) {
      failure = "Metal-4-GPU-Timeout"
      onFailure?(failure!)
      return
    }
    guard let drawable = view.currentDrawable else { return }
    uploadLatestFrame()
    guard failure == nil else { return }
    allocator.reset()
    command.beginCommandBuffer(allocator: allocator)
    do { try encodePresentation(to: drawable.texture) }
    catch {
      command.endCommandBuffer()
      failure = error.localizedDescription
      onFailure?(failure!)
      return
    }
    command.endCommandBuffer()
    queue.waitForDrawable(drawable)
    queue.commit([command])
    queue.signalDrawable(drawable)
    serial &+= 1
    queue.signalEvent(completion, value: serial)
    drawable.present()
  }
  /// Both window presentation and readback verification use this exact GPU path.
  private func encodePresentation(to target: MTLTexture) throws {
    let viewport = presentationViewport(width: target.width, height: target.height)
    let outputWidth = max(1, Int(viewport.width.rounded()))
    let outputHeight = max(1, Int(viewport.height.rounded()))
    var presented = texture
    activeMetalFXMode = .off
    let temporalReady = metalFXMode == .temporal && Self.supportsTemporal
      && temporalFrame?.isValid == true && outputWidth >= texture.width && outputHeight >= texture.height
    if temporalReady, let frame = temporalFrame {
      if temporalUpscaler == nil { temporalUpscaler = try Metal4TemporalUpscaler(device:device,compiler:compiler,residency:residency,fence:metalFXFence) }
      let scale = max(Double(outputWidth)/Double(frame.width),Double(outputHeight)/Double(frame.height))
      presented = try temporalUpscaler!.encode(frame,width:Int((Double(frame.width)*scale).rounded()),
        height:Int((Double(frame.height)*scale).rounded()),command:command)
      activeMetalFXMode = .temporal
    } else { temporalUpscaler = nil }
    let upscale = !temporalReady && metalFXMode != .off && MTLFXSpatialScalerDescriptor.supportsMetal4FX(device)
      && outputWidth >= texture.width && outputHeight >= texture.height
      && (outputWidth > texture.width || outputHeight > texture.height)
    if upscale {
      if spatialScaler?.inputWidth != texture.width || spatialScaler?.inputHeight != texture.height
        || scaledTexture?.width != outputWidth || scaledTexture?.height != outputHeight {
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = texture.width; descriptor.inputHeight = texture.height
        descriptor.outputWidth = outputWidth; descriptor.outputHeight = outputHeight
        descriptor.colorTextureFormat = .bgra8Unorm; descriptor.outputTextureFormat = .bgra8Unorm
        descriptor.colorProcessingMode = .perceptual
        guard let scaler = descriptor.makeSpatialScaler(device: device, compiler: compiler) else {
          throw EmulationError.unsupported("MetalFX spatial scaler creation failed")
        }
        guard texture.usage.isSuperset(of: scaler.colorTextureUsage) else {
          throw EmulationError.unsupported("MetalFX input texture usage")
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
          width: outputWidth, height: outputHeight, mipmapped: false)
        desc.storageMode = .private
        desc.usage = scaler.outputTextureUsage.union(.shaderRead)
        guard let output = device.makeTexture(descriptor: desc) else {
          throw EmulationError.unsupported("MetalFX output texture allocation failed")
        }
        if let old = scaledTexture { residency.removeAllocation(old) }
        residency.addAllocation(output); residency.commit()
        spatialScaler = scaler; scaledTexture = output; scaledUpload = nil
        scaler.fence = metalFXFence
        metalFXCreations += 1
      }
      if let scaler = spatialScaler, let output = scaledTexture {
        if scaledUpload != frameUploads {
          scaler.colorTexture = texture; scaler.outputTexture = output
          scaler.inputContentWidth = texture.width; scaler.inputContentHeight = texture.height
          guard let prepare = command.makeComputeCommandEncoder() else {
            throw EmulationError.unsupported("MetalFX synchronization encoder")
          }
          prepare.updateFence(metalFXFence, afterEncoderStages: .dispatch)
          prepare.endEncoding()
          scaler.encode(commandBuffer: command)
          scaledUpload = frameUploads; metalFXPasses += 1
        }
        presented = output
        activeMetalFXMode = .spatial
      }
    } else if let old = scaledTexture {
      residency.removeAllocation(old); residency.commit()
      scaledTexture = nil; spatialScaler = nil; scaledUpload = nil
    }
    arguments.setTexture(presented.gpuResourceID, index: 0)
    let pass = MTL4RenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
    guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
      throw EmulationError.unsupported("Metal 4 presentation encoder")
    }
    // Metal 4 resources are untracked. Make MetalFX compute writes visible
    // before the presentation fragment samples its output, within this queue.
    encoder.barrier(afterQueueStages: .all, beforeStages: .fragment, visibilityOptions: .device)
    if upscale || temporalReady { encoder.waitForFence(metalFXFence, beforeEncoderStages: .fragment) }
    encoder.setRenderPipelineState(temporalReady ? temporalPipeline : pipeline)
    encoder.setArgumentTable(arguments, stages: .fragment)
    encoder.setViewport(viewport)
    encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
  }
  private func presentationViewport(width: Int, height: Int) -> MTLViewport {
    let w = Double(width), h = Double(height)
    if windowScaling == .fill {
      return MTLViewport(originX: 0, originY: 0, width: w, height: h, znear: 0, zfar: 1)
    }
    let scale = min(w / 640, h / 480)
    return MTLViewport(originX: (w - 640 * scale) / 2, originY: (h - 480 * scale) / 2,
      width: 640 * scale, height: 480 * scale, znear: 0, zfar: 1)
  }
  /// Called only after prior GPU use of the shared presentation texture completes.
  /// Resizing still redraws the cached image, even when the guest has no new frame.
  func uploadLatestFrame() {
    let (frame, sequence) = frames.presentationSnapshot()
    guard uploadedSequence != sequence else { return }
    temporalFrame = frame.temporal
    if texture.width != frame.width || texture.height != frame.height {
      let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
        width: frame.width, height: frame.height, mipmapped: false)
      desc.storageMode = .shared
      desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
      guard let replacement = device.makeTexture(descriptor: desc) else {
        failure = "Metal 4 presentation texture allocation failed"
        onFailure?(failure!)
        return
      }
      residency.removeAllocation(texture)
      residency.addAllocation(replacement)
      residency.commit()
      texture = replacement
      arguments.setTexture(texture.gpuResourceID, index: 0)
    }
    frame.pixels.withUnsafeBytes {
      texture.replace(
        region: MTLRegionMake2D(0, 0, frame.width, frame.height), mipmapLevel: 0,
        withBytes: $0.baseAddress!, bytesPerRow: frame.width * 4)
    }
    uploadedSequence = sequence
    frameUploads += 1
  }
  /// Readback test of the actual Metal-4 pipeline, queue, arguments and residency.
  @discardableResult func verifyGPU(width: Int = 64, height: Int = 48, useFrameStore: Bool = false) throws -> [UInt32] {
    if serial > 0, !completion.wait(untilSignaledValue: serial, timeoutMS: 5000) {
      throw EmulationError.unsupported("GPU test previous submission timeout")
    }
    if useFrameStore { uploadLatestFrame() }
    let desc = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    desc.storageMode = .shared
    desc.usage = [.renderTarget]
    guard let target = device.makeTexture(descriptor: desc) else {
      throw EmulationError.unsupported("GPU test texture")
    }
    residency.addAllocation(target)
    residency.commit()
    defer {
      residency.removeAllocation(target)
      residency.commit()
    }
    if !useFrameStore {
      // Verification changes the texture independently of FrameStore.
      uploadedSequence = nil
      var pattern = [UInt32](repeating: 0xff32_7ac4, count: texture.width * texture.height)
      pattern.withUnsafeMutableBytes {
        texture.replace(
          region: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0, withBytes: $0.baseAddress!,
          bytesPerRow: texture.width * 4)
      }
      scaledUpload = nil
    }
    allocator.reset()
    command.beginCommandBuffer(allocator: allocator)
    try encodePresentation(to: target)
    command.endCommandBuffer()
    queue.commit([command])
    serial &+= 1
    queue.signalEvent(completion, value: serial)
    guard completion.wait(untilSignaledValue: serial, timeoutMS: 5000) else {
      throw EmulationError.unsupported("GPU test timeout")
    }
    var result = [UInt32](repeating: 0, count: width * height)
    result.withUnsafeMutableBytes {
      target.getBytes(
        $0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    }
    if useFrameStore { return result }
    let fullImage = windowScaling == .fill || width * 3 == height * 4
    guard result[(height / 2) * width + width / 2] == 0xff32_7ac4,
      !fullImage || result.allSatisfy({ $0 == 0xff32_7ac4 }) else {
      throw EmulationError.invalid("Metal 4 pixel readback test")
    }
    return result
  }
  deinit { if serial > 0 { _ = completion.wait(untilSignaledValue: serial, timeoutMS: 5000) } }
}

/// Genuine Metal 4 Temporal scaling; input history belongs to guest swaps, not UI redraws.
private final class Metal4TemporalUpscaler {
  let device: MTLDevice
  let compiler: MTL4Compiler
  let residency: MTLResidencySet
  let fence: MTLFence
  let conversion: MTLRenderPipelineState
  let arguments: MTL4ArgumentTable
  var scaler: MTL4FXTemporalScaler?
  var textures: [MTLTexture] = [] // uploaded SDR, linear color, depth, motion, reactive, output
  var lastGeneration: UUID?
  var lastIndex: UInt64?
  var lastTime: Double = 0
  private(set) var passes = 0
  private(set) var resets = 0
  init(device: MTLDevice, compiler: MTL4Compiler, residency: MTLResidencySet, fence: MTLFence) throws {
    self.device = device; self.compiler = compiler; self.residency = residency; self.fence = fence
    let desc = MTL4ArgumentTableDescriptor(); desc.maxTextureBindCount = 1
    arguments = try device.makeArgumentTable(descriptor:desc)
    let options = MTLCompileOptions(); options.languageVersion = .version4_0
    let library = try device.makeLibrary(source:"""
      #include <metal_stdlib>
      using namespace metal;
      struct V { float4 p [[position]]; float2 uv; };
      vertex V linear_vertex(uint id [[vertex_id]]) {
        float2 uv=float2((id<<1)&2,id&2); return {float4(uv*float2(2,-2)+float2(-1,1),0,1),uv};
      }
      fragment float4 linear_fragment(V v [[stage_in]],texture2d<float> t [[texture(0)]]) {
        constexpr sampler s(coord::normalized,filter::nearest);
        float3 c=t.sample(s,v.uv).rgb;
        return float4(select(pow((c+0.055)/1.055,float3(2.4)),c/12.92,c<=0.04045),1);
      }
      """,options:options)
    let vertex = MTL4LibraryFunctionDescriptor(); vertex.library=library; vertex.name="linear_vertex"
    let fragment = MTL4LibraryFunctionDescriptor(); fragment.library=library; fragment.name="linear_fragment"
    let pipeline = MTL4RenderPipelineDescriptor()
    pipeline.vertexFunctionDescriptor=vertex; pipeline.fragmentFunctionDescriptor=fragment
    pipeline.colorAttachments[0].pixelFormat = .rgba16Float
    conversion = try compiler.makeRenderPipelineState(descriptor:pipeline,compilerTaskOptions:nil)
  }
  func encode(_ frame: TemporalFrame, width: Int, height: Int, command: MTL4CommandBuffer) throws -> MTLTexture {
    let changed = scaler?.inputWidth != frame.width || scaler?.inputHeight != frame.height
      || scaler?.outputWidth != width || scaler?.outputHeight != height
    if changed {
      let descriptor = MTLFXTemporalScalerDescriptor()
      descriptor.inputWidth=frame.width; descriptor.inputHeight=frame.height
      descriptor.outputWidth=width; descriptor.outputHeight=height
      descriptor.colorTextureFormat = .rgba16Float; descriptor.depthTextureFormat = .r32Float
      descriptor.motionTextureFormat = .rg16Float; descriptor.outputTextureFormat = .rgba16Float
      descriptor.isReactiveMaskTextureEnabled=true; descriptor.reactiveMaskTextureFormat = .r8Unorm
      descriptor.isAutoExposureEnabled=false
      guard let created = descriptor.makeTemporalScaler(device:device,compiler:compiler) else {
        throw EmulationError.unsupported("MetalFX Temporal scaler creation failed")
      }
      for texture in textures { residency.removeAllocation(texture) }; textures.removeAll()
      for (i,format): (Int,MTLPixelFormat) in [MTLPixelFormat.bgra8Unorm,.rgba16Float,.r32Float,.rg16Float,.r8Unorm,.rgba16Float].enumerated() {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,
          width:i==5 ? width:frame.width,height:i==5 ? height:frame.height,mipmapped:false)
        desc.storageMode = i==1 || i==5 ? .private : .shared
        let usage: MTLTextureUsage = i==1 ? created.colorTextureUsage : i==2 ? created.depthTextureUsage
          : i==3 ? created.motionTextureUsage : i==4 ? created.reactiveTextureUsage : i==5 ? created.outputTextureUsage : []
        desc.usage=usage.union([.shaderRead,.renderTarget])
        guard let texture=device.makeTexture(descriptor:desc) else { throw EmulationError.unsupported("MetalFX Temporal texture") }
        textures.append(texture); residency.addAllocation(texture)
      }
      residency.commit(); scaler=created; created.fence=fence
      lastGeneration=nil; lastIndex=nil
    }
    guard let scaler else { throw EmulationError.invalid("MetalFX Temporal scaler") }
    if lastGeneration == frame.generation && lastIndex == frame.index { return textures[5] }
    for (index,data,stride): (Int,Data,Int) in [(0,frame.color,4),(2,frame.depth,4),(3,frame.motion,4),(4,frame.reactive,1)] {
      data.withUnsafeBytes {
        textures[index].replace(region:MTLRegionMake2D(0,0,frame.width,frame.height),mipmapLevel:0,
          withBytes:$0.baseAddress!,bytesPerRow:frame.width*stride)
      }
    }
    let pass=MTL4RenderPassDescriptor(); pass.colorAttachments[0].texture=textures[1]
    pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
    guard let encoder=command.makeRenderCommandEncoder(descriptor:pass) else { throw EmulationError.unsupported("Temporal linearization encoder") }
    encoder.barrier(afterQueueStages:.all,beforeStages:.fragment,visibilityOptions:.device)
    arguments.setTexture(textures[0].gpuResourceID,index:0)
    encoder.setRenderPipelineState(conversion); encoder.setArgumentTable(arguments,stages:.fragment)
    encoder.drawPrimitives(primitiveType:.triangle,vertexStart:0,vertexCount:3)
    encoder.updateFence(fence,afterEncoderStages:.fragment); encoder.endEncoding()
    let now=ProcessInfo.processInfo.systemUptime
    scaler.reset = changed || frame.reset || lastGeneration != frame.generation
      || lastIndex.map { $0 &+ 1 != frame.index } != false || (lastTime > 0 && now-lastTime > 0.5)
    if scaler.reset { resets += 1 }
    scaler.colorTexture=textures[1]; scaler.depthTexture=textures[2]; scaler.motionTexture=textures[3]
    scaler.reactiveMaskTexture=textures[4]; scaler.outputTexture=textures[5]
    scaler.inputContentWidth=frame.width; scaler.inputContentHeight=frame.height
    scaler.jitterOffsetX=frame.jitter.x; scaler.jitterOffsetY=frame.jitter.y
    scaler.motionVectorScaleX=1; scaler.motionVectorScaleY=1
    scaler.isDepthReversed=false; scaler.preExposure=1
    scaler.encode(commandBuffer:command)
    lastGeneration=frame.generation; lastIndex=frame.index; lastTime=now; passes += 1
    return textures[5]
  }
  deinit { for texture in textures { residency.removeAllocation(texture) }; residency.commit() }
}
