import AVFAudio
import Foundation

// AEEShell.h permits device-specific system tones. These short, locally generated
// PCM tones are a native fallback, not recordings of the Zeebo firmware sounds.
final class BREWShellBeep {
  private var player: (any GameAudioPlayer)?
  private let makePlayer: (Data) throws -> any GameAudioPlayer

  init(makePlayer: @escaping (Data) throws -> any GameAudioPlayer = { try AVAudioPlayer(data: $0) }) {
    self.makePlayer = makePlayer
  }
  deinit { stop() }
  func stop() { player?.stop(); player = nil }

  func play(type: UInt32, loud: Bool, duration: UInt16 = 150) -> Bool {
    if type == 0 { stop(); return true } // BEEP_OFF
    // Vibration-only tones require a device policy; do not report them as played.
    guard let data = Self.wave(type: type, duration: duration) else { return false }
    do {
      let next = try makePlayer(data)
      next.volume = loud ? 0.6 : 0.25
      next.numberOfLoops = duration == 0 ? -1 : 0
      guard next.prepareToPlay() else { return false }
      stop()
      guard next.play() else { next.stop(); return false }
      player = next
      return true
    } catch { return false }
  }

  static func wave(type: UInt32, duration: UInt16 = 150) -> Data? {
    guard (1...4).contains(type) else { return nil }
    let frequency = [880.0, 660.0, 1046.5, 330.0][Int(type - 1)]
    let rate = 22050
    // A two-second period contains whole cycles of each fallback frequency.
    let frames = duration == 0 ? rate * 2 : max(1, Int((Double(rate) * Double(duration) / 1000).rounded()))
    var data = Data("RIFF".utf8)
    func word(_ value: UInt32, bytes: Int) {
      for shift in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
    }
    word(UInt32(36 + frames * 2), bytes: 4)
    data.append(contentsOf: "WAVEfmt ".utf8)
    word(16, bytes: 4); word(1, bytes: 2); word(1, bytes: 2)
    word(UInt32(rate), bytes: 4); word(UInt32(rate * 2), bytes: 4)
    word(2, bytes: 2); word(16, bytes: 2)
    data.append(contentsOf: "data".utf8); word(UInt32(frames * 2), bytes: 4)
    for index in 0..<frames {
      // Fade both ends to avoid clicks when starting/stopping a short tone.
      let envelope = duration == 0 ? 1 : min(1.0, Double(min(index, frames - 1 - index)) / 220.0)
      let sample = Int16((sin(2 * .pi * frequency * Double(index) / Double(rate)) * envelope * 16000).rounded())
      word(UInt32(UInt16(bitPattern: sample)), bytes: 2)
    }
    return data
  }
}

final class BREWSound {
  var references: UInt32 = 1
  var callback: UInt32 = 0
  var context: UInt32 = 0
}

struct BREWSoundNotification {
  let handle: UInt32
  let sound: BREWSound
  let status: UInt32
}

extension BREWRuntime {
  func queueSoundStatus(_ handle: UInt32, _ sound: BREWSound, _ status: UInt32) {
    if sound.callback != 0 {
      soundNotifications.append(BREWSoundNotification(handle: handle, sound: sound, status: status))
    }
  }

  func finishSoundTone() {
    soundTone.stop()
    timers.removeAll { $0.callback == 0xf01bff00 }
    if let owner = soundToneOwner { queueSoundStatus(owner.handle, owner.sound, 2) }
    soundToneOwner = nil; soundToneDeadline = nil
  }

  func pumpSound() throws {
    if let deadline = soundToneDeadline, deadline <= timerMilliseconds { finishSoundTone() }
    let notifications = soundNotifications
    soundNotifications.removeAll(keepingCapacity: true)
    for event in notifications where sounds[event.handle] === event.sound && event.sound.callback != 0 {
      _ = try invokeFormCallback(event.sound.callback, [event.sound.context, 0, event.status, 0])
    }
  }

  func createSound() throws -> UInt32 {
    let handle = try allocate(4)
    guard handle != 0 else { return 0 }
    let table: UInt32 = hleAddress(0x20600)
    for offset in stride(from: UInt32(0), through: 0x38, by: 4) {
      try memory.write32(table + offset, 0xf01b_0000 + offset)
    }
    try memory.write32(handle, table)
    sounds[handle] = BREWSound()
    return handle
  }

  var vibrationRemainingMilliseconds: UInt16 {
    let now = timerMilliseconds
    guard let deadline = vibrationDeadline, deadline > now else { return 0 }
    return UInt16(clamping: deadline - now)
  }

  func stopSoundVibration() {
    vibrationDeadline = nil
    vibrationOwner = nil
    onVibration?(0)
  }

  func dispatchSound(_ offset: UInt32) throws {
    if offset == 0xff00 { try pumpSound(); cpu.r[0] = 0; return }
    let handle = cpu.r[0]
    guard let sound = sounds[handle] else { throw EmulationError.invalid("ISound object " + handle.hex) }
    switch offset {
    case 0:
      sound.references += 1
      cpu.r[0] = sound.references
    case 4:
      sound.references -= 1
      if sound.references == 0 {
        if vibrationOwner == handle { stopSoundVibration() }
        sounds.removeValue(forKey: handle)
        try free(handle)
      }
      cpu.r[0] = sound.references
    case 8:
      sound.callback = cpu.r[1]
      sound.context = cpu.r[2]
    case 0x18:
      // ARM AEESoundToneData is passed by value: int8 tone, padding, uint16 ms.
      // Do not read r1 as a pointer, or interpret the uninitialized padding byte.
      let tone = UInt32(UInt8(truncatingIfNeeded: cpu.r[1]))
      let duration = UInt16(truncatingIfNeeded: cpu.r[1] >> 16)
      guard (100...103).contains(tone) else {
        queueSoundStatus(handle, sound, 3); cpu.r[0] = 0; return
      }
      finishSoundTone()
      let played = soundTone.play(type: tone - 99, loud: false, duration: duration)
      if played {
        soundToneOwner = (handle, sound)
        if duration != 0 {
          soundToneDeadline = timerMilliseconds + UInt64(duration)
          scheduleCallback(delay: UInt32(duration), callback: 0xf01bff00, context: 0)
        }
      }
      queueSoundStatus(handle, sound, played ? 1 : 3)
      log.append("ISound.PlayTone \(tone), \(duration) ms: \(played ? "accepted" : "unavailable")")
      cpu.r[0] = 0 // void method; status is delivered through RegisterNotify.
    case 0x24:
      finishSoundTone(); cpu.r[0] = 0
    case 0x28:
      // The duration is uint16 milliseconds; Vibrate and StopVibrate have no callbacks.
      let duration = UInt16(truncatingIfNeeded: cpu.r[1])
      vibrationOwner = duration == 0 ? nil : handle
      vibrationDeadline = duration == 0 ? nil : timerMilliseconds + UInt64(duration)
      onVibration?(duration)
    case 0x2c:
      stopSoundVibration()
    default: throw EmulationError.hle("ISound+" + offset.hex, cpu.r[14])
    }
  }
}
