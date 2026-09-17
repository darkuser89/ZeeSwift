import Foundation
import GameController

/// Physical Apple inputs stay distinct until the user's mapping is applied.
enum ControllerInput: String, CaseIterable, Codable, Identifiable, Sendable {
  case south, east, north, west, leftShoulder, rightShoulder, leftTrigger, rightTrigger
  case menu, options, home, leftClick, rightClick, up, down, left, right
  var id: Self { self }
  var label: String {
    switch self {
    case .south: "Cross / A"
    case .east: "Circle / B"
    case .north: "Triangle / Y"
    case .west: "Square / X"
    case .leftShoulder: "L1 / LB"
    case .rightShoulder: "R1 / RB"
    case .leftTrigger: "L2 / LT"
    case .rightTrigger: "R2 / RT"
    case .menu: "Options / Menu"
    case .options: "Share / Create / View"
    case .home: "PS / Xbox / Home"
    case .leftClick: "Press Left Stick"
    case .rightClick: "Press Right Stick"
    case .up: "D-pad Up"
    case .down: "D-pad Down"
    case .left: "D-pad Left"
    case .right: "D-pad Right"
    }
  }
  var group: String {
    switch self {
    case .south, .east, .north, .west: "Action Buttons"
    case .leftShoulder, .rightShoulder, .leftTrigger, .rightTrigger: "Shoulders and Triggers"
    case .menu, .options, .home, .leftClick, .rightClick: "Menu and Stick Buttons"
    case .up, .down, .left, .right: "D-pad"
    }
  }
}

enum ControllerTarget: String, CaseIterable, Codable, Identifiable, Sendable {
  case none, one, two, three, four, zl, zr, home, start, back, up, down, left, right
  var id: Self { self }
  var label: String {
    switch self {
    case .none: "Not Assigned"
    case .one: "Zeebo 1"
    case .two: "Zeebo 2"
    case .three: "Zeebo 3"
    case .four: "Zeebo 4"
    case .zl: "Zeebo ZL"
    case .zr: "Zeebo ZR"
    case .home: "Home / Pause (Automatic)"
    case .start: "Home as Start"
    case .back: "Home as Back"
    case .up: "D-pad Up"
    case .down: "D-pad Down"
    case .left: "D-pad Left"
    case .right: "D-pad Right"
    }
  }
  func button(classID: UInt32) -> Int? {
    // The original Zeebo interface assigns printed buttons 1,2,3,4 to HID indices 1,2,3,0.
    // Some shipped games bypass the Zeebo remapping helper and interpret the raw
    // nButtonID as the printed 0-based face-button number. Keep the host-facing
    // labels stable while adapting only those verified titles at this boundary.
    let sequentialFaces = ControllerMapping.sequentialFaceButtonClasses.contains(classID)
    return switch self {
    case .none: nil
    case .one: sequentialFaces ? 0 : 1
    case .two: sequentialFaces ? 1 : 2
    case .three: sequentialFaces ? 2 : 3
    case .four: sequentialFaces ? 3 : 0
    case .zl: 4
    case .zr: 5
    case .home: ControllerMapping.defaultHomeButton(classID: classID)
    case .start: 8
    case .back: 9
    case .up: 12
    case .left: 13
    case .down: 14
    case .right: 15
    }
  }
}

struct PhysicalControllerState: Sendable, Equatable {
  var buttons: Set<ControllerInput> = []
  var sticks: SIMD4<Float> = .zero
  init(buttons: Set<ControllerInput> = [], sticks: SIMD4<Float> = .zero) {
    self.buttons = buttons; self.sticks = sticks
  }
  init(gamepad: GCExtendedGamepad) {
    let inputs: [(ControllerInput, Bool)] = [
      (.south, gamepad.buttonA.isPressed), (.east, gamepad.buttonB.isPressed),
      (.north, gamepad.buttonY.isPressed), (.west, gamepad.buttonX.isPressed),
      (.leftShoulder, gamepad.leftShoulder.isPressed), (.rightShoulder, gamepad.rightShoulder.isPressed),
      (.leftTrigger, gamepad.leftTrigger.isPressed), (.rightTrigger, gamepad.rightTrigger.isPressed),
      (.menu, gamepad.buttonMenu.isPressed), (.options, gamepad.buttonOptions?.isPressed == true),
      (.home, gamepad.buttonHome?.isPressed == true),
      (.leftClick, gamepad.leftThumbstickButton?.isPressed == true),
      (.rightClick, gamepad.rightThumbstickButton?.isPressed == true),
      (.up, gamepad.dpad.up.isPressed), (.down, gamepad.dpad.down.isPressed),
      (.left, gamepad.dpad.left.isPressed), (.right, gamepad.dpad.right.isPressed),
    ]
    buttons = Set(inputs.filter(\.1).map(\.0))
    sticks = SIMD4(gamepad.leftThumbstick.xAxis.value, gamepad.leftThumbstick.yAxis.value,
      gamepad.rightThumbstick.xAxis.value, gamepad.rightThumbstick.yAxis.value)
  }
}

struct ControllerMapping: Codable, Equatable, Sendable {
  var buttons: [ControllerInput: ControllerTarget] = [:]
  var swapSticks = false
  var invertLeftX = false
  var invertLeftY = false
  var invertRightX = false
  var invertRightY = false
  static let standard = ControllerMapping()
  /// Titles verified to consume raw face-button IDs 0...3 instead of the
  /// Zeebo Z-Pad's printed-button UID permutation. This keeps Cross/A mapped to
  /// logical Zeebo 1 consistently without changing the emulated HID ABI.
  static let sequentialFaceButtonClasses: Set<UInt32> = [
    0x0104_13c3, // Ultimate Chess 3D
    0x0107_3825, // Alpine Racer
    0x0108_7b73, // Ridge Racer
    0x0108_d1b7, // Tekken 2
    0x0108_fab8, // Galaxy on Fire
    0x0108_ff16, // Zeebo Sports Queimada
    0x0109_24dd, 0x0109_24de, 0x0109_24df, 0x0109_24e0, 0x0109_24e1,
    0x0109_24e2, 0x0109_24e3, 0x0109_24e4, // Data East arcade collection
    0x0109_40da, // Disney All Star Cards
    0x0109_5146, // Toy Raid
    0x0109_ec1b, 0x0109_ec1c, // Data East arcade collection
    0x010a_1241, // Powerboat Challenge
  ]
  static func defaultHomeButton(classID: UInt32) -> Int {
    // Original-game input probes establish these defaults; explicit user targets bypass them.
    // Ultimate Chess uses its Zeebo 1/back action for the in-game menu.
    if classID == 0x0104_13c3 { return 1 }
    return [UInt32(0x0102_f789), 0x0108_1984, 0x0108_7b73, 0x0108_7c1c, 0x0108_af6c, 0x0108_ff17,
     0x0108_ff19, 0x0109_78a2, 0x0109_da8e, 0x0109_da90, 0x0109_da91].contains(classID) ? 9 : 8
  }
  func target(for input: ControllerInput) -> ControllerTarget {
    if let target = buttons[input] { return target }
    switch input {
    case .south: return .one
    case .east: return .four
    case .north: return .three
    case .west: return .two
    case .leftShoulder, .leftTrigger: return .zl
    case .rightShoulder, .rightTrigger: return .zr
    case .menu, .home: return .home
    case .options: return .back
    case .leftClick, .rightClick: return .none
    case .up: return .up
    case .down: return .down
    case .left: return .left
    case .right: return .right
    }
  }
  func apply(_ state: PhysicalControllerState, classID: UInt32) -> NativeControllerState {
    let buttons = Set(state.buttons.compactMap { target(for: $0).button(classID: classID) })
    var sticks = swapSticks
      ? SIMD4(state.sticks.z, state.sticks.w, state.sticks.x, state.sticks.y) : state.sticks
    if invertLeftX { sticks.x = -sticks.x }
    if invertLeftY { sticks.y = -sticks.y }
    if invertRightX { sticks.z = -sticks.z }
    if invertRightY { sticks.w = -sticks.w }
    return NativeControllerState(buttons: buttons, sticks: sticks, automaticHomeRouting: false)
  }
}

/// Changing a mapping releases old outputs and waits for held inputs to return to neutral.
struct ControllerInputMapper {
  private(set) var mapping: ControllerMapping
  private var last = PhysicalControllerState()
  private var blocked = Set<ControllerInput>()
  private var blockSticks = false
  init(mapping: ControllerMapping = .standard) { self.mapping = mapping }
  @discardableResult mutating func replace(_ value: ControllerMapping) -> Bool {
    guard value != mapping else { return false }
    mapping = value
    suppressHeldInputs()
    return true
  }
  mutating func suppressHeldInputs() {
    blocked.formUnion(last.buttons)
    blockSticks = (0..<4).contains { last.sticks[$0].isFinite && abs(last.sticks[$0]) > 0.12 }
  }
  mutating func update(_ state: PhysicalControllerState, classID: UInt32) -> NativeControllerState {
    last = state
    blocked.formIntersection(state.buttons)
    if blockSticks && (0..<4).allSatisfy({ !state.sticks[$0].isFinite || abs(state.sticks[$0]) <= 0.12 }) {
      blockSticks = false
    }
    return mapping.apply(PhysicalControllerState(buttons: state.buttons.subtracting(blocked),
      sticks: blockSticks ? .zero : state.sticks), classID: classID)
  }
}

struct ControllerPreferences: Codable, Equatable {
  var version = 1
  var global: ControllerMapping = .standard
  var games: [String: ControllerMapping] = [:]
  var multiplayer: MultiplayerPreferences? = nil
  var inputPreferences: MultiplayerPreferences {
    if let multiplayer { return multiplayer }
    var result = MultiplayerPreferences()
    result.global[0].controller = global
    for (key, mapping) in games {
      var players = result.global
      players[0].controller = mapping
      result.games[key] = players
    }
    return result
  }
  func players(for classID: UInt32?) -> [PlayerInputConfiguration] {
    let inputs = inputPreferences
    return classID.flatMap { inputs.games[Self.key($0)] } ?? inputs.global
  }
  static func key(_ classID: UInt32) -> String { String(format: "%08x", classID) }
  func override(for classID: UInt32) -> ControllerMapping? { games[Self.key(classID)] }
  func resolved(for classID: UInt32) -> ControllerMapping { override(for: classID) ?? global }
}

final class ControllerPreferencesStore {
  let url: URL
  init(url: URL) { self.url = url }
  static func applicationStore() throws -> ControllerPreferencesStore {
    let support = try FileManager.default.url(for: .applicationSupportDirectory,
      in: .userDomainMask, appropriateFor: nil, create: false)
    return ControllerPreferencesStore(url: support.appendingPathComponent("ZeeSwift/ControllerBindings.json"))
  }
  private func validate(_ preferences: ControllerPreferences) throws {
    if let inputs = preferences.multiplayer {
      let arrays = [inputs.global] + Array(inputs.games.values)
      guard inputs.games.count <= 1024,
        inputs.games.keys.allSatisfy({ UInt32($0, radix: 16).map(ControllerPreferences.key) == $0 }),
        arrays.allSatisfy({ $0.count == 2 && $0.allSatisfy {
          (0...1).contains($0.controllerSlot) && $0.keyboard.values.allSatisfy { $0.code < 128 && $0.label.count <= 64 }
        } }) else { throw CocoaError(.fileReadCorruptFile) }
    }
    guard preferences.version == 1, preferences.games.count <= 1024,
      preferences.games.keys.allSatisfy({ key in
        UInt32(key, radix: 16).map { ControllerPreferences.key($0) == key } == true
      }) else { throw CocoaError(.fileReadCorruptFile) }
  }
  func load() throws -> ControllerPreferences {
    guard FileManager.default.fileExists(atPath: url.path) else { return ControllerPreferences() }
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 4 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
    let value = try JSONDecoder().decode(ControllerPreferences.self, from: Data(contentsOf: url))
    try validate(value)
    return value
  }
  func save(_ preferences: ControllerPreferences) throws {
    try validate(preferences)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(preferences)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
  }
}


enum PlayerInputSource: String, Codable, CaseIterable, Identifiable, Sendable {
  case controller, keyboard, both, disabled
  var id: Self { self }
  var label: String {
    switch self {
    case .controller: "Controller"
    case .keyboard: "Keyboard"
    case .both: "Controller and Keyboard"
    case .disabled: "Not Connected"
    }
  }
  var usesKeyboard: Bool { self == .keyboard || self == .both }
  var usesController: Bool { self == .controller || self == .both }
}

struct KeyboardBinding: Codable, Equatable, Sendable {
  var code: UInt16
  var label: String
}

enum KeyboardAction: String, Codable, CaseIterable, Identifiable, Sendable {
  case one, two, three, four, zl, zr, home, start, back, up, down, left, right, confirm
  case leftUp, leftDown, leftLeft, leftRight, rightUp, rightDown, rightLeft, rightRight
  var id: Self { self }
  var target: ControllerTarget? { self == .confirm ? .one : ControllerTarget(rawValue: rawValue) }
  var label: String {
    if self == .confirm { return "Zeebo 1 (Additional Key)" }
    if let target { return target.label }
    switch self {
    case .leftUp: return "Left Stick ↑"
    case .leftDown: return "Left Stick ↓"
    case .leftLeft: return "Left Stick ←"
    case .leftRight: return "Left Stick →"
    case .rightUp: return "Right Stick ↑"
    case .rightDown: return "Right Stick ↓"
    case .rightLeft: return "Right Stick ←"
    case .rightRight: return "Right Stick →"
    default: return rawValue
    }
  }
}

struct PlayerInputConfiguration: Codable, Equatable, Sendable {
  var source: PlayerInputSource = .both
  var controllerSlot = 0
  var controller: ControllerMapping = .standard
  var keyboard: [KeyboardAction: KeyboardBinding] = [:]
  static func standard(player: Int) -> Self {
    var result = Self()
    result.source = player == 0 ? .both : .controller
    result.controllerSlot = player
    let keys: [(KeyboardAction, UInt16, String)] = player == 0 ? [
      (.up,126,"↑"),(.down,125,"↓"),(.left,123,"←"),(.right,124,"→"),
      (.four,6,"Y / Z"),(.one,7,"X"),(.two,8,"C"),(.three,9,"V"),
      (.zl,12,"Q"),(.zr,14,"E"),(.start,36,"Return"),(.back,53,"Esc"),(.confirm,49,"Space")
    ] : [
      (.up,13,"W"),(.down,1,"S"),(.left,0,"A"),(.right,2,"D"),
      (.four,4,"H"),(.one,38,"J"),(.two,40,"K"),(.three,37,"L"),
      (.zl,32,"U"),(.zr,31,"O"),(.start,46,"M"),(.back,45,"N")
    ]
    for (action, code, label) in keys { result.keyboard[action] = .init(code: code, label: label) }
    return result
  }
  func keyboardState(_ keys: Set<UInt16>, classID: UInt32) -> NativeControllerState {
    let actions = Set(keyboard.filter { keys.contains($0.value.code) }.map(\.key))
    func axis(_ positive: KeyboardAction, _ negative: KeyboardAction) -> Float {
      (actions.contains(positive) ? 1 : 0) - (actions.contains(negative) ? 1 : 0)
    }
    return NativeControllerState(buttons: Set(actions.compactMap { $0.target?.button(classID: classID) }),
      sticks: SIMD4(axis(.leftRight,.leftLeft), axis(.leftUp,.leftDown),
        axis(.rightRight,.rightLeft), axis(.rightUp,.rightDown)), automaticHomeRouting: false)
  }
}

struct MultiplayerPreferences: Codable, Equatable {
  var global: [PlayerInputConfiguration] = [.standard(player: 0), .standard(player: 1)]
  var games: [String: [PlayerInputConfiguration]] = [:]
}

/// Queue-owned routing shared by the app and input tests. Host slots never imply player identity.
struct MultiplayerInputRouter {
  private(set) var configurations: [PlayerInputConfiguration]
  private(set) var connectedSlots: Set<Int>
  private var physical = [PhysicalControllerState(), PhysicalControllerState()]
  private var keys = Set<UInt16>()
  private var blockedKeys = Set<UInt16>()
  private var mappers: [ControllerInputMapper]
  init(configurations: [PlayerInputConfiguration], connectedSlots: Set<Int> = []) {
    precondition(configurations.count == 2)
    self.configurations = configurations
    self.connectedSlots = connectedSlots
    mappers = configurations.map { ControllerInputMapper(mapping: $0.controller) }
  }
  mutating func setPhysical(_ state: PhysicalControllerState, slot: Int, connected: Bool) {
    guard physical.indices.contains(slot) else { return }
    physical[slot] = connected ? state : .init()
    if connected { connectedSlots.insert(slot) } else { connectedSlots.remove(slot) }
  }
  mutating func setKeys(_ value: Set<UInt16>) { keys = value; blockedKeys.formIntersection(value) }
  mutating func suppress(classID: UInt32) {
    blockedKeys.formUnion(keys)
    for player in 0..<2 {
      _ = mappers[player].update(physical[configurations[player].controllerSlot], classID: classID)
      mappers[player].suppressHeldInputs()
    }
  }
  mutating func replace(_ value: [PlayerInputConfiguration], classID: UInt32) {
    guard value.count == 2, value.allSatisfy({ (0...1).contains($0.controllerSlot) }), value != configurations else { return }
    configurations = value
    for player in 0..<2 { _ = mappers[player].replace(value[player].controller) }
    suppress(classID: classID)
  }
  func connected(player: Int) -> Bool {
    let config = configurations[player]
    return config.source.usesKeyboard || (config.source.usesController && connectedSlots.contains(config.controllerSlot))
  }
  mutating func state(player: Int, classID: UInt32) -> NativeControllerState {
    let config = configurations[player]
    let mapped = mappers[player].update(physical[config.controllerSlot], classID: classID)
    var result = config.source.usesController ? mapped : NativeControllerState(automaticHomeRouting: false)
    if config.source.usesKeyboard {
      let keyboard = config.keyboardState(keys.subtracting(blockedKeys), classID: classID)
      result.buttons.formUnion(keyboard.buttons)
      for axis in 0..<4 where keyboard.sticks[axis] != 0 { result.sticks[axis] = keyboard.sticks[axis] }
    }
    return result
  }
}
