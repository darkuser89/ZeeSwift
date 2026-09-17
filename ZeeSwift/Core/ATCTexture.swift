import Foundation

/// Original ATC block reader. Format tokens and block sizes follow Khronos;
/// endpoint layout and rounding were checked against AMD's original format tool.
/// No external decoder is linked or embedded.
enum ATCTexture {
  static let formats: [UInt32] = [0x8c92, 0x8c93, 0x87ee]
  static func decode(format: UInt32, width: Int, height: Int, data: Data) throws -> GLESTexture {
    guard formats.contains(format),
      width > 0, height > 0, width <= 2048, height <= 2048
    else { throw EmulationError.invalid("ATC texture parameters") }
    let hasAlpha = format != 0x8c92
    let blockBytes = hasAlpha ? 16 : 8
    let columns = (width + 3) / 4
    let rows = (height + 3) / 4
    guard data.count == columns * rows * blockBytes else {
      throw EmulationError.invalid("ATC texture size")
    }
    func bits(_ offset: Int, _ count: Int) -> UInt64 {
      (0..<count).reduce(UInt64(0)) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
    }
    func expand(_ value: UInt64, _ bits: Int) -> Int {
      let masked = Int(value & ((1 << bits) - 1))
      return masked << (8 - bits) | masked >> (2 * bits - 8)
    }
    var output = Data(count: width * height * 4)
    for block in 0..<(columns * rows) {
      let offset = block * blockBytes
      let colorBits = bits(offset + (hasAlpha ? 8 : 0), 8)
      let a = [expand(colorBits >> 10, 5), expand(colorBits >> 5, 5), expand(colorBits, 5)]
      let b = [expand(colorBits >> 27, 5), expand(colorBits >> 21, 6), expand(colorBits >> 16, 5)]
      let special = colorBits & 0x8000 != 0
      var palette = Array(repeating: [Int](repeating: 0, count: 3), count: 4)
      for channel in 0..<3 {
        palette[0][channel] = special ? 0 : a[channel]
        palette[1][channel] =
          special ? max(0, a[channel] - b[channel] / 4) : (5 * a[channel] + 3 * b[channel]) / 8
        palette[2][channel] = special ? a[channel] : (3 * a[channel] + 5 * b[channel]) / 8
        palette[3][channel] = b[channel]
      }
      let alphaBits = hasAlpha ? bits(offset, 8) : 0
      var alphaRamp = [Int](repeating: 0, count: 8)
      if format == 0x87ee {
        alphaRamp[0] = Int(alphaBits & 255)
        alphaRamp[1] = Int(alphaBits >> 8 & 255)
        let divisor = alphaRamp[0] > alphaRamp[1] ? 7 : 5
        for index in 2...divisor {
          let weight = index - 1
          alphaRamp[index] =
            ((divisor - weight) * alphaRamp[0] + weight * alphaRamp[1] + divisor / 2) / divisor
        }
        if divisor == 5 {
          alphaRamp[6] = 0
          alphaRamp[7] = 255
        }
      }
      for texel in 0..<16 {
        let x = (block % columns) * 4 + texel % 4
        let y = (block / columns) * 4 + texel / 4
        guard x < width, y < height else { continue }
        let destination = (y * width + x) * 4
        let index = Int(colorBits >> (32 + texel * 2) & 3)
        for channel in 0..<3 { output[destination + channel] = UInt8(palette[index][channel]) }
        switch format {
        case 0x8c93: output[destination + 3] = UInt8(alphaBits >> (texel * 4) & 15) * 17
        case 0x87ee:
          output[destination + 3] = UInt8(alphaRamp[Int(alphaBits >> (16 + texel * 3) & 7)])
        default: output[destination + 3] = 255
        }
      }
    }
    return GLESTexture(
      width: width, height: height, pixels: output, format: hasAlpha ? 0x1908 : 0x1907,
      internalFormat: format)
  }
}
