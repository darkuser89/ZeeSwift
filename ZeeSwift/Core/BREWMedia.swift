import AVFAudio
import Foundation

// Original BREW IMedia ABI, implemented with system WAV, MP3 and MIDI audio backends.
final class BREWMedia {
  // Type sniffing only. Apple's decoder validates the complete compressed stream.
  static func hasMP3Prefix(_ bytes: Data) -> Bool {
    if bytes.count >= 10, bytes.starts(with: [0x49, 0x44, 0x33]) {
      return (2...4).contains(bytes[3]) && bytes[4] != 0xff
        && bytes[6..<10].allSatisfy { $0 < 0x80 }
    }
    guard bytes.count >= 4 else { return false }
    let header = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
      | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    return header & 0xffe0_0000 == 0xffe0_0000 && (header >> 19) & 3 != 1
      && (header >> 17) & 3 == 1 && (header >> 12) & 15 != 15
      && (header >> 10) & 3 != 3 && header & 3 != 2
  }
  static func hasVorbisPrefix(_ bytes: Data) -> Bool {
    guard bytes.count >= 28, bytes.starts(with: Data("OggS".utf8)),
      bytes[4] == 0, bytes[5] & 2 != 0, bytes[26] > 0, bytes[27] >= 7
    else { return false }
    let packet = 27 + Int(bytes[26])
    guard packet + 7 <= bytes.count else { return false }
    return bytes.subdata(in: packet..<packet + 7) == Data([1] + Array("vorbis".utf8))
  }
  let identity = UUID()
  let classID: UInt32
  var references: UInt32 = 1
  var state: UInt32 = 1
  var callback: UInt32 = 0
  var context: UInt32 = 0
  var registration: UInt64 = 0
  var descriptor = Data()
  var player: (any GameAudioPlayer)?
  var midiMessages: [MIDIMessage]?
  var midiOutput: MIDIMessageOutput?
  var playbackOrder: UInt64 = 0
  var isMIDI: Bool { classID == 0x0100_5501 || classID == 0x0100_5505 }
  var pcmStream: BREWPCMStream?
  var tempo: UInt32 = 100
  var volume: UInt32 = 100
  var pan: UInt32 = 64
  var muted = false
  var repeatCount: UInt32 = 1
  var channelShared = false
  init(classID: UInt32) { self.classID = classID }
  deinit { player?.stop() }
  var milliseconds: UInt32 { UInt32(clamping: Int64((player?.currentTime ?? 0) * 1000)) }
  var duration: UInt32 { UInt32(clamping: Int64((player?.duration ?? 0) * 1000)) }
  func configure() {
    midiOutput?.volume = muted ? 0 : Float(volume) / 100
    midiOutput?.pan = (Float(pan) - 64) / 64
    player?.volume = muted ? 0 : Float(volume) / 100
    player?.pan = (Float(pan) - 64) / 64
    player?.numberOfLoops = repeatCount == 0 ? -1 : Int(repeatCount - 1)
    (player as? MIDIAudioPlayer)?.tempo = Float(tempo) / 100
  }
}

struct BREWMediaNotification {
  let handle: UInt32
  let identity: UUID
  let registration: UInt64
  let command: UInt32
  let status: UInt32
  let value: UInt32
}

extension BREWRuntime {
  func createMediaUtility() throws -> UInt32 {
    let handle = try allocate(4)
    guard handle != 0 else { return 0 }
    let table: UInt32 = hleAddress(0x20400)
    try memory.write32(handle, table)
    for offset in stride(from: UInt32(0), through: 0x14, by: 4) {
      try memory.write32(table + offset, 0xf019_0000 + offset)
    }
    mediaUtilities[handle] = 1
    return handle
  }
  func dispatchMediaUtility(_ offset: UInt32) throws {
    let handle = cpu.r[0], p1 = cpu.r[1], output = cpu.r[2]
    guard let references = mediaUtilities[handle] else {
      throw EmulationError.invalid("Released IMediaUtil object")
    }
    cpu.r[0] = 0
    switch offset {
    case 0:
      mediaUtilities[handle] = references + 1
      cpu.r[0] = references + 1
    case 4:
      cpu.r[0] = references - 1
      if references == 1 {
        mediaUtilities.removeValue(forKey: handle)
        try free(handle)
      } else { mediaUtilities[handle] = references - 1 }
    case 8:
      guard output != 0 else { cpu.r[0] = 14; return }
      let matches = p1 == 0x0100_550d || p1 == 0x0100_0001
      try memory.write32(output, matches ? handle : 0)
      if matches { mediaUtilities[handle] = references + 1 } else { cpu.r[0] = 3 }
    case 0x0c:
      guard output != 0 else { cpu.r[0] = 14; return }
      _ = try memory.region(output, 4)
      try memory.write32(output, 0)
      guard p1 != 0 else { cpu.r[0] = 14; return }
      let type = try memory.read32(p1)
      let source = try memory.read32(p1 + 4)
      let count = try memory.read32(p1 + 8)
      guard source != 0 else { cpu.r[0] = 14; return }
      var classID: UInt32 = 0
      var bytes = Data()
      if type == 0 {
        let filename = try memory.string(source)
        // Original CreateMedia contract checks a registered extension first.
        switch (filename as NSString).pathExtension.lowercased() {
        case "mp3": classID = 0x0100_5502
        case "mid", "midi": classID = 0x0100_5501
        case "wav": classID = 0x0100_550a
        default:
          let path = try filePath(filename)
          guard let data = try fileContents(path) else { cpu.r[0] = 1; return }
          bytes = data
        }
      } else if type == 1 {
        guard count > 0 && count <= 32 * 1024 * 1024 else { cpu.r[0] = 14; return }
        bytes = try memory.data(source, count: Int(count))
      } else { cpu.r[0] = 20; return } // Streaming/peek sources are not implemented.
      if classID == 0 {
        if bytes.starts(with: Data("MThd".utf8)) { classID = 0x0100_5501 }
        else if BREWMedia.hasMP3Prefix(bytes) { classID = 0x0100_5502 }
        else if bytes.count >= 12 && bytes.prefix(4) == Data("RIFF".utf8)
          && bytes.subdata(in: 8..<12) == Data("WAVE".utf8) { classID = 0x0100_550a }
        else { cpu.r[0] = bytes.count < 12 ? 35 : 20; return }
      }
      let created = try createMedia(classID: classID)
      guard created != 0 else { cpu.r[0] = 0x902; return }
      var transferred = false
      defer {
        if !transferred {
          media.removeValue(forKey: created)
          try? free(created)
        }
      }
      let status = try setMediaData(media[created]!, descriptor: p1)
      guard status == 0 else {
        cpu.r[0] = status == 14 || status == 20 ? 0x901 : status
        return
      }
      try memory.write32(output, created)
      transferred = true
    case 0x10, 0x14: cpu.r[0] = 20 // EncodeMedia / CreateMediaEx
    default: throw EmulationError.hle("IMediaUtil+" + offset.hex, cpu.r[14])
    }
  }
  func createMedia(classID: UInt32) throws -> UInt32 {
    let handle = try allocate(16)
    guard handle != 0 else { return 0 }
    let table: UInt32 = hleAddress(0x17000)
    try memory.write32(handle, table)
    for offset in stride(from: UInt32(0), through: 0x34, by: 4) {
      try memory.write32(table + offset, 0xf011_0000 + offset)
    }
    media[handle] = BREWMedia(classID: classID)
    return handle
  }
  private func setMediaData(_ object: BREWMedia, descriptor pointer: UInt32) throws -> UInt32 {
    let descriptor = try memory.data(pointer, count: 12)
    let type = try memory.read32(pointer)
    let source = try memory.read32(pointer + 4)
    let count = try memory.read32(pointer + 8)
    if object.classID == 0x0100_5505 {
      guard type == 1 else { return 20 }
      guard source != 0, count > 0, count <= 96,
        let messages = MIDIMessage.decode(try memory.data(source, count: Int(count))) else { return 14 }
      object.midiOutput?.stop()
      object.midiMessages = messages
      object.descriptor = descriptor
      object.state = 2
      return 0
    }
    guard source != 0 else {
      return 14
    }
    let bytes: Data
    if type == 1 {
      guard count > 0 && count <= 32 * 1024 * 1024 else {
        return 14
      }
      bytes = try memory.data(source, count: Int(count))
    } else if type == 0 {
      let path = try filePath(memory.string(source))
      guard let file = try fileContents(path) else {
        return 1
      }
      bytes = file
    } else {
      return 20
    }
    let midi = object.classID == 0x0100_5501
    // Zeebo's original activitycenter module submits MP3 and Ogg files to the
    // PCM class as well as WAV. Detect those file payloads here; raw ISource PCM
    // still follows setPCMStream. Apple's decoder validates the complete file.
    let pcm = object.classID == 0x0100_5511 || object.classID == 0x0104_0046
    let mp3 = object.classID == 0x0100_5502 || (pcm && BREWMedia.hasMP3Prefix(bytes))
    let vorbis = pcm && BREWMedia.hasVorbisPrefix(bytes)
    let format = midi ? "MIDI" : (mp3 ? "MP3" : (vorbis ? "Vorbis" : "WAV"))
    guard
      midi
        ? bytes.starts(with: Data("MThd".utf8))
        : (mp3 ? BREWMedia.hasMP3Prefix(bytes) : vorbis ? BREWMedia.hasVorbisPrefix(bytes)
          : (bytes.count >= 12 && bytes.prefix(4) == Data("RIFF".utf8)
            && bytes.subdata(in: 8..<12) == Data("WAVE".utf8)))
    else {
      return 14
    }
    do {
      let player: any GameAudioPlayer =
        midi ? try MIDIAudioPlayer(data: bytes) : try AVAudioPlayer(data: bytes)
      try disposePCMStream(object)
      object.player?.stop()
      object.player = player
      object.descriptor = descriptor
      object.state = 2
      object.configure()
      log.append("IMedia \(format): \(bytes.count) Bytes, \(object.duration) ms")
    } catch {
      log.append(
        "IMedia \(format) could not be decoded: \(error.localizedDescription)")
      return 20
    }
    return 0
  }
  var hasPendingMedia: Bool {
    !mediaNotifications.isEmpty || media.values.contains { $0.state == 3 }
  }
  private func canPlayMedia(_ object: BREWMedia) -> Bool {
    !media.values.contains {
      $0 !== object && ($0.state == 3 || $0.state == 5)
        && ($0.isMIDI == object.isMIDI)
        && (!object.channelShared || !$0.channelShared)
    }
  }
  func notifyMedia(_ handle: UInt32, command: UInt32 = 4, status: UInt32, value: UInt32 = 0)
  {
    guard let object = media[handle], object.callback != 0 else { return }
    mediaNotifications.append(
      BREWMediaNotification(
        handle: handle, identity: object.identity,
        registration: object.registration, command: command, status: status, value: value))
  }
  func pumpMedia() throws {
    guard !appletClosed else { throw EmulationError.appletClosed }
    // Host audio threads never touch guest registers or memory. Deliver on the guest queue.
    try pumpPCMStreams()
    for (handle, object) in media where object.state == 3
      && (object.classID == 0x0100_5505 || object.player?.isPlaying == false) {
      object.state = 2
      notifyMedia(handle, status: 2)
    }
    let pending = mediaNotifications
    mediaNotifications.removeAll(keepingCapacity: true)
    for event in pending {
      guard let object = media[event.handle], object.identity == event.identity,
        object.registration == event.registration, object.callback != 0
      else { continue }
      let record = try allocate(28)
      guard record != 0 else {
        throw EmulationError.invalid("IMedia callback: guest memory exhausted")
      }
      defer { try? free(record) }
      for (index, value) in [
        object.classID, event.handle, event.command, 0, event.status,
        event.value, event.command == 6 ? 4 : 0,
      ].enumerated() {
        try memory.write32(record + UInt32(index * 4), value)
      }
      _ = try invoke(object.callback, [object.context, record], budget: 10_000_000)
    }
  }
  func dispatchMedia(_ offset: UInt32) throws {
    let handle = cpu.r[0]
    guard let object = media[handle] else {
      throw EmulationError.invalid("Released IMedia object")
    }
    let p1 = cpu.r[1]
    let p2 = cpu.r[2]
    let p3 = cpu.r[3]
    cpu.r[0] = 0
    switch offset {
    case 0:
      object.references += 1
      cpu.r[0] = object.references
    case 4:
      object.references -= 1
      cpu.r[0] = object.references
      if object.references == 0 {
        object.player?.stop()
        object.midiOutput?.stop()
        try disposePCMStream(object)
        media.removeValue(forKey: handle)
        mediaNotifications.removeAll { $0.handle == handle }
        try free(handle)
      }
    case 8:
      let matches = p1 == 0x0100_5500 || p1 == 0x0100_0001
      try memory.write32(p2, matches ? handle : 0)
      if matches { object.references += 1 } else { cpu.r[0] = 3 }
    case 0x0c:
      object.callback = p1
      object.context = p2
      object.registration &+= 1
    case 0x10:
      switch p1 {
      case 1:
        guard object.state <= 2 else {
          cpu.r[0] = 13
          return
        }
        guard p2 != 0 else {
          cpu.r[0] = 14
          return
        }
        cpu.r[0] = p3 == 0 ? try setMediaData(object, descriptor: p2)
          : try setPCMStream(object, handle: handle, descriptor: p2, count: p3)
      case 4:
        guard p2 <= 100 else {
          cpu.r[0] = 14
          return
        }
        object.volume = p2
        object.configure()
      case 5:
        object.muted = p2 != 0
        object.configure()
      case 6:
        guard object.classID == 0x0100_5501 else {
          cpu.r[0] = 20
          return
        }
        guard p2 > 0 && p2 <= 1000 else {
          cpu.r[0] = 14
          return
        }
        object.tempo = p2
        object.configure()
      case 8:
        guard p2 <= 128 else {
          cpu.r[0] = 14
          return
        }
        object.pan = p2
        object.configure()
      case 11:
        guard object.classID != 0x0100_5505 || p2 == 1 else { cpu.r[0] = 20; return }
        guard object.pcmStream == nil || p2 == 1 else { cpu.r[0] = 20; return }
        object.repeatCount = p2
        object.configure()
      case 16:
        if p2 == 0, object.state == 3 || object.state == 5,
          media.values.contains(where: {
            $0 !== object && ($0.state == 3 || $0.state == 5)
              && ($0.isMIDI == object.isMIDI)
          })
        {
          cpu.r[0] = 32
          return
        }
        object.channelShared = p2 != 0
      case 0x100:
        guard object.classID == 0x0100_5505 else { cpu.r[0] = 20; return }
        guard object.state == 2 else { cpu.r[0] = 13; return }
        guard p2 != 0, p3 > 0, p3 <= 96,
          let messages = MIDIMessage.decode(try memory.data(p2, count: Int(p3))) else { cpu.r[0] = 14; return }
        object.midiMessages = messages
      default:
        log.append("IMedia SetMediaParm unsupported: \(p1), \(p2.hex), \(p3.hex)")
        cpu.r[0] = 20
      }
    case 0x14:
      guard p2 != 0 else {
        cpu.r[0] = 14
        return
      }
      switch p1 {
      case 1:
        guard object.state != 1 else {
          cpu.r[0] = 13
          return
        }
        try memory.write(p2, data: object.descriptor)
      case 4: try memory.write16(p2, object.volume)
      case 5: try memory.write8(p2, object.muted ? 1 : 0)
      case 6: try memory.write16(p2, object.tempo)
      case 8: try memory.write16(p2, object.pan)
      case 11: try memory.write32(p2, object.repeatCount)
      case 12:
        guard try memory.read32(p2) == 0 else {
          cpu.r[0] = 20
          return
        }
        try memory.write32(p2, object.milliseconds)
        if p3 != 0 { try memory.write32(p3, object.milliseconds) }
      case 13: try memory.write32(p2, object.classID)
      case 14:
        try memory.write32(p2, 1)  // Audio only.
        if p3 != 0 { try memory.write32(p3, 0) }
      case 16: try memory.write8(p2, object.channelShared ? 1 : 0)
      default: cpu.r[0] = 20
      }
    case 0x18:
      if object.classID == 0x0100_5505 {
        guard object.state == 2, let messages = object.midiMessages else { cpu.r[0] = 13; return }
        // The first currently playing MIDI file owns the shared synthesizer.
        let file = media.values.filter { $0.classID == 0x0100_5501 && $0.state == 3 }
          .min { $0.playbackOrder < $1.playbackOrder }
        do {
          if let player = file?.player as? MIDIAudioPlayer {
            object.midiOutput?.stop()
            player.send(messages)
          } else {
            if object.midiOutput == nil { object.midiOutput = MIDIMessageOutput() }
            object.configure()
            try object.midiOutput!.send(messages)
          }
          object.state = 3
          notifyMedia(handle, status: 1)
        } catch {
          log.append("MIDI-Nachrichtenausgabe: \(error.localizedDescription)")
          cpu.r[0] = 1
        }
        return
      }
      guard object.state == 2, let player = object.player else {
        cpu.r[0] = 13
        return
      }
      guard canPlayMedia(object) else {
        cpu.r[0] = 32
        return
      }
      if let stream = object.pcmStream {
        player.stop()
        stream.ended = false
        stream.waiting = false
        stream.remainder.removeAll(keepingCapacity: true)
      } else { player.currentTime = 0 }
      object.configure()
      guard player.prepareToPlay(), player.play() else {
        cpu.r[0] = 1
        return
      }
      object.state = 3
      object.playbackOrder = DispatchTime.now().uptimeNanoseconds
      notifyMedia(handle, status: 1)
      log.append("IMedia Play: \(handle.hex)")
    case 0x1c: cpu.r[0] = 20  // Recording is outside the game playback backend.
    case 0x20:
      guard object.state == 3 || object.state == 5 else {
        cpu.r[0] = 13
        return
      }
      object.player?.stop()
      object.midiOutput?.stop()
      if let stream = object.pcmStream {
        try cancelGuestCallback(stream.callback)
        stream.waiting = false
        stream.remainder.removeAll(keepingCapacity: true)
      }
      object.state = 2
      notifyMedia(handle, status: 2)
    case 0x24:
      guard object.pcmStream == nil else { cpu.r[0] = 20; return }
      guard object.state != 1, let player = object.player else {
        cpu.r[0] = 13
        return
      }
      guard p1 <= 2 else {
        cpu.r[0] = 20
        return
      }
      let base = p1 == 0 ? 0 : (p1 == 1 ? player.duration : player.currentTime)
      player.currentTime = min(player.duration, max(0, base + Double(Int32(bitPattern: p2)) / 1000))
      if object.state == 3 || object.state == 5 {
        notifyMedia(handle, status: 7, value: object.milliseconds)
      }
    case 0x28:
      guard object.classID != 0x0100_5505 else { cpu.r[0] = 20; return }
      guard object.state == 3 else {
        cpu.r[0] = 13
        return
      }
      object.player?.pause()
      object.state = 5
      notifyMedia(handle, status: 9, value: object.milliseconds)
    case 0x2c:
      guard object.state == 5, let player = object.player else {
        cpu.r[0] = 13
        return
      }
      guard canPlayMedia(object) else {
        cpu.r[0] = 32
        return
      }
      guard player.play() else {
        cpu.r[0] = 1
        return
      }
      object.state = 3
      notifyMedia(handle, status: 11, value: object.milliseconds)
    case 0x30:
      guard object.pcmStream == nil else { cpu.r[0] = 20; return }
      guard object.state == 2 else {
        cpu.r[0] = 13
        return
      }
      notifyMedia(handle, command: 6, status: 2, value: object.duration)
    case 0x34:
      if p1 != 0 { try memory.write8(p1, 0) }
      cpu.r[0] = object.state
    case 0x38:
      // Private HLE target stored in this stream's AEECallback, not an IMedia slot.
      object.pcmStream?.waiting = false
    default: throw EmulationError.hle("IMedia+" + offset.hex, cpu.r[14])
    }
  }
}
