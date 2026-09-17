import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
  case system
  case english = "en"
  case german = "de"
  case romanian = "ro"

  static let storageKey = "appLanguage"
  static let supportedCodes = ["en", "de", "ro"]

  var id: String { rawValue }

  var label: String {
    switch self {
    case .system: L10n.text("System Default")
    case .english: L10n.text("English")
    case .german: L10n.text("German")
    case .romanian: L10n.text("Romanian")
    }
  }

  var locale: Locale { Locale(identifier: resolvedCode) }

  var resolvedCode: String {
    if self != .system { return rawValue }
    for identifier in Locale.preferredLanguages {
      let code = Locale(identifier: identifier).language.languageCode?.identifier ?? ""
      if Self.supportedCodes.contains(code) { return code }
    }
    return "en"
  }

  static var selected: AppLanguage {
    let value = UserDefaults.standard.string(forKey: storageKey) ?? AppLanguage.system.rawValue
    return AppLanguage(rawValue: value) ?? .system
  }
}

enum L10n {
  static var locale: Locale { AppLanguage.selected.locale }

  static func text(_ key: String) -> String {
    localizedBundle.localizedString(forKey: key, value: key, table: nil)
  }

  static func format(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: text(key), locale: locale, arguments: arguments)
  }

  private static var localizedBundle: Bundle {
    let code = AppLanguage.selected.resolvedCode
    guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
      let bundle = Bundle(path: path) else { return .main }
    return bundle
  }
}

enum EmulationError: Error, LocalizedError {
  case invalid(String)
  case unsupported(String)
  case memory(UInt32, Int)
  case instruction(UInt32, UInt32, Bool)
  case hle(String, UInt32)
  case budget(UInt32)
  case cancelled
  case guestExit(UInt32)
  case appletClosed
  var errorDescription: String? {
    switch self {
    case .invalid(let s): return L10n.format("Invalid file: %@", s)
    case .unsupported(let s): return L10n.format("Not supported yet: %@", s)
    case .memory(let a, let n):
      return L10n.format("Guest memory access outside a region: %@ (%lld bytes)", a.hex, n)
    case .instruction(let pc, let op, let thumb):
      return L10n.format("Unimplemented %@ instruction %@ at %@", thumb ? "Thumb" : "ARM", op.hex, pc.hex)
    case .hle(let s, let pc): return L10n.format("Missing HLE call: %@, return address %@", s, pc.hex)
    case .budget(let pc): return L10n.format("Execution budget reached at %@", pc.hex)
    case .cancelled: return L10n.text("Emulation stopped")
    case .guestExit(let reason): return L10n.format("Guest exited (ARM semihosting, reason %@)", reason.hex)
    case .appletClosed: return L10n.text("Game ended")
    }
  }
}
/// The UI may request cancellation; only the guest queue ever touches guest state.
final class EmulationCancellation: @unchecked Sendable {
  private let lock = NSCondition()
  private var cancelled = false
  func cancel() {
    lock.lock()
    cancelled = true
    lock.broadcast()
    lock.unlock()
  }
  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
  func check() throws {
    if isCancelled { throw EmulationError.cancelled }
  }
  func wait(milliseconds: UInt32) throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(milliseconds) * 1_000_000
    lock.lock()
    defer { lock.unlock() }
    if cancelled { throw EmulationError.cancelled }
    guard milliseconds != 0 else { return }
    // Ordinary timed condition waits are coalesced by macOS (about 7 ms late on
    // the measured host). A strict one-shot wakes the condition at the original
    // monotonic deadline; cancellation still broadcasts immediately to all waiters.
    let timer = DispatchSource.makeTimerSource(flags: .strict,
      queue: DispatchQueue.global(qos: .userInitiated))
    timer.setEventHandler { [self] in
      lock.lock()
      lock.broadcast()
      lock.unlock()
    }
    timer.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline), leeway: .nanoseconds(0))
    timer.activate()
    defer { timer.cancel() }
    while !cancelled {
      let now = DispatchTime.now().uptimeNanoseconds
      if now >= deadline { return }
      // Other waits on this token may wake us; never return before our deadline.
      lock.wait()
    }
    throw EmulationError.cancelled
  }
}
extension UInt32 { var hex: String { String(format: "0x%08X", self) } }
extension Data {
  func checked(_ offset: Int, _ length: Int) throws -> Data {
    guard offset >= 0, length >= 0, offset <= count, length <= count - offset else {
      throw EmulationError.invalid("File bounds")
    }
    return subdata(in: offset..<(offset + length))
  }
  func u16(_ o: Int) throws -> UInt16 {
    guard o >= 0, o <= count, 2 <= count - o else { throw EmulationError.invalid("16-bit field") }
    return UInt16(self[o]) | UInt16(self[o + 1]) << 8
  }
  func u32(_ o: Int) throws -> UInt32 { UInt32(try u16(o)) | UInt32(try u16(o + 2)) << 16 }
}
