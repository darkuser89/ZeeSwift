import AVFAudio
import Foundation

// Some BREW games use an in-memory WAV as a DMA-style buffer: SetMediaData is
// called once, then the guest rewrites the PCM payload while it is playing.
// AVAudioPlayer snapshots Data at initialization, so it would keep playing the
// initial silence. This source node renders from a host snapshot that the guest
// worker refreshes; the audio callback never reads guest memory directly.
final class MutableWAVPlayer: GameAudioPlayer {
  private struct Wave {
    let channels: Int
    let sampleRate: Int
    let bits: Int
    let payload: Data
  }
  private final class State: @unchecked Sendable {
    let lock = NSLock()
    var payload: Data
    var position = 0
    var active = false
    var loops = 0
    var completedLoops = 0
    var metering = false
    var power: Float = -160
    init(payload: Data) { self.payload = payload }
  }

  private let engine = AVAudioEngine()
  private let node: AVAudioSourceNode
  private let state: State
  private let channels: Int
  private let sampleRate: Int
  private let bits: Int
  private let bytesPerFrame: Int
  let duration: TimeInterval

  private static func parse(_ data: Data) throws -> Wave {
    guard data.count >= 12, data.prefix(4) == Data("RIFF".utf8),
      data.subdata(in: 8..<12) == Data("WAVE".utf8)
    else { throw EmulationError.invalid("WAV header") }
    let riffEnd = Int(try data.u32(4)) + 8
    guard riffEnd >= 12, riffEnd <= data.count else {
      throw EmulationError.invalid("WAV RIFF size")
    }
    var offset = 12
    var format: (channels: Int, sampleRate: Int, bits: Int, blockAlign: Int)?
    var payload: Data?
    while offset + 8 <= riffEnd {
      let name = data.subdata(in: offset..<offset + 4)
      let count = Int(try data.u32(offset + 4))
      let start = offset + 8
      guard count >= 0, start <= riffEnd, count <= riffEnd - start else {
        throw EmulationError.invalid("WAV chunk")
      }
      if name == Data("fmt ".utf8) {
        guard count >= 16, try data.u16(start) == 1 else {
          throw EmulationError.unsupported("mutable non-PCM WAV")
        }
        format = (Int(try data.u16(start + 2)), Int(try data.u32(start + 4)),
          Int(try data.u16(start + 14)), Int(try data.u16(start + 12)))
      } else if name == Data("data".utf8) {
        payload = data.subdata(in: start..<start + count)
        if format != nil { break }
      }
      offset = start + count + (count & 1)
    }
    guard let format, let payload, (1...2).contains(format.channels),
      (1000...192_000).contains(format.sampleRate), format.bits == 8 || format.bits == 16,
      format.blockAlign == format.channels * (format.bits / 8),
      !payload.isEmpty, payload.count % format.blockAlign == 0
    else { throw EmulationError.unsupported("mutable WAV format") }
    return Wave(channels: format.channels, sampleRate: format.sampleRate,
      bits: format.bits, payload: payload)
  }

  init(wave data: Data) throws {
    let wave = try Self.parse(data)
    channels = wave.channels
    sampleRate = wave.sampleRate
    bits = wave.bits
    bytesPerFrame = wave.channels * (wave.bits / 8)
    duration = Double(wave.payload.count / bytesPerFrame) / Double(wave.sampleRate)
    let state = State(payload: wave.payload)
    self.state = state
    guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(wave.sampleRate),
      channels: AVAudioChannelCount(wave.channels)), !format.isInterleaved else {
      throw EmulationError.unsupported("mutable WAV output format")
    }
    let channels = wave.channels, bits = wave.bits
    let bytesPerFrame = wave.channels * (wave.bits / 8)
    node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
      let outputs = UnsafeMutableAudioBufferListPointer(audioBufferList)
      for output in outputs {
        if let pointer = output.mData { pointer.initializeMemory(as: UInt8.self, repeating: 0,
          count: Int(output.mDataByteSize)) }
      }
      state.lock.lock()
      defer { state.lock.unlock() }
      guard state.active else { return 0 }
      var energy: Float = 0
      var rendered = 0
      for frame in 0..<Int(frameCount) {
        let totalFrames = state.payload.count / bytesPerFrame
        if state.position >= totalFrames {
          if state.loops == -1 || state.completedLoops < state.loops {
            state.completedLoops += 1
            state.position = 0
          } else {
            state.active = false
            break
          }
        }
        for channel in 0..<channels {
          let index = state.position * bytesPerFrame + channel * (bits / 8)
          let sample: Float
          if bits == 8 {
            sample = Float(Int(state.payload[index]) - 128) / 128
          } else {
            let word = UInt16(state.payload[index]) | UInt16(state.payload[index + 1]) << 8
            sample = Float(Int16(bitPattern: word)) / 32768
          }
          if channel < outputs.count, let address = outputs[channel].mData {
            address.assumingMemoryBound(to: Float.self)[frame] = sample
          }
          if channel == 0 { energy += sample * sample }
        }
        state.position += 1
        rendered += 1
      }
      if state.metering, rendered > 0 {
        state.power = 10 * log10(max(1e-16, energy / Float(rendered)))
      }
      return 0
    }
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
  }

  deinit { stop() }
  func update(wave data: Data) throws {
    let wave = try Self.parse(data)
    guard wave.channels == channels, wave.sampleRate == sampleRate, wave.bits == bits,
      wave.payload.count == state.payload.count else {
      throw EmulationError.invalid("mutable WAV layout changed")
    }
    state.lock.lock()
    state.payload = wave.payload
    state.lock.unlock()
  }
  var currentTime: TimeInterval {
    get {
      state.lock.lock(); defer { state.lock.unlock() }
      return Double(state.position) / Double(sampleRate)
    }
    set {
      state.lock.lock(); defer { state.lock.unlock() }
      state.position = min(state.payload.count / bytesPerFrame,
        max(0, Int(newValue * Double(sampleRate))))
      state.completedLoops = 0
    }
  }
  var isPlaying: Bool {
    state.lock.lock(); defer { state.lock.unlock() }
    return state.active && engine.isRunning
  }
  var volume: Float {
    get { engine.mainMixerNode.outputVolume }
    set { engine.mainMixerNode.outputVolume = newValue }
  }
  var pan: Float {
    get { engine.mainMixerNode.pan }
    set { engine.mainMixerNode.pan = newValue }
  }
  var numberOfLoops: Int {
    get { state.lock.lock(); defer { state.lock.unlock() }; return state.loops }
    set { state.lock.lock(); state.loops = newValue; state.lock.unlock() }
  }
  var isMeteringEnabled: Bool {
    get { state.lock.lock(); defer { state.lock.unlock() }; return state.metering }
    set { state.lock.lock(); state.metering = newValue; state.lock.unlock() }
  }
  func prepareToPlay() -> Bool {
    do {
      if !engine.isRunning { engine.prepare(); try engine.start() }
      return true
    } catch { return false }
  }
  func play() -> Bool {
    guard prepareToPlay() else { return false }
    state.lock.lock()
    if state.position >= state.payload.count / bytesPerFrame {
      state.position = 0
      state.completedLoops = 0
    }
    state.active = true
    state.lock.unlock()
    return true
  }
  func pause() {
    state.lock.lock(); state.active = false; state.lock.unlock()
    engine.pause()
  }
  func stop() {
    state.lock.lock()
    state.active = false
    state.position = 0
    state.completedLoops = 0
    state.lock.unlock()
    engine.stop()
  }
  func updateMeters() {}
  func averagePower(forChannel channel: Int) -> Float {
    state.lock.lock(); defer { state.lock.unlock() }
    return channel < channels ? state.power : -160
  }
}

// Own conversion of the original BREW AEEMediaWaveSpec PCM layout.
struct PCMStreamFormat {
  let channels: Int
  let sampleRate: Int
  let bits: Int
  let unsigned: Bool
  var bytesPerFrame: Int { channels * (bits / 8) }

  init(spec: Data) throws {
    guard spec.count >= 32, try spec.u16(0) >= 32,
      [UInt32(0x0100_5511), 0x0104_0046].contains(try spec.u32(4))
    else { throw EmulationError.unsupported("PCM specification") }
    channels = Int(try spec.u16(8))
    sampleRate = Int(try spec.u32(12))
    bits = Int(try spec.u16(16))
    // ARM ABI packs this one-bit unsigned field immediately after wBitsPerSample.
    unsigned = spec[18] & 1 != 0
    guard (1...2).contains(channels), (1000...192000).contains(sampleRate),
      bits == 8 || bits == 16
    else { throw EmulationError.unsupported("PCM channels/sample rate/bit depth") }
  }

  func decode(_ data: Data) throws -> AVAudioPCMBuffer {
    guard !data.isEmpty, data.count % bytesPerFrame == 0,
      let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate),
        channels: AVAudioChannelCount(channels)),
      let buffer = AVAudioPCMBuffer(pcmFormat: format,
        frameCapacity: AVAudioFrameCount(data.count / bytesPerFrame)),
      let output = buffer.floatChannelData
    else { throw EmulationError.invalid("PCM buffer size") }
    buffer.frameLength = buffer.frameCapacity
    data.withUnsafeBytes { raw in
      let bytes = raw.bindMemory(to: UInt8.self)
      for frame in 0..<Int(buffer.frameLength) {
        for channel in 0..<channels {
          let index = (frame * channels + channel) * (bits / 8)
          let value: Int
          if bits == 8 {
            value = unsigned ? Int(bytes[index]) - 128 : Int(Int8(bitPattern: bytes[index]))
          } else {
            let word = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            value = unsigned ? Int(word) - 32768 : Int(Int16(bitPattern: word))
          }
          output[channel][frame] = Float(value) / (bits == 8 ? 128 : 32768)
        }
      }
    }
    return buffer
  }
}

// A bounded native streaming queue. Only its completion counters cross threads;
// source callbacks, guest memory and CPU execution stay on the emulation worker.
final class PCMStreamPlayer: GameAudioPlayer {
  let format: PCMStreamFormat
  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()
  private let completion = Completion()
  private let meter = Meter()
  private var active = false
  private var ended = false
  var numberOfLoops = 0
  var volume: Float = 1 { didSet { node.volume = volume } }
  var pan: Float = 0 { didSet { node.pan = pan } }
  var duration: TimeInterval { ended ? Double(completion.total) / Double(format.sampleRate) : 0 }
  var currentTime: TimeInterval {
    get { Double(completion.played) / Double(format.sampleRate) }
    set { /* ISource has no seek operation; the BREW adapter rejects seeks. */ }
  }
  var pendingFrames: Int { completion.pending }
  var queueDiagnostics: [String: Double] { completion.diagnostics }
  var isPlaying: Bool { active && !(ended && completion.drained) }

  private final class Meter: @unchecked Sendable {
    let lock = NSLock()
    var enabled = false
    var power: Float = -160
    func receive(_ buffer: AVAudioPCMBuffer) {
      lock.lock()
      defer { lock.unlock() }
      guard enabled, buffer.frameLength > 0, let samples = buffer.floatChannelData else { return }
      var squares: Float = 0
      for index in 0..<Int(buffer.frameLength) {
        squares += samples[0][index] * samples[0][index]
      }
      power = 10 * log10(max(1e-16, squares / Float(buffer.frameLength)))
    }
  }

  private final class Completion: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var queued = 0
    private var consumed = 0
    private var presented = 0
    private var presentations: [(frames: Int, deadline: Double)] = []
    private var running = false
    private var sourceEnded = false
    private var emptyEvents = 0
    private var emptySince: Double?
    private var emptySeconds = 0.0
    var diagnostics: [String: Double] {
      lock.lock(); defer { lock.unlock() }
      let ongoing = emptySince.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
      return ["renderedFrames": Double(consumed), "pendingFrames": Double(queued),
        "emptyEvents": Double(emptyEvents), "emptySeconds": emptySeconds + ongoing]
    }
    func setRunning(_ value: Bool) {
      lock.lock(); defer { lock.unlock() }
      running = value
      if !value { closeEmptyInterval() }
    }
    func endSource() {
      lock.lock(); defer { lock.unlock() }
      sourceEnded = true; closeEmptyInterval()
    }
    private func closeEmptyInterval() {
      if let since = emptySince {
        emptySeconds += ProcessInfo.processInfo.systemUptime - since
        emptySince = nil
      }
    }
    var pending: Int { lock.lock(); defer { lock.unlock() }; return queued }
    private func retirePresentations() {
      let now = ProcessInfo.processInfo.systemUptime
      while let first = presentations.first, first.deadline <= now {
        presented += first.frames; presentations.removeFirst()
      }
    }
    var played: Int {
      lock.lock(); defer { lock.unlock() }
      retirePresentations(); return presented
    }
    var drained: Bool {
      lock.lock(); defer { lock.unlock() }
      retirePresentations(); return queued == 0 && presentations.isEmpty
    }
    var total: Int { lock.lock(); defer { lock.unlock() }; return queued + consumed }
    func enqueue(_ count: Int) -> UInt64 {
      lock.lock(); defer { lock.unlock() }
      queued += count
      closeEmptyInterval()
      return generation
    }
    func finish(_ count: Int, generation expected: UInt64, latency: Double) {
      lock.lock(); defer { lock.unlock() }
      guard generation == expected else { return }
      queued -= count; consumed += count
      retirePresentations()
      presentations.append((count, ProcessInfo.processInfo.systemUptime + latency))
      if queued == 0 && running && !sourceEnded {
        emptyEvents += 1; emptySince = ProcessInfo.processInfo.systemUptime
      }
    }
    func reset() {
      lock.lock(); defer { lock.unlock() }
      generation &+= 1; queued = 0; consumed = 0
      presented = 0; presentations.removeAll(keepingCapacity: true)
      running = false; sourceEnded = false; emptyEvents = 0
      emptySince = nil; emptySeconds = 0
    }
  }

  init(format: PCMStreamFormat) {
    self.format = format
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode,
      format: AVAudioFormat(standardFormatWithSampleRate: Double(format.sampleRate),
        channels: AVAudioChannelCount(format.channels)))
  }
  deinit { stop() }
  func prepareToPlay() -> Bool {
    do { if !engine.isRunning { engine.prepare(); try engine.start() }; return true }
    catch { return false }
  }
  func play() -> Bool {
    guard prepareToPlay() else { return false }
    node.play(); active = true; completion.setRunning(true)
    return true
  }
  func pause() { completion.setRunning(false); node.pause(); active = false }
  func stop() {
    active = false; ended = false
    completion.reset()
    node.stop(); engine.stop()
  }
  func enqueue(_ data: Data) throws {
    let buffer = try format.decode(data)
    // Meter the exact floating-point frames submitted to AVAudioPlayerNode. This
    // keeps diagnostics off CoreAudio's real-time callback while the independent
    // render-tap test continues to verify that scheduled frames reach the engine.
    meter.receive(buffer)
    let count = Int(buffer.frameLength)
    let generation = completion.enqueue(count)
    // Refill when the player renders the source, before device presentation.
    // Waiting for .dataPlayedBack starves small BREW streaming queues. Keep
    // downstream latency separately so EOF does not cut off the final samples.
    let latency = max(0, node.outputPresentationLatency)
    node.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { [completion] _ in
      completion.finish(count, generation: generation, latency: latency)
    }
  }
  func finishSource() { completion.endSource(); ended = true }
  func updateMeters() {}
  var isMeteringEnabled: Bool {
    get {
      meter.lock.lock()
      defer { meter.lock.unlock() }
      return meter.enabled
    }
    set {
      meter.lock.lock()
      meter.enabled = newValue
      meter.lock.unlock()
    }
  }
  func averagePower(forChannel channel: Int) -> Float {
    meter.lock.lock()
    defer { meter.lock.unlock() }
    guard channel == 0, volume > 0 else { return -160 }
    return max(-160, meter.power + 20 * log10(volume))
  }
}
