import SwiftUI
import AppKit

@MainActor final class ControllerSettingsModel: ObservableObject {
  @Published private(set) var preferences = ControllerPreferences()
  @Published private(set) var canEdit = false
  @Published var error: String?
  var onChange: (() -> Void)?
  private var store: ControllerPreferencesStore?
  init(store: ControllerPreferencesStore? = nil) {
    do {
      self.store = try store ?? ControllerPreferencesStore.applicationStore()
      reload()
    } catch { self.error = L10n.format("Controller settings: %@", error.localizedDescription) }
  }
  func reload() {
    do {
      guard let store else { return }
      let loaded = try store.load()
      preferences = loaded
      canEdit = true
      error = nil
      onChange?()
    } catch {
      canEdit = false
      self.error = L10n.format("Controller settings could not be loaded: %@", error.localizedDescription)
    }
  }
  func players(for classID: UInt32?) -> [PlayerInputConfiguration] { preferences.players(for: classID) }
  func mapping(for classID: UInt32?, player: Int = 0) -> ControllerMapping {
    players(for: classID)[player].controller
  }
  func hasOverride(_ classID: UInt32) -> Bool {
    preferences.inputPreferences.games[ControllerPreferences.key(classID)] != nil
  }
  func setOverride(_ enabled: Bool, for classID: UInt32) {
    var updated = preferences
    var inputs = updated.inputPreferences
    let key = ControllerPreferences.key(classID)
    inputs.games[key] = enabled ? players(for: classID) : nil
    updated.games[key] = enabled ? mapping(for: classID) : nil
    updated.multiplayer = inputs
    commit(updated)
  }
  func setPlayer(_ configuration: PlayerInputConfiguration, player: Int, for classID: UInt32?) {
    guard (0..<2).contains(player) else { return }
    var updated = preferences
    var inputs = updated.inputPreferences
    var players = preferences.players(for: classID)
    players[player] = configuration
    if let classID {
      let key = ControllerPreferences.key(classID)
      inputs.games[key] = players
      updated.games[key] = players[0].controller
    } else {
      inputs.global = players
      updated.global = players[0].controller
    }
    updated.multiplayer = inputs
    commit(updated)
  }
  func setMapping(_ mapping: ControllerMapping, for classID: UInt32?, player: Int = 0) {
    var config = players(for: classID)[player]
    config.controller = mapping
    setPlayer(config, player: player, for: classID)
  }
  private func commit(_ updated: ControllerPreferences) {
    guard canEdit, let store else { return }
    do {
      try store.save(updated)
      preferences = updated
      error = nil
      onChange?()
    } catch { self.error = L10n.format("The mapping could not be saved: %@", error.localizedDescription) }
  }
}

struct ControllerSettingsView: View {
  @ObservedObject var settings: ControllerSettingsModel
  var game: LibraryGame? = nil
  var connectedControllers: String? = nil
  var embedded = false
  var onEditingChange: (Bool) -> Void = { _ in }
  @State var player = 0
  @State private var recording: KeyboardAction?
  @Environment(\.dismiss) private var dismiss
  private let groups = ["Action Buttons", "Shoulders and Triggers", "Menu and Stick Buttons", "D-pad"]
  private var editable: Bool {
    settings.canEdit && (game.map { settings.hasOverride($0.classID) } ?? true)
  }
  private var config: PlayerInputConfiguration { settings.players(for: game?.classID)[player] }
  private var mapping: ControllerMapping { config.controller }
  private func setting<T>(_ key: WritableKeyPath<PlayerInputConfiguration, T>) -> Binding<T> {
    Binding(get: { config[keyPath: key] }, set: { value in
      var updated = config
      updated[keyPath: key] = value
      settings.setPlayer(updated, player: player, for: game?.classID)
    })
  }
  private var sharedKeys: Bool {
    let players = settings.players(for: game?.classID)
    return players.allSatisfy { $0.source.usesKeyboard } &&
      !Set(players[0].keyboard.values.map(\.code)).isDisjoint(with: players[1].keyboard.values.map(\.code))
  }
  private func target(_ input: ControllerInput) -> Binding<ControllerTarget> {
    Binding(get: { mapping.target(for: input) }, set: { value in
      var updated = mapping
      updated.buttons[input] = value
      settings.setMapping(updated, for: game?.classID, player: player)
    })
  }
  private func flag(_ key: WritableKeyPath<ControllerMapping, Bool>) -> Binding<Bool> {
    Binding(get: { mapping[keyPath: key] }, set: { value in
      var updated = mapping
      updated[keyPath: key] = value
      settings.setMapping(updated, for: game?.classID, player: player)
    })
  }
  var body: some View {
    VStack(spacing: 0) {
      if !embedded {
      HStack(spacing: 14) {
        Image(systemName: "gamecontroller.fill").font(.system(size: 28))
          .foregroundStyle(LibraryTheme.accent)
        VStack(alignment: .leading, spacing: 5) {
          Text(game == nil ? L10n.text("Controller") : L10n.text("Controller Mapping")).font(.title2.bold())
          Text(game?.title ?? L10n.text("Global for all games without a custom mapping"))
            .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }
        Spacer()
        if game != nil { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
      }.padding(24)
      Divider()
      }
      Form {
        Section {
          Picker("Player", selection: $player) {
            Text("Player 1").tag(0)
            Text("Player 2").tag(1)
          }.pickerStyle(.segmented)
        }
        if let game {
          Section {
            Picker("For This Game", selection: Binding(
              get: { settings.hasOverride(game.classID) },
              set: { settings.setOverride($0, for: game.classID) })) {
              Text("Use Global Mapping").tag(false)
              Text("Custom Mapping").tag(true)
            }.disabled(!settings.canEdit)
            if !settings.hasOverride(game.classID) {
              Text("Changes to the global mapping also apply to this game.")
                .font(.caption).foregroundStyle(.secondary)
              SettingsLink { Label("Open Global Settings", systemImage: "gearshape") }
            }
          }
        }
        Section(L10n.format("Input device for Player %lld", player + 1)) {
          if let connectedControllers {
            Text(connectedControllers).font(.caption).foregroundStyle(.secondary)
          }
          Picker("Input", selection: setting(\.source)) {
            ForEach(PlayerInputSource.allCases) { Text(L10n.text($0.label)).tag($0) }
          }
          if config.source.usesController {
            Picker("Connected Device", selection: setting(\.controllerSlot)) {
              Text("Controller 1").tag(0)
              Text("Controller 2").tag(1)
            }
            Text("Device numbers are shown in the global controller settings. When one disconnects, the other controller keeps its position.")
              .font(.caption).foregroundStyle(.secondary)
          }
          if sharedKeys {
            Text("Both players share keyboard keys. Those keys control both players at the same time.")
              .font(.caption).foregroundStyle(.orange)
          }
          let players = settings.players(for: game?.classID)
          if players.allSatisfy({ $0.source.usesController }) && players[0].controllerSlot == players[1].controllerSlot {
            Text("Both players use the same controller. Choose different devices for separate input.")
              .font(.caption).foregroundStyle(.orange)
          }
        }.disabled(!editable)
        if config.source.usesKeyboard {
          Section("Keyboard") {
            Text("Click a mapping and press the desired key. Both sticks can be mapped; keyboard axes use full deflection. Shortcuts reserved by macOS remain with the system.")
              .font(.caption).foregroundStyle(.secondary)
            ForEach(KeyboardAction.allCases) { action in
              HStack {
                Text(L10n.text(action.label))
                Spacer()
                Button(config.keyboard[action].map { L10n.text($0.label) } ?? L10n.text("Not Assigned")) {
                  recording = action
                }
                  .frame(minWidth: 100)
                Button {
                  var updated = config
                  updated.keyboard[action] = nil
                  settings.setPlayer(updated, player: player, for: game?.classID)
                } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless)
                  .help("Remove mapping").disabled(config.keyboard[action] == nil)
              }
            }
          }.disabled(!editable)
        }
        if config.source.usesController {
        Section {
          Text("Choose the desired Zeebo button for each controller button. Multiple buttons may trigger the same function.")
            .font(.callout).foregroundStyle(.secondary)
        }
        ForEach(groups, id: \.self) { group in
          Section(L10n.text(group)) {
            ForEach(ControllerInput.allCases.filter { $0.group == group }) { input in
              Picker(L10n.text(input.label), selection: target(input)) {
                ForEach(ControllerTarget.allCases) { destination in
                  Text(L10n.text(destination.label)).tag(destination)
                }
              }.disabled(!editable)
            }
          }
        }
        Section("Analog Sticks") {
          Toggle("Swap left and right sticks", isOn: flag(\.swapSticks))
          Toggle("Left stick: invert X axis", isOn: flag(\.invertLeftX))
          Toggle("Left stick: invert Y axis", isOn: flag(\.invertLeftY))
          Toggle("Right stick: invert X axis", isOn: flag(\.invertRightX))
          Toggle("Right stick: invert Y axis", isOn: flag(\.invertRightY))
          Text("When sticks are swapped, the axes refer to the corresponding Zeebo stick.")
            .font(.caption).foregroundStyle(.secondary)
        }.disabled(!editable)
        }
        Section {
          Text("Home / Pause (Automatic) uses the game's known pause button. Choose “Home as Start” or “Home as Back” to set it explicitly.")
            .font(.caption).foregroundStyle(.secondary)
          Button("Restore Default Mapping") {
            settings.setPlayer(.standard(player: player), player: player, for: game?.classID)
          }.disabled(!editable)
          if let game, settings.hasOverride(game.classID) {
            Button("Use Global Mapping Again") { settings.setOverride(false, for: game.classID) }
              .disabled(!settings.canEdit)
          }
        }
      }.formStyle(.grouped)
      if let error = settings.error {
        HStack(alignment: .top) {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
          Text(error).font(.caption).textSelection(.enabled)
          Spacer()
          if !settings.canEdit { Button("Reload") { settings.reload() } }
        }.padding(16)
      }
      Divider()
      Text("Saved automatically. Briefly release held buttons after making a change.")
        .font(.caption).foregroundStyle(.secondary).padding(14)
    }
    .frame(width: 650, height: embedded ? nil : 740)
    .background(LibraryTheme.background)
    .tint(.gray)
    .sheet(item: $recording) { action in
      VStack(spacing: 18) {
        Text(L10n.format("Player %lld · %@", player + 1, L10n.text(action.label))).font(.headline)
        Text("Press the desired key now")
        KeyCaptureView { binding in
          var updated = config
          updated.keyboard[action] = binding
          settings.setPlayer(updated, player: player, for: game?.classID)
          recording = nil
        }.frame(width: 340, height: 45)
        Button("Cancel") { recording = nil }
      }.padding(28)
    }
    .onAppear { onEditingChange(true) }
    .onDisappear { onEditingChange(false) }
  }
}


struct KeyCaptureView: NSViewRepresentable {
  var onKey: (KeyboardBinding) -> Void
  func makeNSView(context: Context) -> CaptureKeyView {
    let view = CaptureKeyView()
    view.onKey = onKey
    return view
  }
  func updateNSView(_ view: CaptureKeyView, context: Context) { view.onKey = onKey }
}

final class CaptureKeyView: NSView {
  var onKey: ((KeyboardBinding) -> Void)?
  override var acceptsFirstResponder: Bool { true }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.window?.makeFirstResponder(self)
    }
  }
  override func keyDown(with event: NSEvent) {
    guard !event.isARepeat, !event.modifierFlags.contains(.command) else { return }
    let names: [UInt16: String] = [36:"Return",48:"Tab",49:"Space",51:"⌫",53:"Esc",
      76:"Enter (Numpad)",117:"Delete",123:"←",124:"→",125:"↓",126:"↑",
      122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12"]
    let label = names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
    onKey?(.init(code: event.keyCode, label: label))
  }
  override func flagsChanged(with event: NSEvent) {
    let names: [UInt16: String] = [56:"Left Shift",60:"Right Shift",59:"Left Control",62:"Right Control",58:"Left Option",61:"Right Option"]
    if let label = names[event.keyCode] { onKey?(.init(code: event.keyCode, label: label)) }
  }
}
