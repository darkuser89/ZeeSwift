import CoreGraphics
import Foundation
import ImageIO

protocol BREWDecodedRaster {
  var width: Int { get }
  var height: Int { get }
  var depth: Int { get }
  var pitch: Int { get }
  var pixels: Data { get }
  var palette: Data { get }
  var transparent: UInt32 { get }
  var rop: UInt32 { get }
}

enum BREWImageFormat {
  case png, jpeg, gif
  var signature: [UInt8] {
    switch self {
    case .png: return [137, 80, 78, 71, 13, 10, 26, 10]
    case .jpeg: return [255, 216, 255]
    case .gif: return [71, 73, 70, 56]
    }
  }
  func decode(_ data: Data) throws -> any BREWDecodedRaster {
    switch self {
    case .png: return try BREWDecodedPNG(data)
    case .jpeg: return try BREWDecodedJPEG(data)
    case .gif: return try BREWDecodedGIF(data)
    }
  }
}

struct BREWDecodedJPEG: BREWDecodedRaster {
  let width: Int
  let height: Int
  let depth = 24
  let pitch: Int
  let pixels: Data
  let palette = Data()
  let transparent = UInt32.max
  let rop: UInt32 = 2

  // Own marker framing check from T.81 Annex B. Image I/O performs the decoding.
  // Do not treat an embedded thumbnail's EOI as completion of a truncated image.
  static func hasCompleteImage(_ input: Data) -> Bool {
    guard input.count <= 32 * 1024 * 1024, input.starts(with: [255, 216]) else { return false }
    var position = 2, scanned = false
    while position < input.count {
      guard input[position] == 255 else { return false }
      while position < input.count, input[position] == 255 { position += 1 }
      guard position < input.count else { return false }
      let marker = input[position]; position += 1
      if marker == 0xd9 { return scanned }
      if marker == 0x01 { continue }
      guard marker != 0, !(0xd0...0xd8).contains(marker), position + 2 <= input.count else { return false }
      let length = Int(input[position]) << 8 | Int(input[position + 1])
      guard length >= 2, length <= input.count - position else { return false }
      position += length
      if marker == 0xda {
        scanned = true
        // Entropy bytes may contain stuffed FF00 or standalone restart markers.
        // Other markers terminate the scan, including later progressive scans.
        while position < input.count {
          if input[position] != 255 { position += 1; continue }
          let start = position
          while position < input.count, input[position] == 255 { position += 1 }
          guard position < input.count else { return false }
          let code = input[position]
          if code == 0 || (0xd0...0xd7).contains(code) { position += 1 }
          else { position = start; break }
        }
      }
    }
    return false
  }

  init(_ input: Data) throws {
    func invalid() -> EmulationError { .invalid("JPEG image data") }
    guard Self.hasCompleteImage(input),
      let source = CGImageSourceCreateWithData(input as CFData, nil),
      CGImageSourceGetStatus(source) == .statusComplete,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, width <= 8191, height > 0, height <= 65535,
      width * height <= 8 * 1024 * 1024,
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
      image.width == width, image.height == height else { throw invalid() }
    self.width = width; self.height = height; pitch = width * 3
    var pixels = Data(count: width * height * 4)
    let rendered = pixels.withUnsafeMutableBytes { raw -> Bool in
      guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
      else { return false }
      context.setBlendMode(.copy)
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      let bytes = raw.bindMemory(to: UInt8.self)
      for p in stride(from: 3, to: bytes.count, by: 4) { bytes[p] = 255 }
      return true
    }
    guard rendered else { throw invalid() }
    // JPEG has no alpha plane. Expose packed IDIB_COLORSCHEME_888 pixels,
    // so guest RGB converters can consume three bytes per pixel directly.
    var packed = Data(count: pitch * height)
    packed.withUnsafeMutableBytes { destination in
      pixels.withUnsafeBytes { source in
        let input = source.bindMemory(to: UInt8.self)
        let output = destination.bindMemory(to: UInt8.self)
        for i in 0..<(width * height) {
          for channel in 0..<3 { output[i * 3 + channel] = input[i * 4 + channel] }
        }
      }
    }
    self.pixels = packed
  }
}
