import AVFAudio
import AudioToolbox
import Foundation

protocol GameAudioPlayer: AnyObject {
  var duration: TimeInterval { get }
  var currentTime: TimeInterval { get set }
  var isPlaying: Bool { get }
  var volume: Float { get set }
  var pan: Float { get set }
  var numberOfLoops: Int { get set }
  var isMeteringEnabled: Bool { get set }
  func prepareToPlay() -> Bool
  func play() -> Bool
  func pause()
  func stop()
  func updateMeters()
  func averagePower(forChannel channel: Int) -> Float
}

extension AVAudioPlayer: GameAudioPlayer {}

// Immediate channel messages, not Standard MIDI Files. Validate the whole buffer
// before any command reaches CoreAudio (Zeebo Developer Guide 9.5.3).
struct MIDIMessage: Equatable {
  let status: UInt8
  let first: UInt8
  let second: UInt8
  static func decode(_ bytes: Data) -> [MIDIMessage]? {
    guard !bytes.isEmpty, bytes.count <= 96 else { return nil }
    let bytes = Array(bytes)
    var result: [MIDIMessage] = []
    var position = 0
    while position < bytes.count {
      let status = bytes[position]
      guard (0x80...0xef).contains(status), result.count < 32 else { return nil }
      let length = (status & 0xe0) == 0xc0 ? 2 : 3
      guard position + length <= bytes.count,
        bytes[(position + 1)..<(position + length)].allSatisfy({ $0 < 0x80 }) else { return nil }
      result.append(MIDIMessage(status: status, first: bytes[position + 1],
        second: length == 3 ? bytes[position + 2] : 0))
      position += length
    }
    return result
  }
  func send(to instrument: AVAudioUnitMIDIInstrument) {
    if (status & 0xe0) == 0xc0 {
      instrument.sendMIDIEvent(status, data1: first)
    } else {
      instrument.sendMIDIEvent(status, data1: first, data2: second)
    }
  }
}

// Keep the synth alive after a buffer completes: notes continue until Note Off.
// There is no guest code on the audio callback thread.
final class MIDIMessageOutput {
  private let engine = AVAudioEngine()
  private let instrument = AVAudioUnitMIDIInstrument(audioComponentDescription:
    AudioComponentDescription(componentType: kAudioUnitType_MusicDevice,
      componentSubType: kAudioUnitSubType_DLSSynth, componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0, componentFlagsMask: 0))
  private final class Meter: @unchecked Sendable {
    let lock = NSLock()
    var enabled = false
    var power: Float = -160
    func receive(_ buffer: AVAudioPCMBuffer) {
      lock.lock()
      defer { lock.unlock() }
      guard enabled else { return }
      guard let samples = buffer.floatChannelData, buffer.frameLength > 0 else { return }
      var energy: Float = 0
      for i in 0..<Int(buffer.frameLength) { energy += samples[0][i] * samples[0][i] }
      power = 10 * log10(max(1e-16, energy / Float(buffer.frameLength)))
    }
  }
  private let meter = Meter()
  init() {
    engine.attach(instrument)
    engine.connect(instrument, to: engine.mainMixerNode, format: nil)
    let meter = self.meter
    engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in meter.receive(buffer) }
  }
  var volume: Float {
    get { engine.mainMixerNode.outputVolume }
    set { engine.mainMixerNode.outputVolume = newValue }
  }
  var pan: Float {
    get { engine.mainMixerNode.pan }
    set { engine.mainMixerNode.pan = newValue }
  }
  var power: Float {
    meter.lock.lock(); defer { meter.lock.unlock() }
    return meter.power
  }
  var isMeteringEnabled: Bool {
    get { meter.lock.lock(); defer { meter.lock.unlock() }; return meter.enabled }
    set { meter.lock.lock(); meter.enabled = newValue; meter.lock.unlock() }
  }
  func send(_ messages: [MIDIMessage]) throws {
    if !engine.isRunning { engine.prepare(); try engine.start() }
    for message in messages { message.send(to: instrument) }
  }
  func stop() {
    for channel in UInt8(0)..<16 { instrument.sendController(120, withValue: 0, onChannel: channel) }
  }
  deinit {
    stop()
    engine.stop()
    engine.mainMixerNode.removeTap(onBus: 0)
  }
}

// The MIDI event parser and General MIDI instrument are Apple's system components.
// This adapter owns only scheduling, playback state and the BREW-facing controls.
final class MIDIAudioPlayer: GameAudioPlayer {
  private let engine: AVAudioEngine
  private let sequencer: AVAudioSequencer
  private let instrument: AVAudioUnitMIDIInstrument
  let duration: TimeInterval
  private var active = false
  private var completedLoops = 0
  private var terminalPosition: TimeInterval?
  var numberOfLoops = 0
  private let meter = Meter()
  private final class Meter: @unchecked Sendable {
    let lock = NSLock()
    var enabled = false
    var power: Float = -160
    func receive(_ buffer: AVAudioPCMBuffer) {
      lock.lock()
      defer { lock.unlock() }
      guard enabled, buffer.frameLength > 0, let samples = buffer.floatChannelData else { return }
      var squares: Float = 0
      for index in 0..<Int(buffer.frameLength) { squares += samples[0][index] * samples[0][index] }
      power = 10 * log10(max(1e-16, squares / Float(buffer.frameLength)))
    }
  }
  init(data: Data) throws {
    let engine = AVAudioEngine()
    let instrument = AVAudioUnitMIDIInstrument(
      audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_MusicDevice, componentSubType: kAudioUnitSubType_DLSSynth,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0,
        componentFlagsMask: 0))
    engine.attach(instrument)
    engine.connect(instrument, to: engine.mainMixerNode, format: nil)
    let sequencer = AVAudioSequencer(audioEngine: engine)
    try sequencer.load(from: data, options: [])
    let duration = sequencer.tracks.map(\.lengthInSeconds).max() ?? 0
    guard duration.isFinite && duration > 0 else {
      throw EmulationError.invalid("MIDI without finite playback duration")
    }
    for track in sequencer.tracks { track.destinationAudioUnit = instrument }
    self.engine = engine
    self.instrument = instrument
    self.sequencer = sequencer
    self.duration = duration
    let meter = self.meter
    engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
      meter.receive(buffer)
    }
  }
  deinit {
    sequencer.stop()
    engine.stop()
    engine.mainMixerNode.removeTap(onBus: 0)
  }
  var volume: Float {
    get { engine.mainMixerNode.outputVolume }
    set { engine.mainMixerNode.outputVolume = newValue }
  }
  var pan: Float {
    get { engine.mainMixerNode.pan }
    set { engine.mainMixerNode.pan = newValue }
  }
  var tempo: Float {
    get { sequencer.rate }
    set { sequencer.rate = newValue }
  }
  func send(_ messages: [MIDIMessage]) {
    for message in messages { message.send(to: instrument) }
  }
  var currentTime: TimeInterval {
    get { terminalPosition ?? min(duration, sequencer.currentPositionInSeconds) }
    set {
      terminalPosition = nil
      sequencer.currentPositionInSeconds = min(duration, max(0, newValue))
    }
  }
  var isPlaying: Bool {
    guard active else { return false }
    guard sequencer.currentPositionInSeconds >= duration else { return sequencer.isPlaying }
    // Repeat the complete sequence, including its tempo map. The guest queue polls
    // completion; restarting here can leave up to one poll interval between repeats.
    if numberOfLoops < 0 || completedLoops < numberOfLoops {
      sequencer.stop()
      silenceNotes()
      sequencer.currentPositionInSeconds = 0
      completedLoops += 1
      do {
        try sequencer.start()
        return true
      } catch {
        stop()
        return false
      }
    }
    stop()
    terminalPosition = duration
    return false
  }
  func prepareToPlay() -> Bool {
    if !engine.isRunning { engine.prepare() }
    sequencer.prepareToPlay()
    return true
  }
  func play() -> Bool {
    if terminalPosition != nil { currentTime = 0 }
    do {
      if !engine.isRunning { try engine.start() }
      try sequencer.start()
      active = true
      return true
    } catch {
      stop()
      return false
    }
  }
  private func silenceNotes() {
    for channel in UInt8(0)..<16 {
      instrument.sendController(120, withValue: 0, onChannel: channel)
      instrument.sendController(123, withValue: 0, onChannel: channel)
    }
  }
  func pause() {
    sequencer.stop()
    silenceNotes()
    // Keep the CoreAudio output unit running silently between pause/resume calls.
    // Removing/restarting its render callback while WAV output is active can race
    // the shared HAL I/O thread. Only destroy the output unit with this player.
    active = false
  }
  func stop() {
    pause()
    completedLoops = 0
  }
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
  func updateMeters() {}
  func averagePower(forChannel channel: Int) -> Float {
    meter.lock.lock()
    defer { meter.lock.unlock() }
    return channel == 0 ? meter.power : -160
  }
}
