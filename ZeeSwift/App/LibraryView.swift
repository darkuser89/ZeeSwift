import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum LibraryTheme {
  static let background = Color(nsColor: .windowBackgroundColor)
  static let panel = Color(nsColor: .controlBackgroundColor)
  static let artwork = Color(nsColor: .underPageBackgroundColor)
  static let accent = Color.primary
  static let separator = Color(nsColor: .separatorColor)
}

struct LibraryView: View {
  @ObservedObject var library: LibraryModel
  @ObservedObject var controllerSettings: ControllerSettingsModel
  let onPlay: (LibraryGame) -> Void
  var onControllerEditing: (Bool) -> Void = { _ in }
  @State private var settingsGame: LibraryGame?
  @State private var query = ""
  @State private var section = Section.all
  @State private var recentSort = false
  @State private var dropping = false
  private enum Section: String, CaseIterable {
    case all, favorites, recent
    var title: String {
      switch self {
      case .all: L10n.text("All Games")
      case .favorites: L10n.text("Favorites")
      case .recent: L10n.text("Recently Played")
      }
    }
    var symbol: String {
      switch self {
      case .all: "square.grid.2x2"
      case .favorites: "star"
      case .recent: "clock"
      }
    }
  }
  private var visible: [LibraryGame] {
    library.games.filter {
      (section != .favorites || $0.favorite) && (section != .recent || $0.lastPlayed != nil)
        && (query.isEmpty || $0.title.localizedStandardContains(query)
          || $0.publisher.localizedStandardContains(query))
    }.sorted {
      if section == .recent || recentSort {
        let a = $0.lastPlayed ?? $0.addedAt
        let b = $1.lastPlayed ?? $1.addedAt
        if a != b { return a > b }
      }
      return $0.title.localizedStandardCompare($1.title) == .orderedAscending
    }
  }
  var body: some View {
    HStack(spacing: 0) {
      sidebar
      VStack(alignment: .leading, spacing: 24) {
        HStack(alignment: .center) {
          Text(section == .all ? L10n.text("Library") : section.title)
            .font(.system(size: 28, weight: .semibold))
          Spacer()
        }
        HStack(spacing: 14) {
          HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search games", text: $query).textFieldStyle(.plain)
            if !query.isEmpty {
              Button {
                query = ""
              } label: {
                Image(systemName: "xmark.circle.fill")
              }
              .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear search")
            }
          }.padding(12).background(LibraryTheme.panel, in: RoundedRectangle(cornerRadius: 8))
          Menu {
            Button("Name A–Z") { recentSort = false }
            Button("Recently played / added") { recentSort = true }
          } label: {
            Image(systemName: "arrow.up.arrow.down").frame(width: 34, height: 34)
          }
          .menuStyle(.borderlessButton).fixedSize().help("Sort order")
          Text(L10n.format(visible.count == 1 ? "%lld game" : "%lld games", visible.count))
            .font(.caption).foregroundStyle(.secondary).fixedSize()
        }
        if library.pendingImports > 0 {
          HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Importing games and original icons …").font(.caption).foregroundStyle(
              .secondary)
          }
        }
        if let error = library.error {
          HStack(alignment: .top) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(error).font(.caption).textSelection(.enabled)
            Spacer()
            Button {
              library.error = nil
            } label: {
              Image(systemName: "xmark")
            }.buttonStyle(.plain)
          }.padding(12).background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        }
        if visible.isEmpty {
          VStack(spacing: 16) {
            Image(systemName: library.games.isEmpty ? "square.stack.3d.up" : "magnifyingglass")
              .font(.system(size: 42, weight: .light)).foregroundStyle(LibraryTheme.accent)
            Text(library.games.isEmpty ? L10n.text("Room for your games") : L10n.text("No games found"))
              .font(.title2.weight(.semibold))
            Text(
              library.games.isEmpty
                ? L10n.text("Add your Zeebo ZIPs or drag them into this window.\nYour games remain in their current location.")
                : L10n.text("Try a different search or view.")
            )
            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if library.games.isEmpty {
              Button("Choose Games …") { library.chooseFiles() }.buttonStyle(.bordered)
            }
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ScrollView {
            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: 220, maximum: 330), spacing: 20)],
              alignment: .leading, spacing: 22
            ) {
              ForEach(visible) { game in
                GameLibraryCard(
                  game: game, onPlay: { onPlay(game) }, onFavorite: { library.toggleFavorite(game) },
                  onSettings: { settingsGame = game }
                )
                .contextMenu {
                  Button("Play", systemImage: "play.fill") { onPlay(game) }
                  Button("Settings …", systemImage: "gearshape") { settingsGame = game }
                  Button(
                    game.favorite ? L10n.text("Remove from Favorites") : L10n.text("Mark as Favorite"),
                    systemImage: "star"
                  ) { library.toggleFavorite(game) }
                  Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([game.resolvedURL()])
                  }
                  Divider()
                  Button("Remove from Library", systemImage: "minus.circle") {
                    library.remove(game)
                  }
                }
              }
            }.padding(.top, 3).padding(.bottom, 24)
          }
        }
      }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(LibraryTheme.background)
    .tint(.gray)
    .sheet(item: $settingsGame) { game in
      GameSettingsView(game: game, controllerSettings: controllerSettings,
        onControllerEditing: onControllerEditing)
    }
    .overlay {
      if dropping {
        RoundedRectangle(cornerRadius: 14).strokeBorder(
          LibraryTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [8])
        )
        .padding(10).allowsHitTesting(false)
      }
    }
    .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
      for provider in providers {
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
          if let url { DispatchQueue.main.async { library.add([url]) } }
        }
      }
      return !providers.isEmpty
    }
  }
  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 30) {
      VStack(alignment: .leading, spacing: 7) {
        Text("LIBRARY").font(.system(size: 9, weight: .bold)).tracking(1.7).foregroundStyle(
          .secondary
        ).padding(.leading, 12).padding(.bottom, 6)
        ForEach(Section.allCases, id: \.self) { item in
          Button {
            section = item
          } label: {
            HStack(spacing: 11) {
              Image(systemName: item.symbol).frame(width: 18)
              Text(item.title).font(
                .system(size: 12, weight: section == item ? .semibold : .regular))
              Spacer(minLength: 0)
            }.padding(.horizontal, 12).padding(.vertical, 12)
              .foregroundStyle(section == item ? Color.primary : Color.secondary)
              .background(
                section == item ? Color.primary.opacity(0.08) : .clear,
                in: RoundedRectangle(cornerRadius: 10))
          }.buttonStyle(.plain)
        }
      }
      Spacer()
    }.padding(20).frame(width: 200).background(.bar)
      .overlay(alignment: .trailing) { Divider() }
  }
}

private struct GameLibraryCard: View {
  let game: LibraryGame
  let onPlay: () -> Void
  let onFavorite: () -> Void
  let onSettings: () -> Void
  @State private var hovering = false
  var body: some View {
    Button(action: onPlay) {
      VStack(alignment: .leading, spacing: 0) {
        ZStack {
          LibraryTheme.artwork
          if let bytes = game.artwork, let image = NSImage(data: bytes) {
            Image(nsImage: image).resizable().interpolation(game.artworkWidth < 100 ? .none : .high)
              .scaledToFit().padding(32)
          } else {
            Image(systemName: "gamecontroller.fill").font(.system(size: 50, weight: .light))
              .foregroundStyle(.tertiary)
          }
        }.aspectRatio(1.35, contentMode: .fit).overlay(alignment: .topLeading) {
          Text("ZEEBO").font(.system(size: 8, weight: .heavy)).tracking(1.6).foregroundStyle(
            Color.secondary
          ).padding(14)
        }
        VStack(alignment: .leading, spacing: 9) {
          Text(game.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
            .multilineTextAlignment(.leading)
          Text(game.publisher.isEmpty ? "Zeebo" : game.publisher).font(.system(size: 10))
            .foregroundStyle(.secondary).lineLimit(1)
          HStack {
            if let date = game.lastPlayed {
              Text(date, style: .relative).font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
              Text("Not played yet").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
            Label("Play", systemImage: "play.fill").font(.system(size: 11, weight: .semibold))
              .foregroundStyle(LibraryTheme.accent)
          }.padding(.top, 9)
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
      }.background(LibraryTheme.panel).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
          RoundedRectangle(cornerRadius: 12).strokeBorder(
            hovering ? Color.primary.opacity(0.25) : LibraryTheme.separator.opacity(0.5), lineWidth: 1)
        )
    }.buttonStyle(.plain).accessibilityLabel(L10n.format("Play %@", game.title))
      .overlay(alignment: .topTrailing) {
        HStack(spacing: 6) {
        Button(action: onSettings) {
          Image(systemName: "gearshape")
            .font(.system(size: 12))
            .foregroundStyle(Color.secondary)
            .frame(width: 28, height: 28).background(LibraryTheme.panel.opacity(0.95), in: Circle())
        }.buttonStyle(.plain).help(L10n.format("Settings for %@", game.title))
          .accessibilityLabel(L10n.format("Settings for %@", game.title))
        Button(action: onFavorite) {
          Image(systemName: game.favorite ? "star.fill" : "star").font(.system(size: 12))
            .foregroundStyle(game.favorite ? Color.primary : Color.secondary)
            .frame(width: 28, height: 28).background(LibraryTheme.panel.opacity(0.95), in: Circle())
        }.buttonStyle(.plain).help(
          game.favorite ? L10n.text("Remove Favorite") : L10n.text("Mark as Favorite"))
        }.padding(10)
      }
      .animation(.easeOut(duration: 0.12), value: hovering)
      .onHover { hovering = $0 }
  }
}


struct GameSettingsView: View {
  let game: LibraryGame
  @ObservedObject var controllerSettings: ControllerSettingsModel
  var onControllerEditing: (Bool) -> Void = { _ in }
  @Environment(\.dismiss) private var dismiss
  @State private var section = Section.display
  private enum Section { case display, controller }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        if let bytes = game.artwork, let icon = NSImage(data: bytes) {
          Image(nsImage: icon).resizable().scaledToFit().frame(width: 48, height: 48)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text(game.title).font(.title3.weight(.semibold)).lineLimit(2)
          Text("Game Settings").font(.subheadline).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }.padding(20)
      Picker("Settings", selection: $section) {
        Text("Display").tag(Section.display)
        Text("Controller").tag(Section.controller)
      }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.bottom, 14)
      Divider()
      Group {
        switch section {
        case .display:
          DisplaySettingsView(game: game)
        case .controller:
          ControllerSettingsView(settings: controllerSettings, game: game, embedded: true,
            onEditingChange: onControllerEditing)
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }.frame(width: 650, height: 800)
      .background(LibraryTheme.background).tint(.gray)
  }
}

/// A fixed scope: app defaults or the game whose library context menu opened this view.
struct DisplaySettingsView: View {
  var game: LibraryGame? = nil
  var onScalingChange: () -> Void = { }
  @State private var msaaValue = 1
  private let msaa = MSAAPreferences()
  @State private var resolutionValue = 1
  @State private var pixelValue = 0
  @State private var windowValue = 0
  @State private var metalFXValue = 0
  private let metalFX = MetalFXPreferences()
  @AppStorage("showFPS") private var showFPS = false
  private let resolutions = RenderResolutionPreferences()
  private let scaling = PixelScalingPreferences()
  private let windowScaling = WindowScalingPreferences()
  private let testFPS = ProcessInfo.processInfo.environment["ZEESWIFT_TEST_FPS"] == "1"
  @AppStorage(SeparateGameWindowPreferences.storageKey) private var separateGameWindow = false
  private func load() {
    msaaValue = game.map { msaa.override(for: $0.classID)?.rawValue ?? 0 } ?? msaa.mode().rawValue
    metalFXValue = game.map { metalFX.override(for: $0.classID)?.rawValue ?? -1 } ?? metalFX.mode().rawValue
    windowValue = game.map { windowScaling.override(for: $0.classID)?.rawValue ?? -1 }
      ?? windowScaling.mode().rawValue
    resolutionValue = game.map { resolutions.override(for: $0.classID)?.rawValue ?? 0 }
      ?? resolutions.resolution().rawValue
    pixelValue = game.map { game in
      scaling.override(for: game.classID).map { $0 ? 1 : 0 } ?? -1
    } ?? (scaling.enabled() ? 1 : 0)
  }
  private func saveScaling(_ value: Int) {
    pixelValue = value
    scaling.set(value == -1 ? nil : value == 1, for: game?.classID)
    onScalingChange()
  }
  var body: some View {
    Form {
      if game == nil {
        Section("Display") {
          Toggle("Open games in a separate window", isOn: $separateGameWindow)
          Text("The separate window shows only the game. It does not show library controls, the ZeeSwift FPS counter, errors, or diagnostics. Applies from the next game start.")
            .font(.caption).foregroundStyle(.secondary)
          Toggle("Show FPS counter", isOn: Binding(
            get: { showFPS || testFPS }, set: { showFPS = $0 }))
            .disabled(testFPS)
            .keyboardShortcut("f", modifiers: [.command, .shift])
          Text(testFPS ? L10n.text("The FPS counter remains enabled during a test run.")
            : L10n.text("Shows the frame rate in the top-right corner while playing."))
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Section("Window Scaling") {
        Picker("Image size", selection: Binding(get: { windowValue }, set: { value in
          windowValue = value
          windowScaling.set(WindowScaling(rawValue: value), for: game?.classID)
          onScalingChange()
        })) {
          if game != nil { Text("Use Global Default").tag(-1) }
          Text("Keep aspect ratio (4:3)").tag(WindowScaling.preserveAspect.rawValue)
          Text("Fill window").tag(WindowScaling.fill.rawValue)
        }
        Text("Fill window stretches the image to the available width and height without adding black bars. Applies immediately while playing.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("MetalFX") {
        Picker("Upscaling", selection: Binding(get: { metalFXValue }, set: { value in
          metalFXValue = value
          metalFX.set(MetalFXMode(rawValue: value), for: game?.classID)
          onScalingChange()
        })) {
          if game != nil { Text("Use Global Default").tag(-1) }
          Text("Disabled").tag(0)
          Text("MetalFX Spatial").tag(1)
          if Metal4Renderer.supportsTemporal { Text("MetalFX Temporal").tag(2) }
        }
        .disabled(!Metal4Renderer.supportsMetalFX)
        if metalFXValue == 2 {
          Text("Temporal uses depth and motion from 3D rendering. Images without valid temporal data use Spatial automatically.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Text(Metal4Renderer.supportsMetalFX
          ? L10n.text("Upscales the game image when the window is larger than the internal resolution. Applies immediately. Pixel-perfect texture scaling remains a separate setting.")
          : L10n.text("MetalFX is not supported on this Mac."))
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Anti-Aliasing") {
        Picker("MSAA", selection: Binding(get: { msaaValue }, set: { value in
          msaaValue = value
          msaa.set(MSAA(rawValue: value), for: game?.classID)
        })) {
          if game != nil { Text("Use Global Default").tag(0) }
          Text("Disabled").tag(1)
          Text("2×").tag(2)
          Text("4×").tag(4)
        }
        Text("Smooths 3D geometry edges. Applies when the game next starts. Higher sample counts use more GPU memory and processing time.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Internal Resolution") {
        Picker("Resolution", selection: Binding(get: { resolutionValue }, set: { value in
          resolutionValue = value
          resolutions.set(RenderResolution(rawValue: value), for: game?.classID)
        })) {
          if game != nil {
            Text(L10n.format("Use global default (%@)", resolutions.resolution().label)).tag(0)
          }
          ForEach(RenderResolution.allCases) { resolution in
            Text(resolution.label).tag(resolution.rawValue)
          }
        }
        Text("Applies when the game next starts. Higher resolutions sharpen 3D geometry; original textures and 2D artwork keep their original detail.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Scaling") {
        if game != nil {
          Picker("Pixel-perfect scaling", selection: Binding(get: { pixelValue }, set: saveScaling)) {
            Text("Use Global Default").tag(-1)
            Text("Enabled").tag(1)
            Text("Disabled").tag(0)
          }
        } else {
          Toggle("Pixel-perfect scaling", isOn: Binding(
            get: { pixelValue == 1 }, set: { saveScaling($0 ? 1 : 0) }))
        }
        Text("Enlarges the image without additional smoothing.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section {
        Text(game == nil
          ? L10n.text("Defaults for games without custom settings. Right-click a game in the library to configure it individually.")
          : L10n.text("Saved automatically for this game. Other games keep their own settings."))
          .font(.caption).foregroundStyle(.secondary)
      }
    }.formStyle(.grouped).onAppear(perform: load)
  }
}
