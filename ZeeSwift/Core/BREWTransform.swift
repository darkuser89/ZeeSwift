import Foundation

final class BREWBitmapTransform {
  let destination: UInt32
  var references: UInt32 = 1
  init(destination: UInt32) { self.destination = destination }
}

extension BREWRuntime {
  func queryBitmapTransform(_ destination: UInt32, output: UInt32) throws -> UInt32 {
    guard output != 0 else { return 14 }
    _ = try memory.region(output, 4)
    try memory.write32(output, 0)
    // Device and compatible bitmaps expose ITransform; decoded DIBs do not.
    guard destination == bitmap || imageBitmaps[destination]?.supportsTransform == true else { return 3 }
    if let existing = bitmapTransforms.first(where: { $0.value.destination == destination }) {
      existing.value.references += 1
      try memory.write32(output, existing.key)
      return 0
    }
    let handle = try allocate(4)
    guard handle != 0 else { return 2 }
    let table = hleAddress(0x20b00)
    for offset in stride(from: UInt32(0), through: 0x10, by: 4) {
      try memory.write32(table + offset, 0xf0200000 + offset)
    }
    try memory.write32(handle, table)
    try retainBitmap(destination)
    bitmapTransforms[handle] = BREWBitmapTransform(destination: destination)
    try memory.write32(output, handle)
    return 0
  }

  func dispatchBitmapTransform(_ offset: UInt32) throws {
    let handle = cpu.r[0]
    guard let object = bitmapTransforms[handle] else { throw EmulationError.invalid("Released ITransform") }
    switch offset {
    case 0: object.references += 1; cpu.r[0] = object.references
    case 4:
      object.references -= 1
      cpu.r[0] = object.references
      if object.references == 0 {
        bitmapTransforms.removeValue(forKey: handle)
        try releaseBitmap(object.destination)
        try free(handle)
      }
    case 8:
      let cls = cpu.r[1], output = cpu.r[2]
      guard output != 0 else { cpu.r[0] = 14; return }
      _ = try memory.region(output, 4)
      var result: UInt32 = 0
      if cls == 0x01000001 || cls == 0x01001029 {
        object.references += 1; result = handle
      } else if cls == 0x01001021 {
        try retainBitmap(object.destination); result = object.destination
      }
      try memory.write32(output, result)
      cpu.r[0] = result == 0 ? 3 : 0
    case 0x0c, 0x10:
      let parameter = try argument(8)
      let matrix: SIMD4<Double>
      if offset == 0x0c {
        let flags = parameter & 0xffff
        let scales: [Double] = [1, 2, 4, 8, 0, 0.125, 0.25, 0.5]
        let scale = scales[Int((flags >> 3) & 7)]
        guard flags & ~UInt32(63) == 0, scale != 0 else { cpu.r[0] = 20; return }
        // Screen coordinates have downward Y. Flip over the X axis first,
        // then rotate counter-clockwise, as defined by AEEITransform.h.
        let flip = flags & 4 == 0 ? 1.0 : -1.0
        switch flags & 3 {
        case 0: matrix = SIMD4(scale, 0, 0, scale * flip)
        case 1: matrix = SIMD4(0, scale * flip, -scale, 0)
        case 2: matrix = SIMD4(-scale, 0, 0, -scale * flip)
        default: matrix = SIMD4(0, -scale * flip, scale, 0)
        }
      } else {
        guard parameter != 0 else { cpu.r[0] = 14; return }
        _ = try memory.region(parameter, 8)
        matrix = try SIMD4((0..<4).map {
          Double(Int16(truncatingIfNeeded: try memory.read16(parameter + UInt32($0 * 2)))) / 256
        })
      }
      cpu.r[0] = try transformBitmap(destination: object.destination, source: cpu.r[3],
        x: Int(Int32(bitPattern: cpu.r[1])), y: Int(Int32(bitPattern: cpu.r[2])),
        sourceX: Int(Int32(bitPattern: argument(4))), sourceY: Int(Int32(bitPattern: argument(5))),
        width: Int(argument(6)), height: Int(argument(7)), matrix: matrix,
        keyed: argument(9) & 255 == 0)
    default: throw EmulationError.hle("ITransform+" + offset.hex, cpu.r[14])
    }
  }

  func transformBitmap(destination: UInt32, source: UInt32, x: Int, y: Int,
    sourceX: Int, sourceY: Int, width: Int, height: Int, matrix: SIMD4<Double>, keyed: Bool) throws -> UInt32 {
    guard width > 0, height > 0 else { return 0 }
    guard width <= 65535, height <= 65535, isNativeBitmap(source), isNativeBitmap(destination) else { return 20 }
    let a = matrix.x, b = matrix.y, c = matrix.z, d = matrix.w, determinant = matrix.x * matrix.w - matrix.y * matrix.z
    guard determinant != 0, matrix.x.isFinite, matrix.y.isFinite, matrix.z.isFinite, matrix.w.isFinite else { return 20 }
    let src = try bitmapLayout(source), dst = try bitmapLayout(destination)
    let sx0 = max(0, sourceX), sy0 = max(0, sourceY)
    let sx1 = min(src.width, sourceX + width), sy1 = min(src.height, sourceY + height)
    guard sx0 < sx1, sy0 < sy1 else { return 0 }
    let w = Double(width), h = Double(height), centerX = Double(x) + w / 2, centerY = Double(y) + h / 2
    let halfX = (abs(a) * w + abs(b) * h) / 2, halfY = (abs(c) * w + abs(d) * h) / 2
    let left = Int(max(0, min(Double(dst.width), floor(centerX - halfX))))
    let right = Int(max(0, min(Double(dst.width), ceil(centerX + halfX))))
    let top = Int(max(0, min(Double(dst.height), floor(centerY - halfY))))
    let bottom = Int(max(0, min(Double(dst.height), ceil(centerY + halfY))))
    guard left < right, top < bottom else { return 0 }

    func checkedRows(_ layout: BREWBitmapLayout, _ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int)
      throws -> (GuestMemory.Region, UInt32, Int) {
      let first = Int64(layout.pixels) + Int64(y0 * layout.pitch + x0 * layout.pixelBytes)
      let last = Int64(layout.pixels) + Int64((y1 - 1) * layout.pitch + x0 * layout.pixelBytes)
      let start = min(first, last), end = max(first, last) + Int64((x1 - x0) * layout.pixelBytes)
      guard start >= 0, end <= 0x100000000 else { throw EmulationError.invalid("ITransform-Pixelbereich") }
      return (try memory.region(UInt32(start), Int(end-start)), UInt32(start), Int(end-start))
    }
    let (srcRegion, _, _) = try checkedRows(src, sx0, sx1, sy0, sy1)
    let (dstRegion, writeStart, writeSize) = try checkedRows(dst, left, right, top, bottom)
    let sameFormat = src.depth == dst.depth && src.scheme == dst.scheme && src.paletteCount == 0 && dst.paletteCount == 0
    // Snapshot before any write: overlapping transforms must not read pixels
    // already overwritten. Preconversion also makes errors atomic.
    let copyWidth = sx1 - sx0
    guard copyWidth * (sy1-sy0) <= 8 * 1024 * 1024 else { return 20 }
    var pixels = [UInt64](repeating: 0, count: copyWidth * (sy1-sy0))
    for row in sy0..<sy1 {
      let rowOffset = Int(src.pixels) - Int(srcRegion.base) + row * src.pitch
      for col in sx0..<sx1 {
        let pointer = srcRegion.bytes.advanced(by: rowOffset + col * src.pixelBytes)
        let value: UInt32
        switch src.depth {
        case 8: value = UInt32(pointer.load(as: UInt8.self))
        case 16: value = UInt32(pointer.loadUnaligned(as: UInt16.self).littleEndian)
        case 24:
          value = UInt32(pointer.load(as: UInt8.self))
            | (UInt32(pointer.load(fromByteOffset: 1, as: UInt8.self)) << 8)
            | (UInt32(pointer.load(fromByteOffset: 2, as: UInt8.self)) << 16)
        default: value = pointer.loadUnaligned(as: UInt32.self).littleEndian
        }
        let native = try sameFormat ? value : bitmapNative(bitmapRGB(value, src), dst)
        pixels[(row-sy0)*copyWidth + col-sx0] = keyed && value == src.transparent ? 0x100000000 : UInt64(native)
      }
    }
    // Inverse-map destination pixel centers; nearest-neighbor sampling preserves
    // exact palette/key colors. No filtering behavior is specified by the interface.
    for row in top..<bottom {
      let dy = Double(row) + 0.5 - centerY
      let rowOffset = Int(dst.pixels) - Int(dstRegion.base) + row * dst.pitch
      for col in left..<right {
        let dx = Double(col) + 0.5 - centerX
        let u = (d * dx - b * dy) / determinant + w / 2
        let v = (-c * dx + a * dy) / determinant + h / 2
        guard u >= 0, u < w, v >= 0, v < h else { continue }
        let sx = sourceX + Int(floor(u)), sy = sourceY + Int(floor(v))
        guard sx >= sx0, sx < sx1, sy >= sy0, sy < sy1 else { continue }
        let value = pixels[(sy-sy0)*copyWidth + sx-sx0]
        guard value <= UInt32.max else { continue }
        let pointer = dstRegion.bytes.advanced(by: rowOffset + col * dst.pixelBytes)
        switch dst.depth {
        case 8: pointer.storeBytes(of: UInt8(truncatingIfNeeded: value), as: UInt8.self)
        case 16:
          var word = UInt16(truncatingIfNeeded: value).littleEndian
          withUnsafeBytes(of: &word) { pointer.copyMemory(from: $0.baseAddress!, byteCount: 2) }
        case 24:
          for channel in 0..<3 {
            pointer.storeBytes(of: UInt8(truncatingIfNeeded: value >> (channel * 8)),
              toByteOffset: channel, as: UInt8.self)
          }
        default:
          var word = UInt32(truncatingIfNeeded: value).littleEndian
          withUnsafeBytes(of: &word) { pointer.copyMemory(from: $0.baseAddress!, byteCount: 4) }
        }
      }
    }
    dstRegion.didWrite(writeStart, count: writeSize)
    return 0
  }
}
