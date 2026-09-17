import CoreGraphics
import CoreText
import Darwin
import Foundation

private enum BREWHostNumbers {
  // One immutable C locale; never change the host process/thread locale.
  static let locale = newlocale(Int32(ZeeSwiftCLocaleMask), "C", nil)
}

// HLE system fonts, not a claim to reproduce Zeebo's original font assets.
// Use the same immutable Core Text faces for drawing and metric queries.
enum BREWHostFonts {
  static let faces: [UInt16: CTFont] = [
    0x8000: CTFontCreateWithName("Helvetica" as CFString, 18, nil),
    0x8001: CTFontCreateWithName("Helvetica-Bold" as CFString, 18, nil),
    0x8002: CTFontCreateWithName("Helvetica" as CFString, 24, nil),
    0x8003: CTFontCreateWithName("Helvetica-Oblique" as CFString, 18, nil),
    0x8004: CTFontCreateWithName("Helvetica-BoldOblique" as CFString, 18, nil),
    0x8005: CTFontCreateWithName("Helvetica-Oblique" as CFString, 24, nil),
  ]
  static func font(_ value: UInt32) -> CTFont? { faces[UInt16(truncatingIfNeeded: value)] }
  static func ascent(_ font: CTFont) -> Int { Int(ceil(CTFontGetAscent(font))) }
  static func descent(_ font: CTFont) -> Int { Int(ceil(CTFontGetDescent(font))) }
}

final class BREWFont {
  var references: UInt32 = 1
  let face: CTFont
  init(_ face: CTFont) { self.face = face }
}

extension BREWRuntime {
  // FONT_STANDARD18B is an SDK fallback font. This is the native HLE face,
  // not an extracted Zeebo TrueType asset.
  func createStandardFont() throws -> UInt32 {
    let handle = try allocate(4), table = hleAddress(0x22000)
    guard handle != 0 else { return 0 }
    for slot in stride(from: UInt32(0), through: 20, by: 4) {
      try memory.write32(table + slot, 0xf0340000 + slot)
    }
    try memory.write32(handle, table)
    fontObjects[handle] = BREWFont(BREWHostFonts.faces[0x8001]!)
    return handle
  }
  func fontString(_ pointer: UInt32, count: Int) throws -> String {
    guard count >= 0, count <= 1_048_576, count == 0 || pointer != 0 else {
      throw EmulationError.invalid("IFont counted text")
    }
    if count == 0 { return "" }
    let data = try memory.data(pointer, count: count * 2)
    let units = stride(from: 0, to: data.count, by: 2).map { UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8 }
    return String(decoding: units, as: UTF16.self)
  }
  func dispatchFont(_ offset: UInt32) throws {
    let handle = cpu.r[0]
    guard let font = fontObjects[handle] else { throw EmulationError.invalid("Released IFont") }
    switch offset {
    case 0: font.references += 1; cpu.r[0] = font.references
    case 4:
      font.references -= 1
      if font.references == 0 { fontObjects.removeValue(forKey: handle); try free(handle) }
      cpu.r[0] = font.references
    case 8:
      guard cpu.r[2] != 0 else { cpu.r[0] = 14; return }
      let supported = [UInt32(0x01000001), 0x01001022].contains(cpu.r[1])
      try memory.write32(cpu.r[2], supported ? handle : 0)
      if supported { font.references += 1 }; cpu.r[0] = supported ? 0 : 3
    case 12:
      let bitmap = cpu.r[1], x = Int(Int32(bitPattern: cpu.r[2])), y = Int(Int32(bitPattern: cpu.r[3]))
      let pointer = try argument(4), count = Int(Int32(bitPattern: try argument(5)))
      let fg = try argument(6), bg = try argument(7), clip = try argument(8), flags = try argument(9)
      guard count >= 0, count <= 1_048_576, clip != 0, count == 0 || pointer != 0 else { cpu.r[0] = 14; return }
      guard isNativeBitmap(bitmap) else { cpu.r[0] = 20; return }
      let string = try fontString(pointer, count: count)
      try drawFont(font.face, string: string, bitmap: bitmap, x: x, y: y, fg: fg, bg: bg, clip: clip, flags: flags)
      cpu.r[0] = 0
    case 16:
      let count = Int(Int32(bitPattern: cpu.r[2])), maximum = Int(Int32(bitPattern: cpu.r[3]))
      let fitsOut = try argument(4), pixelsOut = try argument(5)
      guard count >= 0, count <= 1_048_576, maximum >= 0, fitsOut != 0, pixelsOut != 0,
        count == 0 || cpu.r[1] != 0 else { cpu.r[0] = 14; return }
      _ = try memory.region(fitsOut, 4); _ = try memory.region(pixelsOut, 4)
      let string = try fontString(cpu.r[1], count: count)
      let text = NSAttributedString(string: string, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font.face])
      let typesetter = CTTypesetterCreateWithAttributedString(text)
      var fits = maximum == 0 ? 0 : min(count, CTTypesetterSuggestClusterBreak(typesetter, 0, Double(maximum)))
      func width(_ length: Int) -> Int {
        guard length > 0 else { return 0 }
        return max(0, Int(ceil(CTLineGetTypographicBounds(CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: length)), nil, nil, nil))))
      }
      var pixels = width(fits)
      while fits > 0 && pixels > maximum {
        fits = (string as NSString).rangeOfComposedCharacterSequence(at: fits - 1).location
        pixels = width(fits)
      }
      try memory.write32(fitsOut, UInt32(fits)); try memory.write32(pixelsOut, UInt32(pixels)); cpu.r[0] = 0
    case 20:
      guard cpu.r[2] == 4 else { cpu.r[0] = 20; return }
      guard cpu.r[1] != 0 else { cpu.r[0] = 14; return }
      _ = try memory.region(cpu.r[1], 4)
      try memory.write16(cpu.r[1], UInt32(BREWHostFonts.ascent(font.face)))
      try memory.write16(cpu.r[1] + 2, UInt32(BREWHostFonts.descent(font.face))); cpu.r[0] = 0
    default: throw EmulationError.hle("IFont+" + offset.hex, cpu.r[14])
    }
  }
  func drawFont(_ font: CTFont, string: String, bitmap: UInt32, x: Int, y: Int,
    fg: UInt32, bg: UInt32, clip: UInt32, flags: UInt32) throws {
    guard !string.isEmpty else { return }
    let layout = try bitmapLayout(bitmap)
    let rect = try (0..<4).map { Int(Int16(truncatingIfNeeded: try memory.read16(clip + UInt32($0 * 2)))) }
    guard rect[2] > 0, rect[3] > 0 else { return }
    let text = NSAttributedString(string: string, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)])
    let line = CTLineCreateWithAttributedString(text)
    let textWidth = max(0, Int(ceil(CTLineGetTypographicBounds(line, nil, nil, nil))))
    let ascent = BREWHostFonts.ascent(font), height = ascent + BREWHostFonts.descent(font)
    let left = max(0, rect[0], x), top = max(0, rect[1], y)
    let right = min(layout.width, rect[0] + rect[2], x + textWidth)
    let bottom = min(layout.height, rect[1] + rect[3], y + height)
    guard left < right, top < bottom else { return }
    let w = right - left, h = bottom - top
    guard w * h <= 8 * 1024 * 1024 else { throw EmulationError.invalid("IFont drawing area") }
    var mask = [UInt8](repeating: 0, count: w * h)
    try mask.withUnsafeMutableBytes { bytes in
      guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
        bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { throw EmulationError.unsupported("IFont glyph mask") }
      context.textPosition = CGPoint(x: x - left, y: h - (y - top) - ascent)
      CTLineDraw(line, context)
    }
    let foreground = try bitmapRGB(fg, layout)
    for row in 0..<h {
      for column in 0..<w {
        let alpha = UInt32(mask[row * w + column]), dx = left + column, dy = top + row
        if alpha == 0 {
          if flags & 0x8000 == 0 { try bitmapWritePixel(layout, dx, dy, bg) }
          continue
        }
        if alpha == 255 { try bitmapWritePixel(layout, dx, dy, fg); continue }
        let back = flags & 0x8000 == 0 ? bg : try bitmapReadPixel(layout, dx, dy)
        let background = try bitmapRGB(back, layout)
        var rgb: UInt32 = 0
        for shift in [UInt32(8), 16, 24] {
          rgb |= ((((foreground >> shift) & 255) * alpha + ((background >> shift) & 255) * (255 - alpha) + 127) / 255) << shift
        }
        try bitmapWritePixel(layout, dx, dy, bitmapNative(rgb, layout))
      }
    }
  }

  func duplicateWideString(_ source: UInt32) throws -> UInt32 {
    guard source != 0 else { return 0 }
    var bytes = Data(), terminated = false
    for index in 0..<1_048_576 {
      let address = UInt64(source) + UInt64(index * 2)
      guard address + 2 <= 0x1_0000_0000 else { throw EmulationError.invalid("WSTRDUP address") }
      let unit = try memory.read16(UInt32(address))
      bytes.append(UInt8(truncatingIfNeeded: unit)); bytes.append(UInt8(unit >> 8))
      if unit == 0 { terminated = true; break }
    }
    guard terminated else { throw EmulationError.invalid("WSTRDUP without terminator") }
    let duplicate = try allocate(UInt32(bytes.count))
    if duplicate != 0 { try memory.write(duplicate, data: bytes) }
    return duplicate
  }
  func wideStringToUTF8() throws {
    let source = cpu.r[0], destination = cpu.r[2]
    // AEEStdLib.h: source length is in AECHARs; destination size is in bytes.
    // Convert the counted span. Do not append an uncounted terminator: callers
    // may provide exactly one output byte for a single ASCII AECHAR.
    let count = Int(Int32(bitPattern: cpu.r[1]))
    let capacity = Int(Int32(bitPattern: cpu.r[3]))
    cpu.r[0] = 0
    guard count >= 0, count <= 1_048_576, capacity >= count else { return }
    if count == 0 { cpu.r[0] = 1; return }
    let input = try memory.data(source, count: count * 2)
    func unit(_ index: Int) -> UInt32 {
      UInt32(input[index * 2]) | (UInt32(input[index * 2 + 1]) << 8)
    }
    var output = Data()
    var index = 0
    while index < count {
      var scalar = unit(index)
      index += 1
      if (0xd800...0xdbff).contains(scalar) {
        guard index < count else { return }
        let low = unit(index)
        guard (0xdc00...0xdfff).contains(low) else { return }
        scalar = 0x10000 + ((scalar - 0xd800) << 10) + low - 0xdc00
        index += 1
      } else if (0xdc00...0xdfff).contains(scalar) { return }
      let bytes: [UInt8]
      if scalar < 0x80 { bytes = [UInt8(scalar)] }
      else if scalar < 0x800 {
        bytes = [UInt8(0xc0 | (scalar >> 6)), UInt8(0x80 | (scalar & 0x3f))]
      } else if scalar < 0x10000 {
        bytes = [UInt8(0xe0 | (scalar >> 12)), UInt8(0x80 | ((scalar >> 6) & 0x3f)),
          UInt8(0x80 | (scalar & 0x3f))]
      } else {
        bytes = [UInt8(0xf0 | (scalar >> 18)), UInt8(0x80 | ((scalar >> 12) & 0x3f)),
          UInt8(0x80 | ((scalar >> 6) & 0x3f)), UInt8(0x80 | (scalar & 0x3f))]
      }
      guard bytes.count <= capacity - output.count else { return }
      output.append(contentsOf: bytes)
    }
    // Snapshot input and validate the complete result before touching output,
    // including when guest input and output overlap.
    try memory.write(destination, data: output)
    cpu.r[0] = 1
  }

  func getJulianDate() throws {
    let output = cpu.r[1]
    _ = try memory.region(output, 14)
    // Zero means GETTIMESECONDS(), whose local offset is already included.
    // Explicit nonzero seconds are decoded directly, with no second zone shift.
    let seconds = cpu.r[0] == 0 ? localTimeSeconds : cpu.r[0]
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = Date(timeIntervalSince1970: Double(seconds) + 315_964_800)
    let fields = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
    let values = [fields.year!, fields.month!, fields.day!, fields.hour!, fields.minute!, fields.second!,
      (fields.weekday! + 5) % 7] // AEEDateTime: Monday=0, Sunday=6.
    var bytes = Data()
    for value in values { bytes.append(UInt8(truncatingIfNeeded: value)); bytes.append(UInt8(value >> 8)) }
    try memory.write(output, data: bytes)
  }

  func julianToSeconds() throws {
    let pointer = cpu.r[0]
    _ = try memory.region(pointer, 14)
    let fields = try (0..<6).map { Int(try memory.read16(pointer + UInt32($0 * 2))) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = DateComponents(year: fields[0], month: fields[1], day: fields[2],
      hour: fields[3], minute: fields[4], second: fields[5])
    guard let date = calendar.date(from: components) else {
      throw EmulationError.invalid("JULIANTOSECONDS date")
    }
    let decoded = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    guard [decoded.year, decoded.month, decoded.day, decoded.hour, decoded.minute, decoded.second] == fields.map(Optional.some) else {
      throw EmulationError.invalid("JULIANTOSECONDS date fields")
    }
    // JulianType contains civil fields, not a host-zone timestamp. Its weekday
    // field is redundant and does not participate in the inverse conversion.
    let seconds = date.timeIntervalSince1970 - 315_964_800
    guard seconds >= 0, seconds <= Double(UInt32.max) else {
      throw EmulationError.invalid("JULIANTOSECONDS range")
    }
    cpu.r[0] = UInt32(seconds)
  }

  // Version of this HLE's BREW interface profile, not an OEM firmware/build claim.
  static let brewInterfaceVersion: UInt32 = 0x04000200
  func wideStringCopyN() throws {
    let destination = cpu.r[0], source = cpu.r[2]
    // Despite the cbDest parameter name, the interface specifies AECHAR units.
    let capacity = Int(Int32(bitPattern: cpu.r[1]))
    let sourceLimit = Int(Int32(bitPattern: cpu.r[3]))
    guard capacity >= 0, sourceLimit >= -1 else { throw EmulationError.invalid("WSTRNCOPYN length") }
    guard capacity > 0 else { cpu.r[0] = 0; return }
    let count = min(capacity - 1, sourceLimit == -1 ? capacity - 1 : sourceLimit)
    guard count <= 1_048_576 else { throw EmulationError.invalid("WSTRNCOPYN limit") }
    var bytes = Data()
    for i in 0..<count {
      let unit = try memory.read16(source &+ UInt32(i * 2))
      if unit == 0 { break }
      bytes.append(UInt8(truncatingIfNeeded: unit)); bytes.append(UInt8(unit >> 8))
    }
    let copied = bytes.count / 2
    bytes.append(contentsOf: [0,0])
    // Copy from a snapshot; failed output validation cannot partially modify it.
    try memory.write(destination, data: bytes)
    cpu.r[0] = UInt32(copied)
  }
  func getAEEVersion() throws {
    let output = cpu.r[0], capacity = Int32(bitPattern: cpu.r[1])
    let flags = UInt16(truncatingIfNeeded: cpu.r[2])
    if flags == 8 {
      // AEE_IS_PATCH_PRESENT uses this slot. No OEM patches are installed in HLE.
      cpu.r[0] = 1
      return
    }
    // GAV_MSM is deprecated since BREW 3.0. OEM update/build queries need a
    // separate implementation; never invent device patch/build identifiers.
    guard flags & ~UInt16(3) == 0 else {
      throw EmulationError.unsupported("GETAEEVERSION flags " + UInt32(flags).hex)
    }
    let text = [24,16,8,0].map { String((Self.brewInterfaceVersion >> $0) & 255) }.joined(separator: ".")
    var bytes = Data()
    if flags & 1 != 0 { bytes = Data(text.utf8); bytes.append(0) }
    else {
      for unit in text.utf16 { bytes.append(UInt8(truncatingIfNeeded: unit)); bytes.append(UInt8(unit >> 8)) }
      bytes.append(contentsOf: [0,0])
    }
    if output != 0, Int(capacity) >= bytes.count { try memory.write(output, data: bytes) }
    cpu.r[0] = Self.brewInterfaceVersion
  }
  func displayFontMetrics() throws {
    guard let font = BREWHostFonts.font(cpu.r[1]) else { cpu.r[0] = 1; return }
    let ascentPointer = cpu.r[2], descentPointer = cpu.r[3]
    // Validate both optional int outputs before changing either one.
    if ascentPointer != 0 { _ = try memory.region(ascentPointer, 4) }
    if descentPointer != 0 { _ = try memory.region(descentPointer, 4) }
    let ascent = UInt32(BREWHostFonts.ascent(font)), descent = UInt32(BREWHostFonts.descent(font))
    if ascentPointer != 0 { try memory.write32(ascentPointer, ascent) }
    if descentPointer != 0 { try memory.write32(descentPointer, descent) }
    cpu.r[0] = ascent + descent
  }

  func displayMeasureText() throws {
    let fontID = cpu.r[1], pointer = cpu.r[2], count = Int(Int32(bitPattern: cpu.r[3]))
    let maximum = Int(Int32(bitPattern: try argument(4))), output = try argument(5)
    if output != 0 { _ = try memory.region(output, 4) }
    guard count >= -1, maximum >= -1, let font = BREWHostFonts.font(fontID) else {
      if output != 0 { try memory.write32(output, 0) }
      cpu.r[0] = 0
      return
    }
    let limit = 1_048_576
    guard count <= limit else { throw EmulationError.invalid("MeasureTextEx length") }
    var units: [UInt16] = []
    for i in 0..<(count < 0 ? limit : count) {
      let unit = UInt16(try memory.read16(pointer &+ UInt32(i * 2)))
      if unit == 0 { break }
      units.append(unit)
    }
    guard count >= 0 || units.count < limit else { throw EmulationError.invalid("MeasureTextEx without terminator") }
    let string = String(decoding: units, as: UTF16.self)
    let text = NSAttributedString(string: string,
      attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
    let typesetter = CTTypesetterCreateWithAttributedString(text)
    var fits = units.count
    if maximum >= 0 {
      fits = min(fits, CTTypesetterSuggestClusterBreak(typesetter, 0, Double(maximum)))
    }
    func width(_ length: Int) -> Int {
      guard length > 0 else { return 0 }
      let line = CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: length))
      return max(0, Int(ceil(CTLineGetTypographicBounds(line, nil, nil, nil))))
    }
    var measured = width(fits)
    // Core Text may suggest at least one cluster even when the first glyph is
    // wider than the constraint. BREW must report zero fitting characters there.
    while maximum >= 0 && measured > maximum && fits > 0 {
      fits = (string as NSString).rangeOfComposedCharacterSequence(at: fits - 1).location
      measured = width(fits)
    }
    if output != 0 { try memory.write32(output, UInt32(fits)) }
    cpu.r[0] = UInt32(measured)
  }

  func stringToDouble() throws {
    let source = cpu.r[0], endPointer = cpu.r[1]
    if endPointer != 0 { _ = try memory.region(endPointer, 4) }
    // The interface requires a NUL-terminated byte string. Copy only validated guest
    // bytes; no guest address may be passed to libc as a native pointer.
    let bytes = try memory.stringBytes(source) + Data([0])
    guard let locale = BREWHostNumbers.locale else {
      throw EmulationError.unsupported("C numeric locale unavailable")
    }
    let (value, consumed) = bytes.withUnsafeBytes { raw -> (Double, Int) in
      let start = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
      var end: UnsafeMutablePointer<CChar>?
      let value = strtod_l(start, &end, locale)
      return (value, end.map { start.distance(to: UnsafePointer($0)) } ?? 0)
    }
    if endPointer != 0 { try memory.write32(endPointer, source &+ UInt32(consumed)) }
    // ARM base ABI: a double result occupies r0 (low word) and r1 (high word).
    cpu.r[0] = UInt32(truncatingIfNeeded: value.bitPattern)
    cpu.r[1] = UInt32(truncatingIfNeeded: value.bitPattern >> 32)
  }

  func stringToUnsignedLong() throws {
    let source = cpu.r[0]
    let endPointer = cpu.r[1]
    var base = Int(Int32(bitPattern: cpu.r[2]))
    if endPointer != 0 { _ = try memory.region(endPointer, 4) }
    guard base == 0 || (2...36).contains(base) else {
      if endPointer != 0 { try memory.write32(endPointer, source) }
      cpu.r[0] = 0
      return
    }
    func byte(_ index: Int) throws -> UInt32 {
      guard index < 1_048_576 else { throw EmulationError.invalid("STRTOUL length") }
      return try memory.read8(source &+ UInt32(index))
    }
    func digit(_ value: UInt32) -> Int {
      if (48...57).contains(value) { return Int(value - 48) }
      if (65...90).contains(value) { return Int(value - 65) + 10 }
      if (97...122).contains(value) { return Int(value - 97) + 10 }
      return 36
    }
    var index = 0
    var current = try byte(index)
    while current == 32 || (9...13).contains(current) {
      index += 1
      current = try byte(index)
    }
    let negative = current == 45
    if current == 43 || negative { index += 1; current = try byte(index) }
    if current == 48 && (base == 0 || base == 16) {
      let next = try byte(index + 1)
      if try (next == 120 || next == 88) && digit(byte(index + 2)) < 16 {
        base = 16
        index += 2
        current = try byte(index)
      } else if base == 0 { base = 8 }
    } else if base == 0 { base = 10 }
    var value: UInt64 = 0
    var overflow = false
    var converted = false
    while digit(current) < base {
      converted = true
      if !overflow {
        value = value * UInt64(base) + UInt64(digit(current))
        overflow = value > UInt64(UInt32.max)
      }
      index += 1
      current = try byte(index)
    }
    if endPointer != 0 { try memory.write32(endPointer, converted ? source &+ UInt32(index) : source) }
    let result = overflow ? UInt32.max : UInt32(value)
    cpu.r[0] = negative && !overflow ? 0 &- result : result
  }

  func boundedStringCopy(_ operation: UInt32) throws {
    let destination = cpu.r[0]
    let source = cpu.r[1]
    let capacity = Int(cpu.r[2])
    let wide = operation >= 0x154
    let append = operation == 0x150 || operation == 0x158
    let stride = wide ? 2 : 1
    let limit = 1_048_576
    func unit(_ address: UInt32, _ index: Int) throws -> UInt32 {
      guard index < limit else { throw EmulationError.invalid("STRL length") }
      return try wide ? memory.read16(address &+ UInt32(index * stride))
        : memory.read8(address &+ UInt32(index))
    }
    // Read before writing, and retain code units exactly rather than round-tripping Unicode.
    var sourceLength = 0
    while try unit(source, sourceLength) != 0 { sourceLength += 1 }
    var destinationLength = 0
    if append {
      while try destinationLength < capacity && unit(destination, destinationLength) != 0 {
        destinationLength += 1
      }
    }
    if destinationLength < capacity {
      let copied = min(sourceLength, capacity - destinationLength - 1)
      var bytes = copied > 0 ? try memory.data(source, count: copied * stride) : Data()
      bytes.append(contentsOf: wide ? [0, 0] : [0])
      try memory.write(destination &+ UInt32(destinationLength * stride), data: bytes)
    }
    cpu.r[0] = UInt32(truncatingIfNeeded: destinationLength + sourceLength)
  }

  func wideStringCall(_ operation: UInt32) throws {
    let first = cpu.r[0]
    let second = cpu.r[1]
    let limit = 1_048_576
    func length(_ pointer: UInt32) throws -> Int {
      for i in 0..<limit {
        if try memory.read16(pointer &+ UInt32(i * 2)) == 0 { return i }
      }
      throw EmulationError.invalid("WSTR length")
    }
    switch operation {
    case 0x24, 0x28:  // WSTRCPY / WSTRCAT preserve raw AECHAR units, including non-Latin text.
      let count = try length(second)
      let bytes = try memory.data(second, count: (count + 1) * 2)
      let append = operation == 0x28 ? try length(first) : 0
      try memory.write(first &+ UInt32(append * 2), data: bytes)
      cpu.r[0] = first
    case 0x2c:
      for i in 0..<limit {
        let a = try memory.read16(first &+ UInt32(i * 2))
        let b = try memory.read16(second &+ UInt32(i * 2))
        if a != b || a == 0 {
          cpu.r[0] = UInt32(bitPattern: Int32(a) - Int32(b))
          return
        }
      }
      throw EmulationError.invalid("WSTRCMP length")
    case 0x30:
      cpu.r[0] = UInt32(try length(first))
    case 0x34, 0x38:
      let character = second & 0xffff
      var found: UInt32 = 0
      for i in 0..<limit {
        let address = first &+ UInt32(i * 2)
        let unit = try memory.read16(address)
        if unit == character {
          found = address
          if operation == 0x34 { cpu.r[0] = address; return }
        }
        if unit == 0 { cpu.r[0] = found; return }
      }
      throw EmulationError.invalid("WSTRCHR length")
    case 0x44:
      let capacity = Int(Int32(bitPattern: cpu.r[2]))
      guard capacity >= 0 else { throw EmulationError.invalid("WSTRTOSTR length") }
      if capacity > 0 {
        var source = first
        // A leading UTF-16 BOM marks encoded input; Alpine's language file retains it.
        // Do not read the input when there is room only for the output terminator.
        if capacity > 1, try memory.read16(source) == 0xfeff { source &+= 2 }
        var bytes = Data()
        for i in 0..<min(capacity - 1, limit) {
          let unit = try memory.read16(source &+ UInt32(i * 2))
          if unit == 0 { break }
          // The game's version/localized strings use Latin-1. Other code pages remain explicit.
          guard unit <= 255 else { throw EmulationError.unsupported("WSTRTOSTR outside Latin-1") }
          bytes.append(UInt8(unit))
        }
        guard bytes.count < limit else { throw EmulationError.invalid("WSTRTOSTR length") }
        bytes.append(0)
        try memory.write(second, data: bytes)
      }
      cpu.r[0] = second
    default: throw EmulationError.invalid("WSTR helper")
    }
  }

  func resourceFile(_ filename: UInt32) throws -> BREWResourceFile? {
    // ISHELL_GetAppVersion/Author/Copyright select the active MIF with NULL.
    if filename == 0 { return package.resources }
    let name = try memory.string(filename)
    guard let path = try? filePath(name), fileKind(path) == .file else { return nil }
    let overlay = savedFiles[path]
    if let cached = resourceFileCache, cached.path == path, cached.overlay == overlay {
      return cached.file
    }
    guard let bytes = try fileContents(path), let decoded = try? BREWResourceFile(bytes) else {
      return nil
    }
    // One cached BAR at most; replacements and tombstones are checked on every lookup.
    resourceFileCache = bytes.count <= 32 * 1024 * 1024 ? (path, overlay, decoded) : nil
    return decoded
  }

  func loadResourceData(extended: Bool) throws {
    let filename = cpu.r[1]
    let id = UInt16(truncatingIfNeeded: cpu.r[2])
    let type = UInt16(truncatingIfNeeded: cpu.r[3])  // ResType is int16 in the ARM ABI.
    let output = extended ? try argument(4) : 0
    let sizePointer = extended ? try argument(5) : 0
    if extended {
      guard sizePointer != 0 else { cpu.r[0] = 0; return }
      _ = try memory.region(sizePointer, 4)
    }
    let capacity = output != 0 && output != UInt32.max ? try memory.read32(sizePointer) : 0
    guard let file = try resourceFile(filename), let bytes = file.resource(type: type, id: id)
    else {
      let name = filename == 0 ? "<active MIF>" : try memory.string(filename)
      log.append("Resource unavailable: \(name), type \(type), id \(id)")
      if extended { try memory.write32(sizePointer, 0) }
      cpu.r[0] = 0
      return
    }
    let count = UInt32(bytes.count)
    if output == UInt32.max {  // Documented size-only query; no guest heap allocation.
      try memory.write32(sizePointer, count)
      cpu.r[0] = UInt32.max
      // R3 is caller-saved under AAPCS. Use the byte count as this HLE's scratch result:
      // Peggle's resource wrapper spills it into the next call's capacity slot. The interface
      // does not promise R3's value; this is a compatibility convention, not hardware proof.
      cpu.r[3] = count
      return
    }
    if output != 0 && capacity < count {
      try memory.write32(sizePointer, count)
      cpu.r[0] = 0
      return
    }
    if output != 0 && !bytes.isEmpty { _ = try memory.region(output, bytes.count) }
    let destination = output == 0 ? try allocate(max(1, count)) : output
    guard destination != 0 else {
      if extended { try memory.write32(sizePointer, 0) }
      cpu.r[0] = 0
      return
    }
    if !bytes.isEmpty { try memory.write(destination, data: bytes) }
    if extended { try memory.write32(sizePointer, count) }
    cpu.r[0] = destination
  }

  func loadResourceString() throws {
    let filename = cpu.r[1]
    let id = UInt16(truncatingIfNeeded: cpu.r[2])
    let output = cpu.r[3]
    let capacity = Int(Int32(bitPattern: try argument(4))) / 2
    guard output != 0, capacity > 0 else {
      cpu.r[0] = 0
      return
    }
    guard let file = try resourceFile(filename), let units = file.stringUnits(id: id) else {
      cpu.r[0] = 0
      return
    }
    let copied = units.prefix(capacity - 1)
    var bytes = Data(capacity: (copied.count + 1) * 2)
    for unit in copied { bytes.append(UInt8(truncatingIfNeeded: unit)); bytes.append(UInt8(unit >> 8)) }
    bytes.append(contentsOf: [0, 0])
    // One checked write: a bad destination cannot leave a partially written string.
    try memory.write(output, data: bytes)
    cpu.r[0] = UInt32(copied.count)
  }

  /// HLE text uses host fonts; original Zeebo fonts and custom IFont objects remain incomplete.
  func drawText() throws {
    let font = BREWHostFonts.font(cpu.r[1]) ?? BREWHostFonts.faces[0x8000]!
    let layout = try bitmapLayout(displayDestination)
    let bounds = try currentDisplayClip()
    let width = layout.width, height = layout.height
    var units: [UInt16] = []
    let count = cpu.r[3] == UInt32.max ? 4096 : min(4096, Int(cpu.r[3]))
    for i in 0..<count {
      let value = UInt16(try memory.read16(cpu.r[2] + UInt32(i * 2)))
      if value == 0 { break }
      units.append(value)
    }
    let string = String(decoding: units, as: UTF16.self)
    log.append("Game text: " + string)
    var x = Int(Int32(bitPattern: try memory.read32(cpu.r[13])))
    var y = Int(Int32(bitPattern: try memory.read32(cpu.r[13] + 4)))
    let rect = try memory.read32(cpu.r[13] + 8)
    let flags = try memory.read32(cpu.r[13] + 12)
    var alignment = SIMD4(0, 0, width, height)
    var clip = CGRect(x: bounds.x, y: height - bounds.y - bounds.w, width: bounds.z, height: bounds.w)
    if rect != 0 {
      let rx = Int(Int16(truncatingIfNeeded: try memory.read16(rect)))
      let ry = Int(Int16(truncatingIfNeeded: try memory.read16(rect + 2)))
      let rw = Int(Int16(truncatingIfNeeded: try memory.read16(rect + 4)))
      let rh = Int(Int16(truncatingIfNeeded: try memory.read16(rect + 6)))
      // AEEIDisplay: x/y are bitmap coordinates, not offsets into prcBackground.
      // That rectangle supplies clipping and optional alignment only.
      alignment = SIMD4(rx, ry, max(0, rw), max(0, rh))
      clip = clip.intersection(CGRect(x: rx, y: height - ry - rh, width: max(0, rw), height: max(0, rh)))
    }
    guard width > 0, height > 0, width * height <= 8 * 1024 * 1024 else { return }
    var pixels = [UInt32](repeating: 0, count: width * height)
    for i in pixels.indices {
      let rgb = try bitmapRGB(bitmapReadPixel(layout, i % width, i / width), layout)
      pixels[i] = 0xff00_0000 | (rgb & 0xff00) << 8 | (rgb >> 8) & 0xff00 | rgb >> 24
    }
    try pixels.withUnsafeMutableBytes { bytes in
      guard
        let context = CGContext(
          data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
      else { throw EmulationError.unsupported("Text framebuffer") }
      let color = graphicsState[0x2801, default: 0]
      let foreground = CGColor(
        red: CGFloat((color >> 8) & 255) / 255, green: CGFloat((color >> 16) & 255) / 255,
        blue: CGFloat((color >> 24) & 255) / 255, alpha: 1)
      let text = NSAttributedString(
        string: string,
        attributes: [
          NSAttributedString.Key(kCTFontAttributeName as String): font,
          NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground,
        ])
      let line = CTLineCreateWithAttributedString(text)
      let textWidth = Int(ceil(CTLineGetTypographicBounds(line, nil, nil, nil)))
      let textHeight = BREWHostFonts.ascent(font) + BREWHostFonts.descent(font)
      switch flags & 0xf0 {
      case 0x10: x = alignment.x
      case 0x20: x = alignment.x + (alignment.z - textWidth) / 2
      case 0x40: x = alignment.x + alignment.z - textWidth
      default: break
      }
      switch flags & 0xf00 {
      case 0x100: y = alignment.y
      case 0x200: y = alignment.y + (alignment.w - textHeight) / 2
      case 0x400: y = alignment.y + alignment.w - textHeight
      default: break
      }
      context.clip(to: clip)
      context.textPosition = CGPoint(x: x, y: height - y - BREWHostFonts.ascent(font))
      CTLineDraw(line, context)
    }
    for i in pixels.indices {
      let v = pixels[i]
      let rgb = (v & 255) << 24 | (v & 0xff00) << 8 | (v >> 8) & 0xff00
      try bitmapWritePixel(layout, i % width, i / width, bitmapNative(rgb, layout))
    }
  }
}
