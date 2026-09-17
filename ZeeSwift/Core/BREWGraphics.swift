import Foundation

extension BREWRuntime {
  private func graphicsRect(_ pointer: UInt32) throws -> SIMD4<Int> {
    _ = try memory.region(pointer, 8)
    return try SIMD4((0..<4).map {
      Int(Int16(truncatingIfNeeded: try memory.read16(pointer + UInt32($0 * 2))))
    })
  }

  private func writeGraphicsRect(_ rect: SIMD4<Int>, _ pointer: UInt32) throws {
    _ = try memory.region(pointer, 8)
    for i in 0..<4 { try memory.write16(pointer + UInt32(i * 2), UInt32(truncatingIfNeeded: rect[i])) }
  }

  private func insetGraphicsRect(_ rect: SIMD4<Int>, _ framed: Bool) -> SIMD4<Int> {
    let border = framed ? 1 : 0
    return SIMD4(rect.x + border, rect.y + border, max(0, rect.z - 2 * border), max(0, rect.w - 2 * border))
  }

  private func intersectGraphicsRects(_ a: SIMD4<Int>, _ b: SIMD4<Int>) -> SIMD4<Int> {
    let x = max(a.x, b.x), y = max(a.y, b.y)
    return SIMD4(x, y, max(0, min(a.x + a.z, b.x + b.z) - x), max(0, min(a.y + a.w, b.y + b.w) - y))
  }

  private var graphicsWindow: SIMD4<Int> {
    insetGraphicsRect(graphicsViewport, graphicsViewportFramed)
  }

  private func graphicsScreenRect(_ rect: SIMD4<Int>) -> SIMD4<Int> {
    let window = graphicsWindow
    return SIMD4(rect.x + window.x - graphicsOrigin.x, rect.y + window.y - graphicsOrigin.y, rect.z, rect.w)
  }

  private var effectiveGraphicsClip: SIMD4<Int> {
    guard let graphicsClip else { return graphicsWindow }
    return intersectGraphicsRects(graphicsWindow,
      graphicsScreenRect(insetGraphicsRect(graphicsClip, graphicsClipFramed)))
  }

  private func paintGraphicsLine(_ line: SIMD4<Int>) throws {
    let layout = try bitmapLayout(graphicsDestination)
    let clip = intersectGraphicsRects(effectiveGraphicsClip, SIMD4(0, 0, layout.width, layout.height))
    guard clip.z > 0, clip.w > 0 else { return }
    let start = graphicsScreenRect(SIMD4(line.x, line.y, 1, 1))
    let end = graphicsScreenRect(SIMD4(line.z, line.w, 1, 1))
    var a = SIMD2(start.x, start.y), b = SIMD2(end.x, end.y)
    let major = abs(b.x - a.x) >= abs(b.y - a.y) ? 0 : 1, minor = 1 - major
    // Canonical endpoint order gives identical coverage when a line is reversed.
    // Round the minor-axis displacement to the nearest pixel, ties away from zero.
    if a[major] > b[major] { swap(&a, &b) }
    let length = b[major] - a[major], delta = b[minor] - a[minor]
    let first = max(0, clip[major] - a[major])
    let last = min(length, clip[major] + clip[major + 2] - 1 - a[major])
    guard first <= last else { return }
    let color = try bitmapNative(graphicsState[0x10, default: 0], layout)
    let xor = graphicsState[0x44, default: 0] == 1
    var points: [SIMD2<Int>] = []
    for step in first...last {
      let distance = length == 0 ? 0 : (2 * abs(delta) * step + length) / (2 * length)
      var point = a
      point[major] += step
      point[minor] += delta < 0 ? -distance : distance
      guard point[minor] >= clip[minor], point[minor] < clip[minor] + clip[minor + 2] else { continue }
      let address = Int64(layout.pixels) + Int64(point.y * layout.pitch + point.x * layout.pixelBytes)
      guard address >= 0, address <= Int64(UInt32.max) else { throw EmulationError.invalid("IGraphics pixel address") }
      _ = try memory.region(UInt32(address), layout.pixelBytes)
      points.append(point)
    }
    for p in points {
      let value = xor ? try bitmapReadPixel(layout, p.x, p.y) ^ color : color
      try bitmapWritePixel(layout, p.x, p.y, value)
    }
  }

  // Rasterization writes actual guest bitmap pixels. IDisplay's own clip is separate.
  private func paintGraphicsRect(_ rect: SIMD4<Int>, clip: SIMD4<Int>, flags: UInt32,
    foreground: UInt32? = nil, fill: UInt32? = nil, copy: Bool = false) throws {
    let layout = try bitmapLayout(graphicsDestination)
    let bounds = intersectGraphicsRects(intersectGraphicsRects(rect, clip), SIMD4(0, 0, layout.width, layout.height))
    guard bounds.z > 0, bounds.w > 0, flags != 0 else { return }
    let border = flags & 2 != 0
    let hasFill = flags & 8 != 0
    let hasClear = flags & 4 != 0
    let fg = try bitmapNative(foreground ?? graphicsState[0x10, default: 0], layout)
    let bg = try bitmapNative(graphicsState[0x08, default: 0xffffff00], layout)
    let inside = try bitmapNative(fill ?? graphicsState[0x20, default: 0], layout)
    // Check every destination row before any mutation, including signed pitches.
    for y in bounds.y..<(bounds.y + bounds.w) {
      let address = Int64(layout.pixels) + Int64(y * layout.pitch + bounds.x * layout.pixelBytes)
      guard address >= 0, address <= Int64(UInt32.max) else { throw EmulationError.invalid("IGraphics pixel address") }
      _ = try memory.region(UInt32(address), bounds.z * layout.pixelBytes)
    }
    for y in bounds.y..<(bounds.y + bounds.w) {
      for x in bounds.x..<(bounds.x + bounds.z) {
        let edge = border && (x == rect.x || y == rect.y || x == rect.x + rect.z - 1 || y == rect.y + rect.w - 1)
        guard edge || hasFill || hasClear else { continue }
        var value = edge ? fg : (hasFill ? inside : bg)
        if !copy, graphicsState[0x44, default: 0] == 1, edge || hasFill {
          let previous = !edge && hasClear ? bg : try bitmapReadPixel(layout, x, y)
          value ^= previous
        }
        try bitmapWritePixel(layout, x, y, value)
      }
    }
  }

  func dispatchGraphics(_ offset: UInt32) throws {
    switch offset {
    case 0: cpu.r[0] = 2
    case 4: cpu.r[0] = 1
    case 0x08, 0x10, 0x20:
      let alpha = offset != 0x08 ? try argument(4) & 255 : 0
      let color = ((cpu.r[1] & 255) << 8) | ((cpu.r[2] & 255) << 16) | ((cpu.r[3] & 255) << 24) | alpha
      graphicsState[offset] = color
      cpu.r[0] = color // The interface setters return the updated RGBVAL.
    case 0x0c, 0x14, 0x24:
      let color = graphicsState[offset - 4, default: offset == 0x0c ? 0xffffff00 : 0]
      let pointers = try (1...(offset != 0x0c ? 4 : 3)).map { try argument($0) }
      for p in pointers { _ = try memory.region(p, 1) }
      for (i, p) in pointers.enumerated() { try memory.write8(p, color >> UInt32((i + 1) % 4 * 8)) }
    case 0x18:
      let fill: UInt32 = cpu.r[1] & 255 == 1 ? 1 : 0
      graphicsState[0x18] = fill
      cpu.r[0] = fill
    case 0x1c: cpu.r[0] = graphicsState[0x18, default: 0]
    case 0x30:
      let pointer = cpu.r[1], flags = cpu.r[2] & 255
      guard flags & ~UInt32(14) == 0 else { cpu.r[0] = 0; return }
      if pointer == 0 {
        graphicsClip = nil
        graphicsClipFramed = false
        cpu.r[0] = 1
        return
      }
      let type = try memory.read8(pointer)
      guard type <= 1 else { cpu.r[0] = 0; return }
      if type == 0 {
        graphicsClip = nil
        graphicsClipFramed = false
        cpu.r[0] = 1
        return
      }
      // ARM AEEClip: int8 type; union aligned to 4 because AEEPolygon holds a pointer.
      let rect = try graphicsRect(pointer + 4)
      let framed = flags & 2 != 0
      guard rect.z >= (framed ? 3 : 1), rect.w >= (framed ? 3 : 1) else { cpu.r[0] = 0; return }
      try paintGraphicsRect(graphicsScreenRect(rect), clip: graphicsWindow, flags: flags)
      graphicsClip = rect
      graphicsClipFramed = framed
      cpu.r[0] = 1
    case 0x34:
      let pointer = cpu.r[1]
      guard pointer != 0 else { cpu.r[0] = 0; return }
      _ = try memory.region(pointer, 16)
      let window = graphicsWindow
      let rect = graphicsClip ?? SIMD4(graphicsOrigin.x, graphicsOrigin.y, window.z, window.w)
      try memory.write(pointer, data: Data(repeating: 0, count: 16))
      try memory.write8(pointer, 1)
      try writeGraphicsRect(rect, pointer + 4)
      cpu.r[0] = 1
    case 0x38:
      let pointer = cpu.r[1], flags = cpu.r[2] & 255
      guard flags & ~UInt32(6) == 0 else { cpu.r[0] = 0; return }
      let layout = try bitmapLayout(graphicsDestination)
      let rect = try pointer == 0 ? SIMD4(0, 0, layout.width, layout.height) : graphicsRect(pointer)
      let framed = pointer != 0 && flags & 2 != 0
      guard rect.x >= 0, rect.y >= 0, rect.z >= (framed ? 3 : 1), rect.w >= (framed ? 3 : 1),
        rect.x + rect.z <= layout.width, rect.y + rect.w <= layout.height else { cpu.r[0] = 0; return }
      try paintGraphicsRect(rect, clip: SIMD4(0, 0, layout.width, layout.height), flags: pointer == 0 ? 0 : flags)
      graphicsViewport = rect
      graphicsViewportFramed = framed
      if pointer == 0 { graphicsClip = nil; graphicsClipFramed = false; graphicsOrigin = .zero }
      cpu.r[0] = 1
    case 0x3c:
      guard cpu.r[1] != 0, cpu.r[2] != 0 else { cpu.r[0] = 0; return }
      _ = try memory.region(cpu.r[1], 8)
      _ = try memory.region(cpu.r[2], 1)
      try writeGraphicsRect(graphicsViewport, cpu.r[1])
      try memory.write8(cpu.r[2], graphicsViewportFramed ? 1 : 0)
      cpu.r[0] = 1
    case 0x40:
      try paintGraphicsRect(graphicsWindow, clip: graphicsWindow, flags: 4, copy: true)
    case 0x44:
      let mode: UInt32 = cpu.r[1] & 255 == 1 ? 1 : 0
      graphicsState[0x44] = mode
      cpu.r[0] = mode
    case 0x48: cpu.r[0] = graphicsState[0x44, default: 0]
    case 0x4c: cpu.r[0] = UInt32(try bitmapLayout(graphicsDestination).depth)
    case 0x54:
      guard cpu.r[1] != 0 else { cpu.r[0] = 14; return }
      try paintGraphicsLine(graphicsRect(cpu.r[1]))
      cpu.r[0] = 0
    case 0x58, 0x78:
      guard cpu.r[1] != 0 else { cpu.r[0] = 14; return }
      let rect = try graphicsRect(cpu.r[1])
      guard rect.z > 0, rect.w > 0 else { cpu.r[0] = 14; return }
      let flags: UInt32 = offset == 0x78 ? 4 : (2 | (graphicsState[0x18, default: 0] == 1 ? 8 : 0))
      try paintGraphicsRect(graphicsScreenRect(rect), clip: effectiveGraphicsClip, flags: flags, copy: offset == 0x78)
      cpu.r[0] = 0
    case 0x7c: cpu.r[0] = cpu.r[1] & 255 == 0 ? 1 : 0 // Double buffering is not implemented.
    case 0x80: break // Update has no effect without double buffering.
    case 0x84:
      graphicsOrigin &+= SIMD2(Int(Int16(truncatingIfNeeded: cpu.r[1])), Int(Int16(truncatingIfNeeded: cpu.r[2])))
    case 0x98:
      let next = cpu.r[1] == 0 ? bitmap : cpu.r[1]
      // Accept destinations supported by the rasterizer. A failed selection must
      // leave the previous destination and its ownership intact.
      guard isNativeBitmap(next) else { cpu.r[0] = 1; return }
      _ = try bitmapLayout(next)
      if next != graphicsDestination {
        try retainBitmap(next)
        let previous = graphicsDestination
        graphicsDestination = next
        try releaseBitmap(previous)
      }
      cpu.r[0] = 0
    case 0x9c: cpu.r[0] = graphicsDestination // Borrowed pointer with no side effects.
    default: throw EmulationError.hle("IGraphics+" + offset.hex, cpu.r[14])
    }
  }
}
