import CoreGraphics
import Foundation
import ImageIO

// Own adapters for the IImageDecoder, IForceFeed and IDIB interfaces.
// Image I/O performs image decompression; no simulator or emulator implementation is used.
final class BREWImageDecoder {
  let handle: UInt32
  let format: BREWImageFormat
  var references: UInt32 = 1
  var input = Data()
  var finished = false
  var failed = false
  var bitmap: UInt32 = 0
  init(handle: UInt32, format: BREWImageFormat) { self.handle = handle; self.format = format }
}

enum BREWImageViewerFormat {
  case encoded(BREWImageFormat), windowsBitmap
}

final class BREWImageViewer {
  let streamFormat: BREWImageViewerFormat
  var references: UInt32 = 1
  var callback: UInt32 = 0
  var callbackContext: UInt32 = 0
  var stream: UInt32 = 0
  var loadError: UInt32?
  var bitmap: UInt32
  var colors: UInt32
  var width: Int
  var height: Int
  var offsetX = 0
  var offsetY = 0
  var frameWidth: Int
  var frameCount = 1
  var rop: UInt32
  init(bitmap: UInt32, width: Int, height: Int, colors: UInt32, rop: UInt32,
       streamFormat: BREWImageViewerFormat = .encoded(.png)) {
    self.streamFormat = streamFormat
    self.bitmap = bitmap; self.width = width; self.height = height
    self.colors = colors; self.rop = rop; frameWidth = width
  }
}

final class BREWImageBitmap {
  var supportsTransform = false
  var references: UInt32 = 1
  let pixels: UInt32
  let palette: UInt32
  let width: Int
  let height: Int
  let depth: Int
  let pitch: Int
  let rop: UInt32
  init(pixels: UInt32, palette: UInt32, width: Int, height: Int, depth: Int, pitch: Int,
       rop: UInt32 = 2) {
    self.pixels = pixels
    self.palette = palette
    self.width = width
    self.height = height
    self.depth = depth
    self.pitch = pitch
    self.rop = rop
  }
  convenience init(pixels: UInt32, palette: UInt32, image: any BREWDecodedRaster) {
    self.init(pixels: pixels, palette: palette, width: image.width, height: image.height,
      depth: image.depth, pitch: image.pitch, rop: image.rop)
  }
}

struct BREWDecodedPNG: BREWDecodedRaster {
  let width: Int
  let height: Int
  let depth: Int
  let pitch: Int
  let pixels: Data
  let palette: Data
  let transparent: UInt32
  let rop: UInt32

  init(_ input: Data) throws {
    func invalid() -> EmulationError { .invalid("PNG image data") }
    let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    guard input.count <= 32 * 1024 * 1024, input.starts(with: signature) else {
      throw invalid()
    }
    func big(_ at: Int) -> UInt32 {
      UInt32(input[at]) << 24 | UInt32(input[at + 1]) << 16
        | UInt32(input[at + 2]) << 8 | UInt32(input[at + 3])
    }
    var position = 8
    var header: Data?
    var colors = Data()
    var alpha = Data()
    var ended = false
    while position + 12 <= input.count {
      let length = Int(big(position))
      guard length <= input.count - position - 12 else { throw invalid() }
      let kind = big(position + 4)
      let start = position + 8
      let end = start + length
      let checksum = input.withUnsafeBytes { raw in
        crc32(0, raw.bindMemory(to: UInt8.self).baseAddress! + position + 4, UInt32(length + 4))
      }
      guard UInt32(truncatingIfNeeded: checksum) == big(end) else { throw invalid() }
      switch kind {
      case 0x49484452: // IHDR
        guard position == 8, length == 13 else { throw invalid() }
        header = input.subdata(in: start..<end)
      case 0x504c5445: // PLTE
        guard length > 0, length <= 768, length.isMultiple(of: 3), colors.isEmpty else {
          throw invalid()
        }
        colors = input.subdata(in: start..<end)
      case 0x74524e53: alpha = input.subdata(in: start..<end) // tRNS
      case 0x49454e44: // IEND
        guard length == 0, end + 4 == input.count else { throw invalid() }
        ended = true
      default: break
      }
      position = end + 4
    }
    guard ended, position == input.count, let header else { throw invalid() }
    let width = Int(big(16))
    let height = Int(big(20))
    self.width = width
    self.height = height
    // IDIB pitch is signed 16-bit; both guest allocations and host decode are bounded.
    guard width > 0, width <= 8191, height > 0, height <= 65535,
      width * height <= 8 * 1024 * 1024,
      let source = CGImageSourceCreateWithData(input as CFData, nil),
      CGImageSourceGetStatus(source) == .statusComplete,
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width == width, image.height == height
    else { throw invalid() }
    let indexed = header[9] == 3
    var nativeIndices: Data?
    if indexed, image.colorSpace?.model == .indexed,
      [1, 2, 4, 8].contains(image.bitsPerPixel),
      image.bitsPerComponent == image.bitsPerPixel,
      let provider = image.dataProvider?.data
    {
      // Preserve the decoded index plane. Drawing a calibrated/gAMA palette into
      // DeviceRGB changes its colors, so looking them up in the original PLTE
      // afterwards can fail (and also loses duplicate palette entries).
      let raw = provider as Data, bits = image.bitsPerPixel
      guard raw.count >= image.bytesPerRow * height,
        image.bytesPerRow >= (width * bits + 7) / 8 else { throw invalid() }
      let mask = (1 << bits) - 1
      var result = Data(count: width * height)
      for y in 0..<height {
        for x in 0..<width {
          let bit = x * bits
          let index = (Int(raw[y * image.bytesPerRow + bit / 8]) >> (8 - bits - bit % 8)) & mask
          guard index < colors.count / 3 else { throw invalid() }
          result[y * width + x] = UInt8(index)
        }
      }
      nativeIndices = result
    }
    var rgba = Data(count: nativeIndices == nil ? width * height * 4 : 0)
    // Image I/O's PNG provider normally supplies straight RGB(A). Reading it directly
    // retains palette colors, including hidden RGB at alpha zero and partial-alpha values.
    if nativeIndices != nil {
      // The original palette and index bytes below need no RGB conversion.
    } else if image.bitsPerComponent == 8, image.colorSpace?.model == .rgb,
      image.bitsPerPixel == 24 || image.bitsPerPixel == 32,
      image.bitmapInfo.intersection(.byteOrderMask).isEmpty,
      image.alphaInfo == .last || image.alphaInfo == .none || image.alphaInfo == .noneSkipLast,
      let provider = image.dataProvider?.data
    {
      let raw = provider as Data
      let stride = image.bitsPerPixel / 8
      guard raw.count >= image.bytesPerRow * height else { throw invalid() }
      rgba.withUnsafeMutableBytes { destination in
        let out = destination.bindMemory(to: UInt8.self)
        for y in 0..<height {
          for x in 0..<width {
            let p = y * image.bytesPerRow + x * stride
            let q = (y * width + x) * 4
            out[q] = raw[p]; out[q + 1] = raw[p + 1]; out[q + 2] = raw[p + 2]
            out[q + 3] = image.alphaInfo == .last ? raw[p + 3] : 255
          }
        }
      }
    } else {
      // Grayscale and 16-bit PNGs are normalized to straight eight-bit channels.
      let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
        guard let context = CGContext(
          data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let out = raw.bindMemory(to: UInt8.self)
        for p in stride(from: 0, to: out.count, by: 4) {
          let a = Int(out[p + 3])
          if a > 0 && a < 255 {
            for c in 0..<3 { out[p + c] = UInt8(min(255, (Int(out[p + c]) * 255 + a / 2) / a)) }
          }
        }
        return true
      }
      guard drawn else { throw invalid() }
    }
    if indexed {
      let count = colors.count / 3
      guard count > 0, alpha.count <= count else { throw invalid() }
      var entries = Data(count: count * 4)
      var indices: [UInt32: UInt8] = [:]
      var clear: UInt32 = .max
      var partial = false
      for index in 0..<count {
        let r = colors[index * 3], g = colors[index * 3 + 1], b = colors[index * 3 + 2]
        let a: UInt8 = index < alpha.count ? alpha[index] : 255
        entries[index * 4] = b; entries[index * 4 + 1] = g
        entries[index * 4 + 2] = r; entries[index * 4 + 3] = a
        if a == 0 && clear == .max { clear = UInt32(index) }
        if a > 0 && a < 255 { partial = true }
        let key = UInt32(r) << 24 | UInt32(g) << 16 | UInt32(b) << 8 | UInt32(a)
        if indices[key] == nil { indices[key] = UInt8(index) }
      }
      var result = nativeIndices ?? Data(count: width * height)
      for index in 0..<(nativeIndices == nil ? result.count : 0) {
        let p = index * 4
        if rgba[p + 3] == 0, clear != .max {
          result[index] = UInt8(clear)
        } else {
          let key = UInt32(rgba[p]) << 24 | UInt32(rgba[p + 1]) << 16
            | UInt32(rgba[p + 2]) << 8 | UInt32(rgba[p + 3])
          guard let value = indices[key] else { throw invalid() }
          result[index] = value
        }
      }
      depth = 8; pitch = width; pixels = result; palette = entries; transparent = clear
      rop = partial ? 9 : (clear == .max ? 2 : 7)
    } else {
      // IDIB_COLORSCHEME_888 uses native 0xRRGGBB values, little-endian B,G,R bytes.
      // Keep alpha privately in the unused top byte for subsequent bitmap operations.
      var partial = false
      var clear = false
      for p in stride(from: 0, to: rgba.count, by: 4) {
        let r = rgba[p]; rgba[p] = rgba[p + 2]; rgba[p + 2] = r
        if rgba[p + 3] < 255 { partial = true }
        if rgba[p + 3] == 0 { clear = true }
      }
      depth = 32; pitch = width * 4; pixels = rgba; palette = Data()
      transparent = clear ? 0 : .max
      rop = partial ? 9 : 2
    }
  }
}

extension BREWRuntime {
  func loadResourceBitmap() throws {
    let filename = cpu.r[1], id = UInt16(truncatingIfNeeded: cpu.r[2]), handler = cpu.r[3]
    guard handler == 0x0100_1021 || handler == 0 else {
      throw EmulationError.unsupported("IShell.LoadResObject handler " + handler.hex)
    }
    cpu.r[0] = 0
    let bytes: Data
    if id == 0 {
      guard filename != 0, let path = try? filePath(memory.string(filename)),
        let file = try fileContents(path) else { return }
      bytes = file
    } else {
      guard let file = try resourceFile(filename), let blob = file.resource(type: 6, id: id),
        blob.count >= 4, blob[1] == 0 else { return }
      let start = Int(blob[0])
      guard start >= 3, start < blob.count,
        let end = blob[2..<start].firstIndex(of: 0), end > 2 else { return }
      bytes = blob.subdata(in: start..<blob.count)
    }
    let bitmap: UInt32, colors: UInt32
    var format: BREWImageViewerFormat = .encoded(.png)
    if bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) {
      guard let decoded = try? BREWDecodedPNG(bytes) else { return }
      bitmap = try createImageBitmap(decoded)
      colors = UInt32(decoded.palette.count / 4)
    } else if bytes.starts(with: [255, 216]) {
      guard let decoded = try? BREWDecodedJPEG(bytes) else { return }
      bitmap = try createImageBitmap(decoded); colors = 0; format = .encoded(.jpeg)
    } else if bytes.starts(with: [71, 73, 70, 56]) {
      guard let decoded = try? BREWDecodedGIF(bytes) else { return }
      bitmap = try createImageBitmap(decoded); colors = UInt32(decoded.palette.count / 4); format = .encoded(.gif)
    } else if bytes.starts(with: [0x42, 0x4d]) {
      guard let decoded = try createWindowsBitmap(bytes) else { return }
      bitmap = decoded.handle; colors = decoded.colors; format = .windowsBitmap
    } else { return }
    guard bitmap != 0 else { return }
    cpu.r[0] = handler == 0 ? try createImageViewer(owning: bitmap, colors: colors, format: format) : bitmap
  }

  private func createImageViewer(owning bitmap: UInt32, colors: UInt32,
                                 format: BREWImageViewerFormat = .encoded(.png)) throws -> UInt32 {
    // Transfer the newly decoded bitmap's single reference to the viewer.
    let handle = try allocate(4)
    guard handle != 0 else {
      if bitmap != 0 { _ = try releaseImageBitmap(bitmap) }
      return 0
    }
    let layout = bitmap == 0 ? nil : try bitmapLayout(bitmap)
    let table: UInt32 = hleAddress(0x20300)
    for offset in stride(from: UInt32(0), through: 0x28, by: 4) {
      try memory.write32(table + offset, 0xf018_0000 + offset)
    }
    try memory.write32(handle, table)
    imageViewers[handle] = BREWImageViewer(bitmap: bitmap, width: layout?.width ?? 0,
      height: layout?.height ?? 0, colors: colors, rop: imageBitmaps[bitmap]?.rop ?? 2,
      streamFormat: format)
    return handle
  }

  func createPNGImage() throws -> UInt32 {
    try createImageViewer(owning: 0, colors: 0)
  }

  func createJPEGImage() throws -> UInt32 {
    try createImageViewer(owning: 0, colors: 0, format: .encoded(.jpeg))
  }

  func createWindowsBMPImage() throws -> UInt32 {
    try createImageViewer(owning: 0, colors: 0, format: .windowsBitmap)
  }

  private func scheduleImageNotification(_ handle: UInt32, _ image: BREWImageViewer) {
    timers.removeAll { $0.image == handle }
    if image.callback != 0, image.bitmap != 0 || image.loadError != nil {
      scheduleCallback(delay: 0, callback: image.callback,
        context: image.callbackContext, image: handle)
    }
  }

  private func setImageStream(_ handle: UInt32, _ image: BREWImageViewer,
                              stream: UInt32) throws {
    // IMemAStream is immediately readable. Snapshot the unread bytes before
    // replacing the previous stream, whose release may run a guest callback.
    var bitmap: UInt32 = 0, colors: UInt32 = 0
    var loadError: UInt32?
    if stream != 0 {
      guard let source = memoryStreams[stream] else {
        throw EmulationError.unsupported("IImage.SetStream: IAStream " + stream.hex)
      }
      let remaining = source.size - source.position
      if remaining > 32 * 1024 * 1024 {
        loadError = 2
      } else {
        let bytes = remaining == 0 ? Data()
          : try memory.data(source.buffer + source.position, count: Int(remaining))
        switch image.streamFormat {
        case .encoded(let format):
          if let decoded = try? format.decode(bytes) {
            bitmap = try createImageBitmap(decoded)
            colors = UInt32(decoded.palette.count / 4)
            if bitmap == 0 { loadError = 2 }
          } else { loadError = 1 }
        case .windowsBitmap:
          if let decoded = try createWindowsBitmap(bytes) {
            bitmap = decoded.handle; colors = decoded.colors
          } else { loadError = 1 }
        }
        source.position = source.size
      }
      source.references += 1
    }
    let oldBitmap = image.bitmap, oldStream = image.stream
    image.bitmap = bitmap; image.colors = colors
    image.stream = stream; image.loadError = loadError
    image.width = imageBitmaps[bitmap]?.width ?? 0
    image.height = imageBitmaps[bitmap]?.height ?? 0
    image.frameWidth = image.width; image.frameCount = 1
    image.offsetX = 0; image.offsetY = 0
    image.rop = imageBitmaps[bitmap]?.rop ?? 2
    timers.removeAll { $0.image == handle }
    if oldBitmap != 0 { _ = try releaseImageBitmap(oldBitmap) }
    if oldStream != 0 { _ = try releaseMemoryStream(oldStream) }
    // A stream's free callback may have released this viewer or replaced its stream.
    if imageViewers[handle] === image { scheduleImageNotification(handle, image) }
  }

  func dispatchImageViewer(_ offset: UInt32) throws {
    let handle = cpu.r[0]
    guard let image = imageViewers[handle] else {
      throw EmulationError.invalid("Released IImage")
    }
    let p1 = cpu.r[1], p2 = cpu.r[2], p3 = cpu.r[3]
    cpu.r[0] = 0
    switch offset {
    case 0: image.references += 1; cpu.r[0] = image.references
    case 4:
      image.references -= 1
      cpu.r[0] = image.references
      if image.references == 0 {
        imageViewers.removeValue(forKey: handle)
        timers.removeAll { $0.image == handle }
        defer { try? free(handle) }
        if image.bitmap != 0 { _ = try releaseImageBitmap(image.bitmap) }
        if image.stream != 0 { _ = try releaseMemoryStream(image.stream) }
      }
    case 8, 0x0c:
      guard image.bitmap != 0 else { return }
      let frame = offset == 8 ? 0 : Int(Int32(bitPattern: p1))
      guard frame >= -1, frame < image.frameCount else { return }
      let x = Int(Int32(bitPattern: offset == 8 ? p1 : p2))
      let y = Int(Int32(bitPattern: offset == 8 ? p2 : p3))
      let result = try bitmapBlit(destination: displayDestination, source: image.bitmap,
        x: x, y: y, width: image.width, height: image.height,
        sourceX: image.offsetX + max(frame, 0) * image.frameWidth,
        sourceY: image.offsetY, rop: image.rop, clip: currentDisplayClip())
      guard result == 0 else { throw EmulationError.unsupported("IImage.Draw format/raster operation") }
    case 0x10:
      try writeImageViewerInfo(image, to: p1)
    case 0x28:
      // Image I/O has completed synchronously. Deliver completion on the guest
      // queue after this call returns, with the original PFNIMAGEINFO arguments.
      image.callback = p1
      image.callbackContext = p2
      scheduleImageNotification(handle, image)
    case 0x20:
      try setImageStream(handle, image, stream: p1)
    case 0x14:
      let x = Int(Int32(bitPattern: p2)), y = Int(Int32(bitPattern: p3))
      switch p1 {
      case 0: image.width = max(0, x); image.height = max(0, y)
      case 1: image.offsetX = x; image.offsetY = y
      case 2, 4:
        guard image.bitmap != 0 else { return }
        let layout = try bitmapLayout(image.bitmap)
        let width = p1 == 2 ? (x > 0 ? x : layout.height)
          : layout.width / max(1, x > 0 ? x : layout.width / layout.height)
        guard width > 0, width <= layout.width else { return }
        image.frameWidth = width; image.frameCount = layout.width / width; image.width = width
      case 3: image.rop = p2
      case 8:
        guard p2 == display else { throw EmulationError.unsupported("IImage target display " + p2.hex) }
        // The one shared display resolves its current destination at draw time.
      case 9, 10:
        if p2 != 0 { _ = try memory.region(p2, 4) }
        if p3 != 0 { _ = try memory.region(p3, 4) }
        if p2 != 0 {
          try memory.write32(p2, p1 == 9 ? image.rop : image.bitmap)
          if p1 == 10 { imageBitmaps[image.bitmap]?.references += 1 }
        }
        if p3 != 0 {
          try memory.write32(p3, p2 == 0 ? 14 : (p1 == 10 && image.bitmap == 0 ? 1 : 0))
        }
      case 13:
        if p3 != 0 { try memory.write32(p3, 20) }
      default: throw EmulationError.unsupported("IImage.SetParm " + p1.hex)
      }
    case 0x1c: break  // No asynchronous animation is started by this static-image adapter.
    case 0x24: break  // Static images do not consume application input events.
    default: throw EmulationError.hle("IImage+" + offset.hex, cpu.r[14])
    }
  }

  func writeImageViewerInfo(_ image: BREWImageViewer, to output: UInt32) throws {
    let layout = image.bitmap == 0 ? nil : try bitmapLayout(image.bitmap)
    var info = Data(count: 10)
    for (offset, value) in [(0, layout?.width ?? 0), (2, layout?.height ?? 0),
      (4, Int(image.colors)), (8, image.frameWidth)] {
      info[offset] = UInt8(truncatingIfNeeded: value)
      info[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
    info[6] = image.frameCount > 1 ? 1 : 0
    try memory.write(output, data: info)
  }

  func createImageDecoder(format: BREWImageFormat = .png) throws -> UInt32 {
    let handle = try allocate(8)
    guard handle != 0 else { return 0 }
    for (index, api) in [UInt32(0xf015_0000), 0xf016_0000].enumerated() {
      let table = hleAddress(0x20000 + UInt32(index * 0x100))
      try memory.write32(handle + UInt32(index * 4), table)
      for offset in stride(from: UInt32(0), through: 16, by: 4) {
        try memory.write32(table + offset, api + offset)
      }
    }
    let object = BREWImageDecoder(handle: handle, format: format)
    imageDecoders[handle] = object
    imageDecoders[handle + 4] = object
    return handle
  }

  private func decodeImage(_ object: BREWImageDecoder) throws -> UInt32 {
    if object.bitmap != 0 { return 0 }
    guard !object.failed, let image = try? object.format.decode(object.input) else { return 1 }
    let handle = try createImageBitmap(image)
    guard handle != 0 else { return 2 }
    object.bitmap = handle
    return 0
  }

  func createImageBitmap(_ image: any BREWDecodedRaster) throws -> UInt32 {
    let handle = try allocate(36)
    guard handle != 0 else { return 0 }
    let pixels = try allocate(UInt32(image.pixels.count) | 0x8000_0000)
    guard pixels != 0 else { try free(handle); return 0 }
    let palette = image.palette.isEmpty ? 0 : try allocate(UInt32(image.palette.count))
    guard image.palette.isEmpty || palette != 0 else {
      try free(pixels); try free(handle); return 0
    }
    let table: UInt32 = hleAddress(0x20200)
    for offset in stride(from: UInt32(0), through: 0x3c, by: 4) {
      try memory.write32(table + offset, 0xf017_0000 + offset)
    }
    try memory.write32(handle, table)
    try memory.write32(handle + 8, pixels)
    try memory.write32(handle + 12, palette)
    try memory.write32(handle + 16, image.transparent)
    try memory.write16(handle + 20, UInt32(image.width))
    try memory.write16(handle + 22, UInt32(image.height))
    try memory.write16(handle + 24, UInt32(image.pitch))
    try memory.write16(handle + 26, UInt32(image.palette.count / 4))
    try memory.write8(handle + 28, UInt32(image.depth))
    try memory.write8(handle + 29, image.palette.isEmpty ? 24 : 0)
    try memory.write(pixels, data: image.pixels)
    if palette != 0 { try memory.write(palette, data: image.palette) }
    imageBitmaps[handle] = BREWImageBitmap(pixels: pixels, palette: palette, image: image)
    return handle
  }

  func releaseImageBitmap(_ handle: UInt32) throws -> UInt32 {
    guard let object = imageBitmaps[handle] else { throw EmulationError.invalid("Released image") }
    object.references -= 1
    if object.references == 0 {
      convertedBitmaps.remove(handle)
      imageBitmaps.removeValue(forKey: handle)
      try free(object.pixels); try free(object.palette); try free(handle)
    }
    return object.references
  }

  func dispatchImageDecoder(_ offset: UInt32, feeding: Bool) throws {
    guard let object = imageDecoders[cpu.r[0]] else {
      throw EmulationError.invalid("Released image decoder")
    }
    let p1 = cpu.r[1], p2 = cpu.r[2]
    cpu.r[0] = 0
    switch offset {
    case 0: object.references += 1; cpu.r[0] = object.references
    case 4:
      object.references -= 1; cpu.r[0] = object.references
      if object.references == 0 {
        if object.bitmap != 0 { _ = try releaseImageBitmap(object.bitmap) }
        imageDecoders.removeValue(forKey: object.handle)
        imageDecoders.removeValue(forKey: object.handle + 4)
        try free(object.handle)
      }
    case 8:
      guard p2 != 0 else { cpu.r[0] = 14; return }
      let result: UInt32
      switch p1 {
      case 0x0100_0001, 0x0102_6e20: result = object.handle
      case 0x0101_eb0b: result = object.handle + 4
      default: result = 0
      }
      try memory.write32(p2, result)
      if result != 0 { object.references += 1 } else { cpu.r[0] = 3 }
    case 0x0c where feeding:
      guard !object.finished else { cpu.r[0] = 13; return }
      guard !object.failed else { cpu.r[0] = 1; return }
      guard Int32(bitPattern: p2) >= 0 else { cpu.r[0] = 14; return }
      if p1 == 0 {
        cpu.r[0] = try decodeImage(object)
        if cpu.r[0] == 0 { object.finished = true; object.input = Data() }
        else if cpu.r[0] != 2 { object.failed = true }
      } else {
        if p2 == 0 { return }
        guard object.bitmap == 0 else { cpu.r[0] = 13; return }
        guard Int(p2) <= 32 * 1024 * 1024 - object.input.count else { cpu.r[0] = 2; return }
        let bytes = try memory.data(p1, count: Int(p2))
        object.input.append(bytes)
        let signature = object.format.signature
        if !signature.starts(with: object.input.prefix(signature.count)) {
          object.failed = true; cpu.r[0] = 1
        }
      }
    case 0x10 where feeding:
      if object.bitmap != 0 { _ = try releaseImageBitmap(object.bitmap) }
      object.bitmap = 0; object.input = Data(); object.finished = false; object.failed = false
    case 0x0c:
      guard p1 != 0 else { cpu.r[0] = 14; return }
      _ = try memory.region(p1, 4)
      cpu.r[0] = try decodeImage(object)
      try memory.write32(p1, cpu.r[0] == 0 ? object.bitmap : 0)
      if cpu.r[0] == 0 { imageBitmaps[object.bitmap]!.references += 1 }
    case 0x10: cpu.r[0] = imageBitmaps[object.bitmap]?.rop ?? 2
    default: throw EmulationError.hle("IImageDecoder+" + offset.hex, cpu.r[14])
    }
  }

  func dispatchImageBitmap(_ offset: UInt32) throws {
    let handle = cpu.r[0]
    guard let object = imageBitmaps[handle] else { throw EmulationError.invalid("Released image") }
    let p1 = cpu.r[1], p2 = cpu.r[2]
    cpu.r[0] = 0
    switch offset {
    case 0: object.references += 1; cpu.r[0] = object.references
    case 4: cpu.r[0] = try releaseImageBitmap(handle)
    case 8:
      if p1 == 0x0100_1029 {
        cpu.r[0] = try queryBitmapTransform(handle, output: p2)
        return
      }
      guard p2 != 0 else { cpu.r[0] = 14; return }
      let matches = [UInt32(0x0100_0001), 0x0100_1021, 0x0100_1045].contains(p1)
      try memory.write32(p2, matches ? handle : 0)
      if matches { object.references += 1 } else { cpu.r[0] = 3 }
    case 0x30:
      guard p2 == 12 else { cpu.r[0] = 20; return }
      guard p1 != 0 else { cpu.r[0] = 14; return }
      _ = try memory.region(p1, 12)
      for (i, value) in [object.width, object.height, object.depth].enumerated() {
        try memory.write32(p1 + UInt32(i * 4), UInt32(value))
      }
    case 0x38: try memory.write32(handle + 16, p1)
    case 0x3c:
      guard p1 != 0 else { cpu.r[0] = 14; return }
      try memory.write32(p1, memory.read32(handle + 16))
    default:
      cpu.r[0] = handle
      if try !dispatchBitmapOperation(offset) {
        throw EmulationError.hle("ImageBitmap+" + offset.hex, cpu.r[14])
      }
    }
  }
}

// Single-frame GIF images (including Z-Wheel's opening_low.gif). Image I/O
// decodes the original file; the existing PNG adapter preserves its alpha and
// palette semantics after a lossless in-memory conversion. Multi-frame GIFs
// require timing/disposal support and are explicitly rejected here.
struct BREWDecodedGIF: BREWDecodedRaster {
  private let raster: BREWDecodedPNG
  var width: Int { raster.width }
  var height: Int { raster.height }
  var depth: Int { raster.depth }
  var pitch: Int { raster.pitch }
  var pixels: Data { raster.pixels }
  var palette: Data { raster.palette }
  var transparent: UInt32 { raster.transparent }
  var rop: UInt32 { raster.rop }
  init(_ data: Data) throws {
    guard data.count >= 14, data.count <= 32 * 1024 * 1024,
      data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)),
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetStatus(source) == .statusComplete else { throw EmulationError.invalid("GIF image data") }
    guard CGImageSourceGetCount(source) == 1 else { throw EmulationError.unsupported("Multi-frame GIF") }
    let width = Int(data[6]) | Int(data[7]) << 8, height = Int(data[8]) | Int(data[9]) << 8
    guard width > 0, width <= 8191, height > 0, width * height <= 8 * 1024 * 1024,
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
      image.width == width, image.height == height else { throw EmulationError.invalid("GIF raster") }
    let png = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)
    else { throw EmulationError.invalid("GIF raster conversion") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw EmulationError.invalid("GIF raster conversion") }
    raster = try BREWDecodedPNG(png as Data)
  }
}
