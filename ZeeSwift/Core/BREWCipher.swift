import CommonCrypto
import Foundation

final class BREWAESCipher {
  var references: UInt32 = 1
  let keySize: Int
  var direction: UInt32
  var mode: UInt32
  var padding: UInt32
  var key = Data()
  var iv = Data(count: 16)
  var input = Data()
  var output = Data()
  var finished = false
  init(keySize: Int, direction: UInt32, mode: UInt32, padding: UInt32) {
    self.keySize = keySize; self.direction = direction; self.mode = mode; self.padding = padding
  }
  func resetBuffers() { input.removeAll(); output.removeAll(); finished = false }
  // Native AES/CBC or AES/ECB for complete blocks. BREW buffering and chaining
  // state are owned here, so invalid guest outputs cannot consume cipher state.
  func transform(_ bytes: Data) throws -> Data {
    guard !bytes.isEmpty else { return Data() }
    var result = Data(count: bytes.count + 16), moved = 0
    let capacity = result.count
    let status = key.withUnsafeBytes { k in iv.withUnsafeBytes { v in bytes.withUnsafeBytes { b in
      result.withUnsafeMutableBytes { out in
        CCCrypt(CCOperation(direction == 0 ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
          CCOptions(mode == 0x0102ccd7 ? kCCOptionECBMode : 0), k.baseAddress, key.count,
          v.baseAddress, b.baseAddress, bytes.count, out.baseAddress, capacity, &moved)
      }
    } } }
    guard status == kCCSuccess, moved == bytes.count else { throw EmulationError.invalid("Native AES processing: \(status)") }
    result.count = moved
    return result
  }
}

extension BREWRuntime {
  static func cipherKeySize(_ cls: UInt32) -> Int? {
    switch cls {
    case 0x0102ccd3, 0x0102ccd4: return 16
    case 0x01039ad7, 0x01039ad8: return 24
    case 0x01039ad3, 0x01039ad5: return 32
    default: return nil
    }
  }
  static func supportsCipher(_ cls: UInt32, _ mode: UInt32, _ padding: UInt32) -> Bool {
    cipherKeySize(cls) != nil && (mode == 0x0102ccd7 || mode == 0x0102ccd9) && padding <= 1
  }
  func createCipherFactory() throws -> UInt32 {
    let handle = try allocate(4)
    guard handle != 0 else { return 0 }
    let table = hleAddress(0x20800)
    for offset in stride(from: UInt32(0), through: 0x14, by: 4) {
      try memory.write32(table + offset, 0xf0220000 + offset)
    }
    try memory.write32(handle, table); cipherFactories[handle] = 1
    return handle
  }
  func createCipher(_ object: BREWAESCipher, output: UInt32) throws -> UInt32 {
    let handle = try allocate(4)
    guard handle != 0 else { return 2 }
    let table = hleAddress(0x20900)
    for offset in stride(from: UInt32(0), through: 0x18, by: 4) {
      try memory.write32(table + offset, 0xf0230000 + offset)
    }
    try memory.write32(handle, table); ciphers[handle] = object
    try memory.write32(output, handle)
    return 0
  }
  func dispatchCipherFactory(_ offset: UInt32) throws {
    let handle = cpu.r[0]
    guard let references = cipherFactories[handle] else { throw EmulationError.invalid("Released ICipherFactory") }
    switch offset {
    case 0: cipherFactories[handle] = references + 1; cpu.r[0] = references + 1
    case 4:
      cpu.r[0] = references - 1
      if references == 1 { cipherFactories.removeValue(forKey: handle); try free(handle) }
      else { cipherFactories[handle] = references - 1 }
    case 8:
      let out = cpu.r[2]
      guard out != 0 else { cpu.r[0] = 14; return }
      _ = try memory.region(out,4)
      let supported = cpu.r[1] == 0x01000001 || cpu.r[1] == 0x0104171d
      try memory.write32(out,supported ? handle : 0)
      if supported { cipherFactories[handle] = references + 1 }
      cpu.r[0] = supported ? 0 : 3
    case 0x0c, 0x10:
      let out = offset == 0x0c ? try argument(5) : cpu.r[3]
      guard out != 0 else { cpu.r[0] = 14; return }
      _ = try memory.region(out,4)
      var cls: UInt32, direction: UInt32, mode: UInt32, padding: UInt32
      var keyPointer: UInt32 = 0, keyCount: UInt32 = 0, ivPointer: UInt32 = 0, ivCount: UInt32 = 0
      if offset == 0x0c {
        cls = cpu.r[1]; direction = cpu.r[2]; mode = cpu.r[3]; padding = try argument(4)
      } else {
        let info = cpu.r[1]
        guard info != 0, cpu.r[2] >= 32 else { cpu.r[0] = 14; return }
        _ = try memory.region(info,32)
        cls = try memory.read32(info); mode = try memory.read32(info+4)
        padding = try memory.read32(info+8); direction = try memory.read32(info+12)
        keyPointer = try memory.read32(info+16); keyCount = try memory.read32(info+20)
        ivPointer = try memory.read32(info+24); ivCount = try memory.read32(info+28)
      }
      guard Self.supportsCipher(cls,mode,padding) else { try memory.write32(out,0); cpu.r[0] = 3; return }
      guard direction <= 1 else { try memory.write32(out,0); cpu.r[0] = 14; return }
      let object = BREWAESCipher(keySize: Self.cipherKeySize(cls)!, direction: direction, mode: mode, padding: padding)
      if keyPointer != 0 && keyCount != 0 {
        guard keyCount == object.keySize else { try memory.write32(out,0); cpu.r[0] = 0x603; return }
        object.key = try memory.data(keyPointer,count:Int(keyCount))
      }
      if ivPointer != 0 && ivCount != 0 {
        guard mode == 0x0102ccd9, ivCount == 16 else { try memory.write32(out,0); cpu.r[0] = 0x608; return }
        object.iv = try memory.data(ivPointer,count:16)
      }
      try memory.write32(out,0)
      cpu.r[0] = try createCipher(object,output:out)
    case 0x14:
      let keySize = try argument(4)
      cpu.r[0] = Self.supportsCipher(cpu.r[1],cpu.r[2],cpu.r[3])
        && (keySize == 0 || Int(keySize) == Self.cipherKeySize(cpu.r[1])) ? 0 : 3
    default: throw EmulationError.hle("ICipherFactory+" + offset.hex,cpu.r[14])
    }
  }
  func dispatchCipher(_ offset: UInt32) throws {
    let handle = cpu.r[0]
    guard let object = ciphers[handle] else { throw EmulationError.invalid("Released ICipher1") }
    switch offset {
    case 0: object.references += 1; cpu.r[0] = object.references
    case 4:
      object.references -= 1; cpu.r[0] = object.references
      if object.references == 0 { ciphers.removeValue(forKey:handle); try free(handle) }
    case 8:
      let out = cpu.r[2]
      guard out != 0 else { cpu.r[0] = 14; return }
      _ = try memory.region(out,4)
      let supported = [0x01000001,0x0102cce3,0x0102d13b,0x0102d13c].contains(cpu.r[1])
      try memory.write32(out,supported ? handle:0)
      if supported { object.references += 1 }; cpu.r[0] = supported ? 0:3
    case 0x0c:
      let id = cpu.r[1], out = cpu.r[2], size = cpu.r[3]
      guard size != 0 else { cpu.r[0] = 14; return }
      let capacity = try memory.read32(size)
      let bytes: Data
      if id == 3 {
        guard object.mode == 0x0102ccd9 else { cpu.r[0] = 14; return }
        bytes = object.iv
      } else {
        let value: UInt32
        switch id {
        case 0: value = object.direction
        case 2: value = UInt32(object.keySize)
        case 4: value = object.mode == 0x0102ccd9 ? 16:0
        case 5: value = object.padding
        case 6: value = 16
        case 8: value = object.mode
        case 9: value = UInt32(object.input.count + object.output.count)
        default: cpu.r[0] = 14; return
        }
        var word = value.littleEndian; bytes = withUnsafeBytes(of:&word) { Data($0) }
      }
      if out == 0 || capacity < bytes.count {
        try memory.write32(size,UInt32(bytes.count)); cpu.r[0] = out == 0 ? 0:38; return
      }
      _ = try memory.region(out,bytes.count)
      try memory.write(out,data:bytes); try memory.write32(size,UInt32(bytes.count))
      cpu.r[0] = id == 9 && object.input.isEmpty && object.output.isEmpty ? 1:0
    case 0x10:
      let id = cpu.r[1], pointer = cpu.r[2], count = cpu.r[3]
      guard pointer != 0 else { cpu.r[0] = 14; return }
      if id == 1 {
        guard count == object.keySize else { cpu.r[0] = 0x603; return }
        object.key = try memory.data(pointer,count:Int(count)); object.resetBuffers()
      } else if id == 3 {
        guard object.mode == 0x0102ccd9, count == 16 else { cpu.r[0] = 14; return }
        object.iv = try memory.data(pointer,count:16); object.resetBuffers()
      } else {
        guard count == 4 else { cpu.r[0] = 14; return }
        let value = try memory.read32(pointer)
        switch id {
        case 0 where value <= 1: object.direction = value
        case 5 where value <= 1: object.padding = value
        case 8 where value == 0x0102ccd7 || value == 0x0102ccd9: object.mode = value
        default: cpu.r[0] = 14; return
        }
        object.resetBuffers()
      }
      cpu.r[0] = 0
    case 0x14, 0x18:
      let last = offset == 0x18
      let out = last ? cpu.r[1]:cpu.r[3], size = last ? cpu.r[2]:try argument(4)
      let count = last ? 0:Int(cpu.r[2])
      guard !object.key.isEmpty, last || !object.finished else { cpu.r[0] = 13; return }
      guard size != 0, out != 0, last || cpu.r[1] != 0 else { cpu.r[0] = 14; return }
      let capacity = Int(try memory.read32(size))
      guard last || capacity >= count else { cpu.r[0] = 38; return }
      var input = object.input
      if last {
        if !input.isEmpty {
          guard object.direction == 0, object.padding == 1 else { cpu.r[0] = 0x609; return }
          input.append(Data(count:16-input.count))
        }
      } else if count > 0 { input.append(try memory.data(cpu.r[1],count:count)) }
      let complete = input.count / 16 * 16
      let available = object.output.count + complete
      guard !last || capacity >= available else { cpu.r[0] = 38; return }
      let written = min(capacity,available)
      _ = try memory.region(out,written)
      let blocks = Data(input.prefix(complete)), converted = try object.transform(blocks)
      var output = object.output; output.append(converted)
      try memory.write(out,data:Data(output.prefix(written)))
      try memory.write32(size,UInt32(written))
      if complete > 0 && object.mode == 0x0102ccd9 {
        object.iv = Data((object.direction == 0 ? converted:blocks).suffix(16))
      }
      object.input = Data(input.dropFirst(complete)); object.output = Data(output.dropFirst(written))
      if last { object.finished = true }; cpu.r[0] = 0
    default: throw EmulationError.hle("ICipher1+" + offset.hex,cpu.r[14])
    }
  }
}
