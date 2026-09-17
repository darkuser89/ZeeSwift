import Foundation

/// Own packed GLES pixel conversion. On Apple Silicon Swift lowers the eight
/// independent pixels to NEON; this does not change guest CPU instructions.
enum PackedPixels {
  /// Caller checks the complete source rectangle and allocates width*height*4
  /// destination bytes. Row padding is not read, including after the final row.
  @inline(never) static func decode(source: UnsafeRawPointer, destination: UnsafeMutableRawPointer,
    width: Int, height: Int, stride: Int, type: UInt32) {
    for y in 0..<height {
      let row = source.advanced(by: y * stride)
      let out = destination.advanced(by: y * width * 4)
      var x = 0
      while x + 8 <= width {
        let packed = row.loadUnaligned(fromByteOffset: x * 2, as: SIMD8<UInt16>.self)
        let v = SIMD8<UInt32>(truncatingIfNeeded: packed)
        let r, g, b, a: SIMD8<UInt32>
        switch type {
        case 0x8363:
          r = (v &>> 11) &* 255 / 31
          g = ((v &>> 5) & 63) &* 255 / 63
          b = (v & 31) &* 255 / 31
          a = .init(repeating: 255)
        case 0x8033:
          r = (v &>> 12) &* 17
          g = ((v &>> 8) & 15) &* 17
          b = ((v &>> 4) & 15) &* 17
          a = (v & 15) &* 17
        default: // GL_UNSIGNED_SHORT_5_5_5_1, validated by the caller.
          r = (v &>> 11) &* 255 / 31
          g = ((v &>> 6) & 31) &* 255 / 31
          b = ((v &>> 1) & 31) &* 255 / 31
          a = (v & 1) &* 255
        }
        // ARM Mac is little-endian: a packed UInt32 stores R,G,B,A in order.
        let rgba = r | (g &<< 8) | (b &<< 16) | (a &<< 24)
        withUnsafeBytes(of: rgba) { out.advanced(by: x * 4).copyMemory(from: $0.baseAddress!, byteCount: 32) }
        x += 8
      }
      // An exact tail, with no speculative read beyond the checked guest row.
      while x < width {
        let v = UInt32(row.loadUnaligned(fromByteOffset: x * 2, as: UInt16.self))
        let r, g, b, a: UInt32
        switch type {
        case 0x8363:
          r = (v >> 11) * 255 / 31; g = ((v >> 5) & 63) * 255 / 63
          b = (v & 31) * 255 / 31; a = 255
        case 0x8033:
          r = (v >> 12) * 17; g = ((v >> 8) & 15) * 17
          b = ((v >> 4) & 15) * 17; a = (v & 15) * 17
        default:
          r = (v >> 11) * 255 / 31; g = ((v >> 6) & 31) * 255 / 31
          b = ((v >> 1) & 31) * 255 / 31; a = (v & 1) * 255
        }
        out.storeBytes(of: r | (g << 8) | (b << 16) | (a << 24), toByteOffset: x * 4, as: UInt32.self)
        x += 1
      }
    }
  }
}
