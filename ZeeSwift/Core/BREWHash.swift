import CommonCrypto
import CryptoKit
import Foundation

final class BREWMD5 {
  var references: UInt32 = 1
  var context = Insecure.MD5()
}

extension BREWRuntime {
  // Own ABI adapter for AEESecurity.h's IHash. The digest implementation is
  // Apple's CryptoKit; input is consumed directly from checked guest memory.
  func createMD5() throws -> UInt32 {
    let handle = try allocate(4)
    guard handle != 0 else { return 0 }
    let table = hleAddress(0x20a00)
    for offset in stride(from: UInt32(0), through: 0x14, by: 4) {
      try memory.write32(table + offset, 0xf0210000 + offset)
    }
    try memory.write32(handle, table)
    hashes[handle] = BREWMD5()
    return handle
  }

  func dispatchHash(_ offset: UInt32) throws {
    let handle = cpu.r[0]
    guard let object = hashes[handle] else { throw EmulationError.invalid("Released IHash") }
    switch offset {
    case 0: object.references += 1; cpu.r[0] = object.references
    case 4:
      object.references -= 1
      cpu.r[0] = object.references
      if object.references == 0 { hashes.removeValue(forKey: handle); try free(handle) }
    case 8:
      // IHash inherits IBASE, not IQI: slot 8 is Update, not QueryInterface.
      let pointer = cpu.r[1], count = Int(Int32(bitPattern: cpu.r[2]))
      guard count >= 0 else { throw EmulationError.invalid("Negative IHash.Update length") }
      if count > 0 {
        let region = try memory.region(pointer, count)
        object.context.update(bufferPointer: UnsafeRawBufferPointer(
          start: region.bytes.advanced(by: Int(pointer - region.base)), count: count))
      }
      cpu.r[0] = 0
    case 0x0c:
      let output = cpu.r[1], sizePointer = cpu.r[2]
      guard sizePointer != 0 else { cpu.r[0] = 14; return }
      let capacity = Int32(bitPattern: try memory.read32(sizePointer))
      guard capacity >= 0 else { cpu.r[0] = 14; return }
      if capacity < 16 {
        try memory.write32(sizePointer, 16)
        cpu.r[0] = 0x602 // AEE_HASH_MORE_DATA
        return
      }
      guard output != 0 else { cpu.r[0] = 14; return }
      _ = try memory.region(output, 16)
      // finalize() snapshots CryptoKit's context; Restart explicitly resets it.
      try memory.write(output, data: Data(object.context.finalize()))
      try memory.write32(sizePointer, 16)
      cpu.r[0] = 0
    case 0x10: object.context = Insecure.MD5(); cpu.r[0] = 0
    case 0x14:
      // SetKey has no effect on non-HMAC hashes, including this MD5 class.
      cpu.r[0] = 0
    default: throw EmulationError.hle("IHash+" + offset.hex, cpu.r[14])
    }
  }
}


// IHashCtx stores its opaque state in an 88-byte caller-owned buffer. Encode
// state/count/block explicitly, rather than copying Apple's 92-byte host struct.
// Its redundant buffered-byte count follows from the low bit count.
private enum BREWMD5Context {
  static func decode(_ bytes: Data) throws -> CC_MD5_CTX {
    var context = CC_MD5_CTX()
    context.A = try bytes.u32(0); context.B = try bytes.u32(4)
    context.C = try bytes.u32(8); context.D = try bytes.u32(12)
    let totalLow = try bytes.u32(16)
    context.Nl = totalLow & ~511; context.Nh = try bytes.u32(20)
    context.num = Int32((totalLow >> 3) & 63)
    withUnsafeMutableBytes(of: &context.data) { $0.copyBytes(from: bytes[24..<88]) }
    return context
  }
  static func encode(_ context: CC_MD5_CTX) -> Data {
    var bytes = Data()
    // CommonCrypto counts only compressed blocks in Nl/Nh, with pending bytes
    // stored separately in num. Our opaque guest count includes both.
    let total = ((UInt64(context.Nh) << 32) | UInt64(context.Nl))
      &+ UInt64(UInt32(bitPattern: context.num)) * 8
    for value in [context.A,context.B,context.C,context.D,
                  UInt32(truncatingIfNeeded: total), UInt32(total >> 32)] {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
    }
    var block = context.data
    withUnsafeBytes(of: &block) { bytes.append(contentsOf: $0) }
    return bytes
  }
}

extension BREWRuntime {
  func createMD5Context() throws -> UInt32 {
    let handle = try allocate(4)
    guard handle != 0 else { return 0 }
    let table = hleAddress(0x20e00)
    for offset in stride(from: UInt32(0), through: 0x18, by: 4) {
      try memory.write32(table + offset, 0xf0260000 + offset)
    }
    try memory.write32(handle, table)
    hashContexts[handle] = 1
    return handle
  }
  func dispatchHashContext(_ offset: UInt32) throws {
    let handle = cpu.r[0]
    guard let references = hashContexts[handle] else {
      throw EmulationError.invalid("Released IHashCtx")
    }
    switch offset {
    case 0: hashContexts[handle] = references + 1; cpu.r[0] = references + 1
    case 4:
      cpu.r[0] = references - 1
      if references == 1 { hashContexts.removeValue(forKey: handle); try free(handle) }
      else { hashContexts[handle] = references - 1 }
    case 8:
      let output = cpu.r[2]
      guard output != 0 else { cpu.r[0] = 14; return }
      _ = try memory.region(output, 4)
      let supported = cpu.r[1] == 0x01000001 || cpu.r[1] == 0x0102cb09
      try memory.write32(output, supported ? handle : 0)
      if supported { hashContexts[handle] = references + 1 }
      cpu.r[0] = supported ? 0 : 3
    case 0x0c, 0x10, 0x14, 0x18:
      let pointer = cpu.r[1], capacity = Int32(bitPattern: cpu.r[2])
      // Original AEEIHashCtx.h: undersized Init/Update silently do nothing.
      guard capacity >= 88 else { cpu.r[0] = offset <= 0x10 ? 0 : 0x601; return }
      guard pointer != 0 else { cpu.r[0] = offset <= 0x10 ? 0 : 14; return }
      if offset == 0x18 { cpu.r[0] = 0x603; return } // MD5 is not a keyed hash.
      _ = try memory.region(pointer, 88)
      if offset == 0x0c {
        var context = CC_MD5_CTX()
        CC_MD5_Init(&context)
        try memory.write(pointer, data: BREWMD5Context.encode(context))
      } else if offset == 0x10 {
        let count = Int32(bitPattern: try argument(4)), input = cpu.r[3]
        guard count >= 0 else { cpu.r[0] = 0; return }
        var context = try BREWMD5Context.decode(memory.data(pointer, count: 88))
        if count > 0 {
          let region = try memory.region(input, Int(count))
          CC_MD5_Update(&context, region.bytes.advanced(by: Int(input - region.base)), UInt32(count))
        }
        try memory.write(pointer, data: BREWMD5Context.encode(context))
      } else {
        let output = cpu.r[3], sizePointer = try argument(4)
        guard sizePointer != 0 else { cpu.r[0] = 14; return }
        let size = Int32(bitPattern: try memory.read32(sizePointer))
        guard size >= 0 else { cpu.r[0] = 14; return }
        if size < 16 {
          try memory.write32(sizePointer,16)
          cpu.r[0] = 0x602
          return
        }
        guard output != 0 else { cpu.r[0] = 14; return }
        _ = try memory.region(output,16)
        var context = try BREWMD5Context.decode(memory.data(pointer, count: 88))
        var digest = [UInt8](repeating:0,count:16)
        CC_MD5_Final(&digest,&context)
        try memory.write(pointer,data:BREWMD5Context.encode(context))
        try memory.write(output,data:Data(digest))
        try memory.write32(sizePointer,16)
      }
      cpu.r[0] = 0
    default: throw EmulationError.hle("IHashCtx+" + offset.hex, cpu.r[14])
    }
  }
}
