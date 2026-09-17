import MetalKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct ZeeSwiftApp: App {
  // Views observe game updates; the app scene only owns the stable model.
  // Rebuilding scene commands for each guest update removes Apple's HUD menu.
  @StateObject private var state = AppState()
  private var model: EmulatorModel { state.model }
  @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
  var body: some Scene {
    WindowGroup {
      ContentView(model: model)
        .frame(minWidth: 1000, minHeight: 680)
        .onOpenURL { model.open($0) }
        .onChange(of: language) { _, _ in model.languageDidChange() }
    }
    .defaultSize(width: 1100, height: 760)
    .environment(\.locale, selectedLanguage.locale)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button(L10n.text("Add Games …")) { model.chooseGame() }.keyboardShortcut("o")
      }
    }
    Window("Game", id: "game") {
      ExternalGameWindow(model: model)
        .environment(\.locale, selectedLanguage.locale)
    }
    .defaultSize(width: 960, height: 720)
    Settings {
      AppSettingsView(model: model)
        .environment(\.locale, selectedLanguage.locale)
    }
  }
  private var selectedLanguage: AppLanguage { AppLanguage(rawValue: language) ?? .system }
}

@MainActor private final class AppState: ObservableObject {
  let model = EmulatorModel()
}

@MainActor final class EmulatorModel: ObservableObject {
  @Published var title = "ZeeSwift"
  @Published var status = L10n.text("Open a game ZIP")
  @Published var detail = L10n.text("Standalone Zeebo HLE emulator · Work in progress")
  @Published var report = L10n.text("No game loaded yet.")
  @Published var busy = false
  @Published var controllerName = L10n.text("No controller connected")
  @Published var error: String?
  @Published var showingGame = false
  @Published var copyright: BREWCopyrightInfo?
  @Published var activeGame: LibraryGame?
  @Published private(set) var presentsGameInSeparateWindow = false
  @Published private(set) var pixelExactMagnification = false
  @Published private(set) var metalFXMode = MetalFXMode.off
  @Published private(set) var windowScaling = WindowScaling.preserveAspect
  let library = LibraryModel()
  let controllerSettings = ControllerSettingsModel()
  let frames = FrameStore()
  private var session: EmulationSession?
  private var sessionID = UUID()
  private var recordedSession: UUID?
  private let controllers = NativeControllers()
  private var controllerEditors = 0
  init() {
    controllers.onName = { [weak self] in self?.controllerName = $0 }
    controllers.onState = { [weak self] slot, state, connected in
      self?.session?.sendPhysicalControllerState(state, slot: slot, connected: connected)
    }
    controllerSettings.onChange = { [weak self] in self?.refreshControllerMapping() }
    controllers.refreshControllers()
  }
  func chooseGame() {
    returnToLibrary()
    library.chooseFiles()
  }
  func open(_ url: URL) {
    library.add([url]) { [weak self] game in self?.play(game) }
  }
  func play(_ game: LibraryGame) {
    guard !busy else { return }
    let url = game.resolvedURL()
    guard FileManager.default.fileExists(atPath: url.path) else {
      library.error =
        L10n.format("%@: The ZIP file could not be found. Add it again to update its location.", game.title)
      return
    }
    // Apple's HUD registers its AppKit menu during the first Metal device lookup.
    // Do that on the main actor, before the guest worker can initialize Metal.
    // The library window and its menu already exist when play is invoked.
    _ = MTLCreateSystemDefaultDevice()
    session?.stop()
    let id = UUID()
    sessionID = id
    busy = true
    copyright = nil
    error = nil
    title = game.title
    activeGame = game
    metalFXMode = MetalFXPreferences().mode(for: activeGame?.classID)
    windowScaling = WindowScalingPreferences().mode(for: game.classID)
    pixelExactMagnification = PixelScalingPreferences().enabled(for: game.classID)
    detail = game.publisher
    presentsGameInSeparateWindow = UserDefaults.standard.bool(
      forKey: SeparateGameWindowPreferences.storageKey)
    showingGame = true
    status = L10n.text("Starting game code …")
    controllers.stopVibration()
    let session = EmulationSession(frames: frames,
      playerInputs: controllerSettings.players(for: game.classID), connectedControllers: controllers.connectedSlots,
      pixelExactMagnification: pixelExactMagnification,
      temporalEnabled: metalFXMode == .temporal && Metal4Renderer.supportsTemporal,
      renderResolution: RenderResolutionPreferences().resolution(for: game.classID),
      msaa: MSAAPreferences().mode(for: game.classID),
      onCopyright: { [weak self] notice in
      DispatchQueue.main.async {
        guard let self, self.sessionID == id else { return }
        self.copyright = notice
      }
    }, onVibration: { [weak self] duration in
      DispatchQueue.main.async {
        guard let self, self.sessionID == id else { return }
        let input = self.controllerSettings.players(for: self.activeGame?.classID)[0]
        self.controllers.vibrate(milliseconds: input.source.usesController ? duration : 0, slot: input.controllerSlot)
      }
    })
    self.session = session
    session.start(url: url) { [weak self] update in
      DispatchQueue.main.async {
        guard let self, self.sessionID == id else { return }
        self.report = update.report
        self.error = update.error
        self.status = update.status
        self.busy = false
        if update.completed {
          self.returnToLibrary()
          self.status = update.status
          return
        }
        if update.error == nil && self.recordedSession != id {
          self.recordedSession = id
          self.library.markPlayed(game.id)
        }
      }
    }
    session.setControllerEditing(controllerEditors > 0)
    controllers.publish()
  }
  private func refreshControllerMapping() {
    guard let activeGame else { return }
    session?.setPlayerInputs(controllerSettings.players(for: activeGame.classID))
    controllers.publish()
  }
  func refreshDisplayPreferences() {
    guard let activeGame else { return }
    metalFXMode = MetalFXPreferences().mode(for: activeGame.classID)
    windowScaling = WindowScalingPreferences().mode(for: activeGame.classID)
    pixelExactMagnification = PixelScalingPreferences().enabled(for: activeGame.classID)
    session?.setPixelExactMagnification(pixelExactMagnification)
    session?.setTemporalEnabled(metalFXMode == .temporal && Metal4Renderer.supportsTemporal)
  }
  func controllerEditorChanged(_ editing: Bool) {
    controllerEditors = max(0, controllerEditors + (editing ? 1 : -1))
    session?.setControllerEditing(controllerEditors > 0)
    controllers.publish()
  }
  func keyboard(_ keys: Set<UInt16>) { session?.sendKeyboardKeys(keys) }
  func dismissCopyright() { session?.dismissCopyright() }
  func returnToLibrary() {
    stop()
    showingGame = false
    activeGame = nil
    presentsGameInSeparateWindow = false
  }
  func stop() {
    controllers.stopVibration()
    session?.stop()
    session = nil
    sessionID = UUID()
    busy = false
    copyright = nil
    status = L10n.text("Emulation stopped")
  }
  func languageDidChange() {
    if !showingGame {
      status = L10n.text("Open a game ZIP")
      detail = L10n.text("Standalone Zeebo HLE emulator · Work in progress")
      if activeGame == nil { report = L10n.text("No game loaded yet.") }
    }
    controllers.refreshControllers()
    objectWillChange.send()
  }
  func saveReport() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = L10n.text("ZeeSwift-Diagnostics.txt")
    if panel.runModal() == .OK, let url = panel.url {
      do {
        try (report + "\n" + (error ?? "")).write(to: url, atomically: true, encoding: .utf8)
      } catch { self.error = error.localizedDescription }
    }
  }
}
struct ContentView: View {
  @ObservedObject var model: EmulatorModel
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow
  var body: some View {
    Group {
      if model.showingGame && !model.presentsGameInSeparateWindow {
        GamePlayerView(model: model)
      } else {
        LibraryView(
          library: model.library, controllerSettings: model.controllerSettings,
          onPlay: model.play,
          onControllerEditing: model.controllerEditorChanged)
      }
    }
    .tint(.gray)
    .onChange(of: model.showingGame) { _, showing in
      if showing && model.presentsGameInSeparateWindow {
        openWindow(id: "game")
      } else if !showing {
        dismissWindow(id: "game")
      }
    }
  }
}

/// A clean presentation window: game pixels and the required copyright prompt only.
struct ExternalGameWindow: View {
  @ObservedObject var model: EmulatorModel
  var body: some View {
    ZStack {
      Color.black
      if model.showingGame && model.presentsGameInSeparateWindow {
        MetalSurface(
          frames: model.frames, windowScaling: model.windowScaling, metalFXMode: model.metalFXMode,
          onKeys: model.keyboard
        ) { model.error = $0 }
        if let notice = model.copyright {
          CopyrightOverlay(notice: notice, onClose: model.dismissCopyright)
        }
      }
    }
    .frame(minWidth: 320, minHeight: 240)
    .navigationTitle(model.title)
    .onDisappear {
      if model.showingGame && model.presentsGameInSeparateWindow {
        model.returnToLibrary()
      }
    }
  }
}

struct GamePlayerView: View {
  @ObservedObject var model: EmulatorModel
  @AppStorage("showFPS") private var showFPS = false
  private let testFPS = ProcessInfo.processInfo.environment["ZEESWIFT_TEST_FPS"] == "1"
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        Button {
          model.returnToLibrary()
        } label: {
          Label("Library", systemImage: "chevron.left")
        }.buttonStyle(.plain).foregroundStyle(LibraryTheme.accent).padding(.trailing, 10)
        Spacer()
        Button("Stop", systemImage: "stop.fill") { model.stop() }
      }.padding(20)
      ZStack {
        MetalSurface(frames: model.frames, windowScaling: model.windowScaling, metalFXMode: model.metalFXMode, onKeys: model.keyboard) {
          model.error = $0
        }
        if model.busy {
          ProgressView(model.status).padding(22).background(
            .regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        if let notice = model.copyright {
          CopyrightOverlay(notice: notice, onClose: model.dismissCopyright)
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
        .overlay(alignment: .topTrailing) {
          if showFPS || testFPS {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
              let fps = model.frames.performance()?.fps ?? 0
              Text(String(format: "%.1f FPS", fps))
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .monospacedDigit().foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(L10n.format("Game: %.1f frames per second", fps))
            }.padding(16).allowsHitTesting(false)
          }
        }
      if let error = model.error {
        HStack(alignment: .top) {
          Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
          VStack(alignment: .leading, spacing: 5) {
            Text("Game paused").font(.headline)
            Text(error).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          }
          Spacer()
          SettingsLink { Label("Settings", systemImage: "gearshape") }
        }.padding(16).background(Color.orange.opacity(0.08))
      }
    }
    .tint(.gray)
    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
      guard let provider = providers.first else { return false }
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        if let url { DispatchQueue.main.async { model.open(url) } }
      }
      return true
    }
  }
}

private struct CopyrightOverlay: View {
  let notice: BREWCopyrightInfo
  let onClose: () -> Void
  var body: some View {
    ZStack {
      Color.black.opacity(0.6)
      VStack(spacing: 16) {
        if let data = notice.artwork, let icon = NSImage(data: data) {
          Image(nsImage: icon).resizable().interpolation(.none).scaledToFit()
            .frame(width: 80, height: 80)
        }
        Text(notice.title).font(.title2.bold())
        if !notice.publisher.isEmpty { Text(notice.publisher).foregroundStyle(.secondary) }
        if !notice.copyright.isEmpty { Text(notice.copyright) }
        if !notice.version.isEmpty { Text("Version \(notice.version)").font(.caption) }
        Button("Close", action: onClose)
          .keyboardShortcut(.cancelAction)
          .buttonStyle(.borderedProminent)
        Text("Cross / A or Back").font(.caption).foregroundStyle(.secondary)
      }.multilineTextAlignment(.center).padding(28).frame(maxWidth: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
  }
}

enum SeparateGameWindowPreferences {
  static let storageKey = "openGamesInSeparateWindow"
}

/// App-wide presentation and diagnostics live in the native macOS Settings window.
struct AppSettingsView: View {
  @ObservedObject var model: EmulatorModel
  @State private var section = SettingsSection.general
  private enum SettingsSection: String, Hashable {
    case general, display, controller, diagnostics
  }
  var body: some View {
    VStack(spacing: 0) {
      Picker("Settings", selection: $section) {
        Text("General").tag(SettingsSection.general)
        Text("Display").tag(SettingsSection.display)
        Text("Controller").tag(SettingsSection.controller)
        Text("Diagnostics").tag(SettingsSection.diagnostics)
      }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.vertical, 12)
      Divider()
      Group {
        switch section {
        case .general:
          GeneralSettingsView()
        case .controller:
          ControllerSettingsView(settings: model.controllerSettings, connectedControllers: model.controllerName,
            onEditingChange: model.controllerEditorChanged)
        case .diagnostics:
          DiagnosticsSettingsView(model: model)
        case .display:
          DisplaySettingsView(onScalingChange: model.refreshDisplayPreferences)
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(width: 650, height: 800)
    .background(LibraryTheme.background)
    .tint(.gray)
  }
}

struct GeneralSettingsView: View {
  @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
  var body: some View {
    Form {
      Section("Language") {
        Picker("App language", selection: $language) {
          ForEach(AppLanguage.allCases) { option in
            Text(option.label).tag(option.rawValue)
          }
        }
        Text("System Default follows the preferred macOS language when it is English, German, or Romanian. Other languages use English.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }.formStyle(.grouped)
  }
}

struct DiagnosticsSettingsView: View {
  @ObservedObject var model: EmulatorModel
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Runtime Diagnostics").font(.title2.bold())
        Spacer()
        Button("Save …") { model.saveReport() }
      }
      if let game = model.activeGame { Text(game.title).font(.headline) }
      Text(model.status).font(.callout).foregroundStyle(.secondary)
      if let error = model.error {
        Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
      }
      ScrollView {
        Text(model.report).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading).padding(14)
      }.background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }.padding(24)
  }
}

struct MetalSurface: NSViewRepresentable {
  let frames: FrameStore
  var windowScaling = WindowScaling.preserveAspect
  var metalFXMode = MetalFXMode.off
  let onKeys: (Set<UInt16>) -> Void
  let onFailure: (String) -> Void
  final class Coordinator { var renderer: Metal4Renderer? }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> MTKView {
    let view = GameMetalView()
    view.onKeys = onKeys
    view.colorPixelFormat = .bgra8Unorm
    view.preferredFramesPerSecond = 60
    do {
      let renderer = try Metal4Renderer(frames: frames)
      renderer.windowScaling = windowScaling
      renderer.metalFXMode = metalFXMode
      renderer.onFailure = onFailure
      context.coordinator.renderer = renderer
      view.device = renderer.device
      view.delegate = renderer
    } catch { DispatchQueue.main.async { onFailure(error.localizedDescription) } }
    return view
  }
  func updateNSView(_ nsView: MTKView, context: Context) {
    (nsView as? GameMetalView)?.onKeys = onKeys
    context.coordinator.renderer?.windowScaling = windowScaling
    context.coordinator.renderer?.metalFXMode = metalFXMode
  }
}

final class GameMetalView: MTKView {
  var onKeys: ((Set<UInt16>) -> Void)?
  private var pressed = Set<UInt16>()
  private var focusObserver: NSObjectProtocol?
  override var acceptsFirstResponder: Bool { true }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
    focusObserver = nil
    if let window {
      focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
        object: window, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.releaseKeys() }
        }
    } else { releaseKeys() }
  }
  deinit { if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) } }
  override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
  override func keyDown(with event: NSEvent) {
    guard !event.modifierFlags.contains(.command) else {
      releaseKeys()
      super.keyDown(with: event)
      return
    }
    if pressed.insert(event.keyCode).inserted { onKeys?(pressed) }
  }
  override func keyUp(with event: NSEvent) {
    if pressed.remove(event.keyCode) != nil { onKeys?(pressed) }
  }
  override func flagsChanged(with event: NSEvent) {
    // Device-specific modifier bits distinguish left/right keys held simultaneously.
    let masks: [UInt16: UInt] = [56:0x2,60:0x4,59:0x1,62:0x2000,58:0x20,61:0x40]
    guard let mask = masks[event.keyCode] else { return }
    if event.modifierFlags.rawValue & mask != 0 { pressed.insert(event.keyCode) }
    else { pressed.remove(event.keyCode) }
    onKeys?(pressed)
  }
  private func releaseKeys() { pressed.removeAll(); onKeys?(pressed) }
  override func resignFirstResponder() -> Bool {
    releaseKeys()
    return super.resignFirstResponder()
  }
}
