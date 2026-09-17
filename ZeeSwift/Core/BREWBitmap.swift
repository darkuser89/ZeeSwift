import CoreGraphics
import Foundation
import ImageIO

struct BREWBitmapLayout {
  let handle: UInt32
  let pixels: UInt32
  let palette: UInt32
  let paletteCount: Int
  let width: Int
  let height: Int
  let depth: Int
  let scheme: UInt32
  let pitch: Int
  let transparent: UInt32
  var pixelBytes: Int { depth / 8 }
}

extension BREWRuntime {
  func isNativeBitmap(_ handle: UInt32) -> Bool {
    handle == bitmap || handle == dib || imageBitmaps[handle] != nil
  }

  // A game may implement IBitmap itself. Call its public vtable, never interpret
  // that object's private storage as IDIB. Extra AAPCS arguments need a separate
  // stack frame so nested calls cannot overwrite the outer HLE call's arguments.
  func callBitmapMethod(_ handle: UInt32, _ offset: UInt32, _ args: [UInt32] = []) throws -> UInt32 {
    let table = try memory.read32(handle)
    let entry = try memory.read32(table + offset)
    let registers = (0..<16).map { cpu.r[$0] }, flags = cpu.cpsr
    guard args.count <= 8, registers[13] >= 64 else { throw EmulationError.invalid("IBitmap call frame") }
    let stack = (registers[13] - 64) & ~UInt32(7)
    _ = try memory.region(stack, 64)
    defer {
      for i in 0..<16 { cpu.r[i] = registers[i] }
      cpu.cpsr = flags
    }
    cpu.r[13] = stack
    return try invoke(entry, [handle] + args)
  }

  func bitmapDimensions(_ handle: UInt32) throws -> SIMD2<Int> {
    if isNativeBitmap(handle) {
      let layout = try bitmapLayout(handle)
      return SIMD2(layout.width, layout.height)
    }
    guard cpu.r[13] >= 16 else { throw EmulationError.invalid("IBitmap info call frame") }
    let info = cpu.r[13] - 16
    try memory.write(info, data: Data(count: 12))
    let result = try callBitmapMethod(handle, 0x30, [info, 12])
    guard result == 0 else { throw EmulationError.unsupported("IBitmap.GetInfo " + result.hex) }
    let width = try memory.read32(info), height = try memory.read32(info + 4)
    guard width <= 65535, height <= 65535 else { throw EmulationError.invalid("IBitmap dimensions") }
    return SIMD2(Int(width), Int(height))
  }

  func retainBitmap(_ handle: UInt32) throws {
    if let image = imageBitmaps[handle] { image.references += 1 }
    else if handle != bitmap && handle != dib { _ = try callBitmapMethod(handle, 0) }
  }

  func releaseBitmap(_ handle: UInt32) throws {
    if imageBitmaps[handle] != nil { _ = try releaseImageBitmap(handle) }
    else if handle != bitmap && handle != dib { _ = try callBitmapMethod(handle, 4) }
  }

  func bitmapLayout(_ handle: UInt32) throws -> BREWBitmapLayout {
    let address = handle == bitmap ? dib : handle
    guard address == dib || imageBitmaps[address] != nil else {
      throw EmulationError.unsupported("Guest IBitmap " + handle.hex)
    }
    let depth = Int(try memory.read8(address + 28))
    guard [8, 16, 24, 32].contains(depth) else {
      throw EmulationError.unsupported("Bitmap color depth \(depth)")
    }
    return try BREWBitmapLayout(handle: address, pixels: memory.read32(address + 8),
      palette: memory.read32(address + 12), paletteCount: Int(memory.read16(address + 26)),
      width: Int(memory.read16(address + 20)), height: Int(memory.read16(address + 22)),
      depth: depth, scheme: memory.read8(address + 29),
      pitch: Int(Int16(truncatingIfNeeded: memory.read16(address + 24))),
      transparent: memory.read32(address + 16))
  }

  private func bitmapPixelAddress(_ layout: BREWBitmapLayout, _ x: Int, _ y: Int) throws -> UInt32 {
    let address = Int64(layout.pixels) + Int64(y) * Int64(layout.pitch) + Int64(x * layout.pixelBytes)
    guard address >= 0, address <= Int64(UInt32.max) else {
      throw EmulationError.invalid("Bitmap pixel address")
    }
    return UInt32(address)
  }

  func bitmapReadPixel(_ layout: BREWBitmapLayout, _ x: Int, _ y: Int) throws -> UInt32 {
    let p = try bitmapPixelAddress(layout, x, y)
    switch layout.depth {
    case 8: return try memory.read8(p)
    case 16: return try memory.read16(p)
    case 24: return try memory.read8(p) | (memory.read8(p + 1) << 8) | (memory.read8(p + 2) << 16)
    default: return try memory.read32(p)
    }
  }

  func bitmapWritePixel(_ layout: BREWBitmapLayout, _ x: Int, _ y: Int, _ value: UInt32) throws {
    let p = try bitmapPixelAddress(layout, x, y)
    switch layout.depth {
    case 8: try memory.write8(p, value)
    case 16: try memory.write16(p, value)
    case 24:
      _ = try memory.region(p, 3)
      try memory.write8(p, value)
      try memory.write8(p + 1, value >> 8)
      try memory.write8(p + 2, value >> 16)
    default: try memory.write32(p, value)
    }
  }

  func bitmapRGB(_ native: UInt32, _ layout: BREWBitmapLayout) throws -> UInt32 {
    let color: UInt32
    if layout.paletteCount > 0 {
      guard native < UInt32(layout.paletteCount) else { return 0 }
      color = try memory.read32(layout.palette + native * 4)
    } else if layout.scheme == 16 {
      let r = (native >> 11) & 31, g = (native >> 5) & 63, b = native & 31
      color = ((r << 3) | (r >> 2)) << 16 | ((g << 2) | (g >> 4)) << 8 | (b << 3) | (b >> 2)
    } else if layout.scheme == 24 {
      color = native
    } else {
      throw EmulationError.unsupported("Bitmap color scheme " + layout.scheme.hex)
    }
    // RGBVAL is 0xBBGGRR00, not a native IDIB pixel value.
    return (color & 0xff) << 24 | (color & 0xff00) << 8 | (color >> 8) & 0xff00
  }

  func bitmapNative(_ rgb: UInt32, _ layout: BREWBitmapLayout) throws -> UInt32 {
    let r = (rgb >> 8) & 255, g = (rgb >> 16) & 255, b = rgb >> 24
    if layout.paletteCount > 0 {
      var best: UInt32 = 0
      var bestDistance = Int.max
      for index in 0..<layout.paletteCount {
        let entry = try memory.read32(layout.palette + UInt32(index * 4))
        let dr = Int(r) - Int((entry >> 16) & 255)
        let dg = Int(g) - Int((entry >> 8) & 255)
        let db = Int(b) - Int(entry & 255)
        let distance = dr * dr + dg * dg + db * db
        if distance < bestDistance { best = UInt32(index); bestDistance = distance }
        if distance == 0 { break }
      }
      return best
    }
    if layout.scheme == 16 { return (r >> 3) << 11 | (g >> 2) << 5 | (b >> 3) }
    if layout.scheme == 24 { return r << 16 | g << 8 | b }
    throw EmulationError.unsupported("Bitmap color scheme " + layout.scheme.hex)
  }

  func createCompatibleBitmap(_ source: BREWBitmapLayout, width: Int, height: Int) throws -> UInt32 {
    let pitch = (width * source.pixelBytes + 3) & ~3
    guard width > 0, height > 0, pitch <= Int(Int16.max), pitch * height <= 32 * 1024 * 1024 else {
      return 0
    }
    let paletteBytes = source.paletteCount == 0 ? Data()
      : try memory.data(source.palette, count: source.paletteCount * 4)
    let handle = try allocate(36)
    guard handle != 0 else { return 0 }
    let pixels = try allocate(UInt32(pitch * height))
    guard pixels != 0 else { try free(handle); return 0 }
    let palette = paletteBytes.isEmpty ? 0 : try allocate(UInt32(paletteBytes.count))
    guard paletteBytes.isEmpty || palette != 0 else {
      try free(pixels); try free(handle); return 0
    }
    let table: UInt32 = hleAddress(0x20200)
    for offset in stride(from: UInt32(0), through: 0x3c, by: 4) {
      try memory.write32(table + offset, 0xf017_0000 + offset)
    }
    try memory.write32(handle, table)
    try memory.write32(handle + 8, pixels)
    try memory.write32(handle + 12, palette)
    try memory.write32(handle + 16, source.transparent)
    try memory.write16(handle + 20, UInt32(width))
    try memory.write16(handle + 22, UInt32(height))
    try memory.write16(handle + 24, UInt32(pitch))
    try memory.write16(handle + 26, UInt32(source.paletteCount))
    try memory.write8(handle + 28, UInt32(source.depth))
    try memory.write8(handle + 29, source.scheme)
    if palette != 0 { try memory.write(palette, data: paletteBytes) }
    imageBitmaps[handle] = BREWImageBitmap(pixels: pixels, palette: palette, width: width,
      height: height, depth: source.depth, pitch: pitch)
    imageBitmaps[handle]!.supportsTransform = true
    return handle
  }

  func dispatchBitmapOperation(_ offset: UInt32) throws -> Bool {
    guard [UInt32(0x0c), 0x10, 0x14, 0x18, 0x1c, 0x20, 0x24, 0x28, 0x2c, 0x34, 0x38, 0x3c].contains(offset) else {
      return false
    }
    let layout = try bitmapLayout(cpu.r[0])
    let p1 = cpu.r[1], p2 = cpu.r[2], p3 = cpu.r[3]
    switch offset {
    case 0x28, 0x2c:
      let other = try argument(5)
      cpu.r[0] = try bitmapBlit(destination: offset == 0x28 ? layout.handle : other,
        source: offset == 0x28 ? other : layout.handle,
        x: Int(Int32(bitPattern: p1)), y: Int(Int32(bitPattern: p2)),
        width: Int(Int32(bitPattern: p3)), height: Int(Int32(bitPattern: argument(4))),
        sourceX: Int(Int32(bitPattern: argument(6))), sourceY: Int(Int32(bitPattern: argument(7))),
        rop: argument(8), allowDestinationCallback: offset == 0x28)
    case 0x0c: cpu.r[0] = try bitmapNative(p1, layout)
    case 0x10: cpu.r[0] = try bitmapRGB(p1, layout)
    case 0x34:
      guard p1 != 0 else { cpu.r[0] = 14; return true }
      _ = try memory.region(p1, 4)
      let width = Int(p2 & 0xffff), height = Int(p3 & 0xffff)
      guard width > 0, height > 0 else {
        try memory.write32(p1, 0); cpu.r[0] = 14; return true
      }
      let result = try createCompatibleBitmap(layout, width: width, height: height)
      try memory.write32(p1, result)
      cpu.r[0] = result == 0 ? 2 : 0
    case 0x38:
      try memory.write32(layout.handle + 16, p1); cpu.r[0] = 0
    case 0x3c:
      guard p1 != 0 else { cpu.r[0] = 14; return true }
      try memory.write32(p1, layout.transparent); cpu.r[0] = 0
    case 0x18:
      guard p1 < layout.width, p2 < layout.height, p3 != 0 else { cpu.r[0] = 14; return true }
      let value = try bitmapReadPixel(layout, Int(p1), Int(p2))
      try memory.write32(p3, value); cpu.r[0] = 0
    case 0x14:
      let rop = try argument(4)
      guard rop == 1 || rop == 2 else { cpu.r[0] = 20; return true }
      if p1 < layout.width && p2 < layout.height {
        let value = rop == 1 ? try bitmapReadPixel(layout, Int(p1), Int(p2)) ^ p3 : p3
        try bitmapWritePixel(layout, Int(p1), Int(p2), value)
      }
      cpu.r[0] = 0
    case 0x1c:
      // SetPixels uses an unsigned count, packed signed int16 x/y pairs,
      // native color and stack ROP. Every operation except XOR means COPY.
      let rop = try argument(4)
      guard p1 <= 1_048_576 else { throw EmulationError.invalid("IBitmap.SetPixels limit") }
      if p1 > 0 {
        guard p2 != 0 else { cpu.r[0] = 14; return true }
        let points = try memory.data(p2, count: Int(p1) * 4)
        for index in 0..<Int(p1) {
          let at = index * 4
          let x = Int(Int16(bitPattern: UInt16(points[at]) | UInt16(points[at + 1]) << 8))
          let y = Int(Int16(bitPattern: UInt16(points[at + 2]) | UInt16(points[at + 3]) << 8))
          if x >= 0, y >= 0, x < layout.width, y < layout.height {
            let value = rop == 1 ? try bitmapReadPixel(layout, x, y) ^ p3 : p3
            try bitmapWritePixel(layout, x, y, value)
          }
        }
      }
      cpu.r[0] = 0
    case 0x20:
      // IBitmap.DrawHScanline uses unsigned coordinates and inclusive endpoints.
      let color = try argument(4), rop = try argument(5)
      guard rop == 1 || rop == 2 else { cpu.r[0] = 20; return true }
      if p1 < layout.height, p2 < layout.width, p2 <= p3 {
        let end = min(Int(p3), layout.width - 1)
        for x in Int(p2)...end {
          let value = rop == 1 ? try bitmapReadPixel(layout, x, Int(p1)) ^ color : color
          try bitmapWritePixel(layout, x, Int(p1), value)
        }
      }
      cpu.r[0] = 0
    case 0x24:
      guard p1 != 0 else { cpu.r[0] = 14; return true }
      guard p3 == 1 || p3 == 2 else { cpu.r[0] = 20; return true }
      let x = Int(Int16(truncatingIfNeeded: try memory.read16(p1)))
      let y = Int(Int16(truncatingIfNeeded: try memory.read16(p1 + 2)))
      let w = Int(Int16(truncatingIfNeeded: try memory.read16(p1 + 4)))
      let h = Int(Int16(truncatingIfNeeded: try memory.read16(p1 + 6)))
      let x0 = max(0, x), y0 = max(0, y), x1 = min(layout.width, x + w), y1 = min(layout.height, y + h)
      if x0 < x1 && y0 < y1 {
        for row in y0..<y1 {
          for col in x0..<x1 {
            let value = p3 == 1 ? try bitmapReadPixel(layout, col, row) ^ p2 : p2
            try bitmapWritePixel(layout, col, row, value)
          }
        }
      }
      cpu.r[0] = 0
    default: return false
    }
    return true
  }

  func currentDisplayClip() throws -> SIMD4<Int> {
    let size = try bitmapDimensions(displayDestination)
    guard let c = displayClip else { return SIMD4(0, 0, size.x, size.y) }
    let left = max(0, c.x), top = max(0, c.y)
    let right = min(size.x, c.x + c.z), bottom = min(size.y, c.y + c.w)
    guard c.z > 0, c.w > 0, left < right, top < bottom else { return .zero }
    return SIMD4(left, top, right - left, bottom - top)
  }

  func bitmapBlit(destination: UInt32, source: UInt32, x: Int, y: Int, width: Int, height: Int,
                  sourceX: Int, sourceY: Int, rop: UInt32, clip: SIMD4<Int>? = nil,
                  allowDestinationCallback: Bool = true) throws -> UInt32 {
    guard width > 0, height > 0 else { return 0 }
    guard rop <= 9 else { return 20 }
    if !isNativeBitmap(destination) || !isNativeBitmap(source) {
      // BltOut must not delegate back to BltIn: the interface explicitly forbids that
      // recursion. An unknown destination's BltIn can handle a native source.
      let guestDestination = !isNativeBitmap(destination)
      if guestDestination && !allowDestinationCallback { return 20 }
      let dst = try bitmapDimensions(destination), src = try bitmapDimensions(source)
      let c = clip ?? SIMD4(0, 0, dst.x, dst.y)
      let left = max(0, -x, -sourceX, c.x - x), top = max(0, -y, -sourceY, c.y - y)
      let right = min(width, dst.x - x, src.x - sourceX, c.x + c.z - x)
      let bottom = min(height, dst.y - y, src.y - sourceY, c.y + c.w - y)
      guard left < right, top < bottom else { return 0 }
      return try callBitmapMethod(guestDestination ? destination : source,
        guestDestination ? 0x28 : 0x2c,
        [UInt32(x + left), UInt32(y + top), UInt32(right - left), UInt32(bottom - top),
         guestDestination ? source : destination, UInt32(sourceX + left), UInt32(sourceY + top), rop])
    }
    let dst = try bitmapLayout(destination), src = try bitmapLayout(source)
    // Alpha compositing into an alpha-bearing image needs a separate destination-alpha
    // path. The current blend path targets opaque display/compatible bitmaps only.
    if rop == 9 && imageBitmaps[dst.handle]?.rop == 9 { return 20 }
    let c = clip ?? SIMD4(0, 0, dst.width, dst.height)
    let left = max(0, -x, -sourceX, c.x - x)
    let top = max(0, -y, -sourceY, c.y - y)
    let right = min(width, dst.width - x, src.width - sourceX, c.x + c.z - x)
    let bottom = min(height, dst.height - y, src.height - sourceY, c.y + c.w - y)
    guard left < right, top < bottom else { return 0 }
    guard (right - left) * (bottom - top) <= 8 * 1024 * 1024 else { return 2 }
    let sourcePalette = src.paletteCount == 0 ? Data()
      : try memory.data(src.palette, count: src.paletteCount * 4)
    let destinationPalette = dst.paletteCount == 0 ? Data()
      : try memory.data(dst.palette, count: dst.paletteCount * 4)
    let compatible = src.depth == dst.depth && src.scheme == dst.scheme && sourcePalette == destinationPalette
    if compatible && rop == 2 {
      let rowBytes = (right - left) * src.pixelBytes
      var snapshot = Data()
      snapshot.reserveCapacity(rowBytes * (bottom - top))
      for row in top..<bottom {
        _ = try memory.region(bitmapPixelAddress(dst, x + left, y + row), rowBytes)
        snapshot.append(try memory.data(bitmapPixelAddress(src, sourceX + left, sourceY + row), count: rowBytes))
      }
      for row in top..<bottom {
        let start = (row - top) * rowBytes
        try memory.write(bitmapPixelAddress(dst, x + left, y + row),
          data: snapshot.subdata(in: start..<(start + rowBytes)))
      }
      return 0
    }
    // Snapshot the source first: horizontal/vertical self-blits and aliased IDIB storage
    // must not smear pixels. Check every output row before changing the destination.
    var pixels: [UInt32] = []
    pixels.reserveCapacity((right - left) * (bottom - top))
    for row in top..<bottom {
      _ = try memory.region(bitmapPixelAddress(dst, x + left, y + row), (right - left) * dst.pixelBytes)
      for col in left..<right { pixels.append(try bitmapReadPixel(src, sourceX + col, sourceY + row)) }
    }
    var index = 0
    for row in top..<bottom {
      for col in left..<right {
        let value = pixels[index]; index += 1
        if (rop == 4 || rop == 7) && value == src.transparent { continue }
        let native = compatible ? value : try bitmapNative(bitmapRGB(value, src), dst)
        let previous = try bitmapReadPixel(dst, x + col, y + row)
        let result: UInt32
        switch rop {
        case 0: result = previous | native
        case 1: result = previous ^ native
        case 3: result = ~native
        case 5: result = previous | ~native
        case 6: result = previous & ~native
        case 8: result = previous & native
        case 9:
          // Alpha exists in our decoded image storage; ordinary RGB565/IDIBs are opaque.
          var alpha: UInt32 = 255
          if imageBitmaps[src.handle]?.rop == 9 {
            alpha = src.paletteCount > 0 && value < src.paletteCount
              ? try memory.read32(src.palette + value * 4) >> 24 : value >> 24
          }
          if alpha == 0 { continue }
          if alpha == 255 { result = native }
          else {
            let srgb = try bitmapRGB(value, src), drgb = try bitmapRGB(previous, dst)
            var blended: UInt32 = 0
            for shift: UInt32 in [8, 16, 24] {
              let channel = (((srgb >> shift) & 255) * alpha
                + ((drgb >> shift) & 255) * (255 - alpha) + 127) / 255
              blended |= channel << shift
            }
            result = try bitmapNative(blended, dst)
          }
        default: result = native
        }
        try bitmapWritePixel(dst, x + col, y + row, result)
      }
    }
    return 0
  }

  func createWindowsBitmap(_ data: Data) throws -> (handle: UInt32, width: Int, height: Int, colors: UInt32)? {
    guard data.count >= 26, data.count <= 32 * 1024 * 1024, try data.u16(0) == 0x4d42 else { return nil }
    let size = Int(try data.u32(2))
    guard size >= 26, size <= data.count else { return nil }
    let header = try data.u32(14)
    var decoderData = data
    let width: Int, height: Int, colors: UInt32
    if header == 12 {
      width = Int(try data.u16(18)); height = Int(try data.u16(20))
      let bits = try data.u16(24)
      colors = bits <= 8 ? UInt32(1) << bits : 0
    } else if header >= 40 && size >= 54 && header <= size - 14 {
      width = Int(Int32(bitPattern: try data.u32(18)))
      height = abs(Int(Int32(bitPattern: try data.u32(22))))
      let bits = try data.u16(28), declared = try data.u32(46)
      colors = bits <= 8 ? min(declared == 0 ? UInt32(1) << bits : declared, 256) : 0
      // BITMAPINFOHEADER defines biClrUsed == 0 as the full indexed palette.
      // Image I/O rejects some such BMPs when biClrImportant is nonzero.
      // Spell out the equivalent count for the host decoder only; preserve
      // the original guest buffer, palette, pixel indices and importance field.
      if [1, 4, 8].contains(bits), declared == 0 {
        let paletteEnd = 14 + Int(header) + Int(colors) * 4
        guard paletteEnd <= size, Int(try data.u32(10)) >= paletteEnd else { return nil }
        for i in 0..<4 { decoderData[46 + i] = UInt8(truncatingIfNeeded: colors >> (i * 8)) }
      }
    } else { return nil }
    guard width > 0, width <= 8191, height > 0, height <= 65535,
      width * height <= 8 * 1024 * 1024,
      let imageSource = CGImageSourceCreateWithData(decoderData as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
      image.width == width, image.height == height else { return nil }
    var rgba = Data(count: width * height * 4)
    let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
      guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return false }
      context.setBlendMode(.copy)
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard rendered else { return nil }
    let handle = try createCompatibleBitmap(bitmapLayout(bitmap), width: width, height: height)
    guard handle != 0 else { return nil }
    let layout = try bitmapLayout(handle)
    for y in 0..<height {
      var row = Data(count: width * 2)
      for x in 0..<width {
        let p = (y * width + x) * 4
        let pixel = UInt16(rgba[p] >> 3) << 11 | UInt16(rgba[p + 1] >> 2) << 5 | UInt16(rgba[p + 2] >> 3)
        row[x * 2] = UInt8(truncatingIfNeeded: pixel); row[x * 2 + 1] = UInt8(pixel >> 8)
      }
      try memory.write(layout.pixels + UInt32(y * layout.pitch), data: row)
    }
    return (handle, width, height, colors)
  }

  func convertWindowsBitmap() throws {
    let classID = cpu.r[0], source = cpu.r[1], info = cpu.r[2], reallocated = cpu.r[3]
    if info != 0 { _ = try memory.region(info, 10) }
    if reallocated != 0 { _ = try memory.region(reallocated, 1) }
    cpu.r[0] = 0
    if reallocated != 0 { try memory.write8(reallocated, 0) }
    guard classID == 0x0100_4001, source != 0, try memory.read16(source) == 0x4d42 else { return }
    let size = Int(try memory.read32(source + 2))
    guard size >= 26, size <= 32 * 1024 * 1024 else { return }
    let data = try memory.data(source, count: size)
    guard let decoded = try createWindowsBitmap(data) else { return }
    let (handle, width, height, colors) = decoded
    if info != 0 {
      var record = Data(count: 10)
      for (offset, value) in [(0, UInt32(width)), (2, UInt32(height)), (4, colors), (8, UInt32(width))] {
        record[offset] = UInt8(truncatingIfNeeded: value)
        record[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
      }
      try memory.write(info, data: record)
    }
    if reallocated != 0 { try memory.write8(reallocated, 1) }
    convertedBitmaps.insert(handle)
    cpu.r[0] = handle
  }
}
