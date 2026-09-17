import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor final class LibraryModel: ObservableObject {
  @Published private(set) var games: [LibraryGame] = []
  @Published private(set) var pendingImports = 0
  @Published var message: String?
  @Published var error: String?
  private var store: GameLibraryStore?
  init() {
    do {
      let store = try GameLibraryStore.applicationStore()
      games = try store.load()
      self.store = store
    } catch { self.error = L10n.format("The library could not be loaded: %@", error.localizedDescription) }
  }
  func chooseFiles() {
    let panel = NSOpenPanel()
    panel.title = L10n.text("Add Zeebo Games")
    panel.prompt = L10n.text("Add")
    panel.allowedContentTypes = [.zip]
    panel.allowsMultipleSelection = true
    if panel.runModal() == .OK { add(panel.urls) }
  }
  func add(_ urls: [URL], completion: ((LibraryGame) -> Void)? = nil) {
    guard store != nil else { return }
    pendingImports += 1
    Task {
      defer { pendingImports -= 1 }
      var imported = 0
      var failures: [String] = []
      for url in urls {
        do {
          let metadata = try await Task.detached(priority: .userInitiated) {
            try GameLibraryMetadata(url: url)
          }.value
          var game = LibraryGame(metadata: metadata)
          var updated = games
          if let index = updated.firstIndex(where: { $0.classID == game.classID }) {
            game.id = updated[index].id
            game.addedAt = updated[index].addedAt
            game.lastPlayed = updated[index].lastPlayed
            game.favorite = updated[index].favorite
            updated[index] = game
          } else {
            updated.append(game)
          }
          try commit(updated)
          imported += 1
          completion?(game)
        } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
      }
      if imported > 0 {
        message = imported == 1
          ? L10n.text("Game added to the library") : L10n.format("%lld games added", imported)
      }
      if !failures.isEmpty { error = failures.joined(separator: "\n") }
    }
  }
  func toggleFavorite(_ game: LibraryGame) {
    update(game.id) { $0.favorite.toggle() }
  }
  func markPlayed(_ id: UUID) { update(id) { $0.lastPlayed = Date() } }
  func remove(_ game: LibraryGame) {
    do { try commit(games.filter { $0.id != game.id }) } catch {
      self.error = error.localizedDescription
    }
  }
  private func update(_ id: UUID, change: (inout LibraryGame) -> Void) {
    var updated = games
    guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
    change(&updated[index])
    do { try commit(updated) } catch { self.error = error.localizedDescription }
  }
  private func commit(_ updated: [LibraryGame]) throws {
    guard let store else { throw EmulationError.invalid("Library unavailable") }
    try store.save(updated)
    games = updated
  }
}
