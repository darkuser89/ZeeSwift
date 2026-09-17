import Foundation

enum MetalFXMode: Int, CaseIterable, Identifiable {
  case off = 0, spatial = 1, temporal = 2
  var id: Int { rawValue }
}

struct MetalFXPreferences {
  private let defaults: UserDefaults
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }
  private func key(_ classID: UInt32?) -> String {
    classID.map { "metalFX.\($0)" } ?? "metalFX.global"
  }
  func override(for classID: UInt32) -> MetalFXMode? {
    (defaults.object(forKey: key(classID)) as? Int).flatMap(MetalFXMode.init(rawValue:))
  }
  func mode(for classID: UInt32? = nil) -> MetalFXMode {
    if let classID, let mode = override(for: classID) { return mode }
    return MetalFXMode(rawValue: defaults.integer(forKey: key(nil))) ?? .off
  }
  func set(_ mode: MetalFXMode?, for classID: UInt32? = nil) {
    if let mode { defaults.set(mode.rawValue, forKey: key(classID)) }
    else { defaults.removeObject(forKey: key(classID)) }
  }
}

/// Host rendering preference. Guest EGL dimensions and memory layouts stay native.
enum RenderResolution: Int, CaseIterable, Identifiable {
  case native = 1, double = 2, triple = 3, quadruple = 4
  var id: Int { rawValue }
  var width: Int { 640 * rawValue }
  var height: Int { 480 * rawValue }
  var label: String { "\(rawValue)× · \(width) × \(height)" }
}

struct RenderResolutionPreferences {
  private let defaults: UserDefaults
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }
  private func key(_ classID: UInt32?) -> String {
    classID.map { "renderResolution.\($0)" } ?? "renderResolution.global"
  }
  func override(for classID: UInt32) -> RenderResolution? {
    RenderResolution(rawValue: defaults.integer(forKey: key(classID)))
  }
  func resolution(for classID: UInt32? = nil) -> RenderResolution {
    if let classID, let value = override(for: classID) { return value }
    return RenderResolution(rawValue: defaults.integer(forKey: key(nil))) ?? .native
  }
  func set(_ resolution: RenderResolution?, for classID: UInt32? = nil) {
    if let resolution { defaults.set(resolution.rawValue, forKey: key(classID)) }
    else { defaults.removeObject(forKey: key(classID)) }
  }
}

/// Preserve existing per-game keys, including an explicit false override.
struct PixelScalingPreferences {
  private let defaults: UserDefaults
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }
  private func key(_ classID: UInt32?) -> String {
    classID.map { "pixelExactMagnification.\($0)" } ?? "pixelExactMagnification.global"
  }
  func override(for classID: UInt32) -> Bool? {
    defaults.object(forKey: key(classID)) as? Bool
  }
  func enabled(for classID: UInt32? = nil) -> Bool {
    if let classID, let value = override(for: classID) { return value }
    return defaults.bool(forKey: key(nil))
  }
  func set(_ enabled: Bool?, for classID: UInt32? = nil) {
    if let enabled { defaults.set(enabled, forKey: key(classID)) }
    else { defaults.removeObject(forKey: key(classID)) }
  }
}

/// Presentation only: stretching never changes guest pixels or internal resolution.
enum WindowScaling: Int, CaseIterable, Identifiable {
  case preserveAspect = 0, fill = 1
  var id: Int { rawValue }
}

/// Keeps a 4:3 game surface flush with a resizable window while allowing fixed
/// interface chrome (for example the embedded player's toolbar) above it.
struct GameWindowAspectSizing {
  static let ratio: CGFloat = 4 / 3
  static func fittedContentSize(current: CGSize, game: CGSize,
    previous: CGSize? = nil, preferGameHeight: Bool = false) -> CGSize {
    guard current.width > 0, current.height > 0, game.width > 0, game.height > 0 else {
      return current
    }
    let horizontalChrome = max(0, current.width - game.width)
    let verticalChrome = max(0, current.height - game.height)
    let widthLeads: Bool
    if preferGameHeight {
      widthLeads = false
    } else if let previous {
      let widthChange = abs(current.width - previous.width)
      let heightChange = abs(current.height - previous.height)
      widthLeads = widthChange >= heightChange * ratio
    } else {
      widthLeads = true
    }
    if widthLeads {
      let gameWidth = max(1, current.width - horizontalChrome)
      return CGSize(width: current.width, height: gameWidth / ratio + verticalChrome)
    }
    let gameHeight = max(1, current.height - verticalChrome)
    return CGSize(width: gameHeight * ratio + horizontalChrome, height: current.height)
  }
}

struct WindowScalingPreferences {
  private let defaults: UserDefaults
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }
  private func key(_ classID: UInt32?) -> String {
    classID.map { "windowScaling.\($0)" } ?? "windowScaling.global"
  }
  func override(for classID: UInt32) -> WindowScaling? {
    (defaults.object(forKey: key(classID)) as? Int).flatMap(WindowScaling.init(rawValue:))
  }
  func mode(for classID: UInt32? = nil) -> WindowScaling {
    if let classID, let mode = override(for: classID) { return mode }
    return WindowScaling(rawValue: defaults.integer(forKey: key(nil))) ?? .preserveAspect
  }
  func set(_ mode: WindowScaling?, for classID: UInt32? = nil) {
    if let mode { defaults.set(mode.rawValue, forKey: key(classID)) }
    else { defaults.removeObject(forKey: key(classID)) }
  }
}

/// Sample count is fixed for a running guest, like internal render resolution.
enum MSAA: Int, CaseIterable, Identifiable {
  case off = 1, x2 = 2, x4 = 4
  var id: Int { rawValue }
}

struct MSAAPreferences {
  private let defaults: UserDefaults
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }
  private func key(_ classID: UInt32?) -> String {
    classID.map { "msaa.\($0)" } ?? "msaa.global"
  }
  func override(for classID: UInt32) -> MSAA? {
    (defaults.object(forKey: key(classID)) as? Int).flatMap(MSAA.init(rawValue:))
  }
  func mode(for classID: UInt32? = nil) -> MSAA {
    if let classID, let mode = override(for: classID) { return mode }
    return MSAA(rawValue: defaults.integer(forKey: key(nil))) ?? .off
  }
  func set(_ mode: MSAA?, for classID: UInt32? = nil) {
    if let mode { defaults.set(mode.rawValue, forKey: key(classID)) }
    else { defaults.removeObject(forKey: key(classID)) }
  }
}
