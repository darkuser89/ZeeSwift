import AVFAudio
import Foundation

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
  private var active = false
  private var ended = false
  var numberOfLoops = 0
  var isMeteringEnabled = false
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
  func averagePower(forChannel channel: Int) -> Float { -160 }
}
