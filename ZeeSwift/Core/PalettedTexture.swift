import Foundation

/// OES_compressed_paletted_texture decoding, written from the Khronos data layout.
enum PalettedTexture {
  static func decode(format: UInt32, width: Int, height: Int, data: Data) throws -> GLESTexture {
    guard (0x8b90...0x8b99).contains(format), width > 0, height > 0, width <= 2048, height <= 2048
    else { throw EmulationError.invalid("Paletted texture parameters") }
    let eightBit = format >= 0x8b95
    let encoding = Int((format - 0x8b90) % 5)
    let entrySize = encoding == 0 ? 3 : encoding == 1 ? 4 : 2
    let entries = eightBit ? 256 : 16
    let paletteSize = entries * entrySize
    let pixels = width * height
    let indexBytes = eightBit ? pixels : (pixels + 1) / 2
    guard data.count == paletteSize + indexBytes else {
      throw EmulationError.invalid("Paletted texture size")
    }
    var palette: [SIMD4<UInt8>] = []
    palette.reserveCapacity(entries)
    for i in 0..<entries {
      let p = i * entrySize
      if encoding <= 1 {
        palette.append(SIMD4(data[p], data[p + 1], data[p + 2], encoding == 1 ? data[p + 3] : 255))
        continue
      }
      let value = UInt32(data[p]) | UInt32(data[p + 1]) << 8
      let color: SIMD4<UInt32>
      switch encoding {
      case 2:
        color = SIMD4(
          ((value >> 11) & 31) * 255 / 31, ((value >> 5) & 63) * 255 / 63, (value & 31) * 255 / 31,
          255)
      case 3:
        color = SIMD4(
          (value >> 12) * 17, ((value >> 8) & 15) * 17, ((value >> 4) & 15) * 17, (value & 15) * 17)
      default:
        color = SIMD4(
          ((value >> 11) & 31) * 255 / 31, ((value >> 6) & 31) * 255 / 31,
          ((value >> 1) & 31) * 255 / 31, (value & 1) * 255)
      }
      palette.append(SIMD4(UInt8(color.x), UInt8(color.y), UInt8(color.z), UInt8(color.w)))
    }
    var output = Data(count: pixels * 4)
    for i in 0..<pixels {
      let byte = data[paletteSize + (eightBit ? i : i / 2)]
      let index = Int(eightBit ? byte : i % 2 == 0 ? byte >> 4 : byte & 15)
      for c in 0..<4 { output[i * 4 + c] = palette[index][c] }
    }
    return GLESTexture(
      width: width, height: height, pixels: output,
      format: encoding == 0 || encoding == 2 ? 0x1907 : 0x1908, internalFormat: format)
  }
  static func decodeLevels(format: UInt32, width: Int, height: Int, level: Int, data: Data) throws
    -> [GLESTexture.Image]
  {
    guard (0x8b90...0x8b99).contains(format), level <= 0, level >= -11,
      width > 0, height > 0, width <= 2048, height <= 2048,
      -level < Int.bitWidth - max(width, height).leadingZeroBitCount
    else { throw EmulationError.invalid("Paletted texture mipmap level") }
    let encoding = Int((format - 0x8b90) % 5)
    let eightBit = format >= 0x8b95
    let paletteSize = (eightBit ? 256 : 16) * (encoding == 0 ? 3 : encoding == 1 ? 4 : 2)
    let palette = try data.checked(0, paletteSize)
    var cursor = paletteSize
    var images: [GLESTexture.Image] = []
    for index in 0...(-level) {
      let w = max(1, width >> index)
      let h = max(1, height >> index)
      let size = eightBit ? w * h : (w * h + 1) / 2
      let texture = try decode(
        format: format, width: w, height: h,
        data: palette + data.checked(cursor, size))
      images.append(texture.images[0]!)
      cursor += size
    }
    guard cursor == data.count else { throw EmulationError.invalid("Paletted texture mipmap size") }
    return images
  }
}
