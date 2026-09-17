import Foundation
import ImageIO

/// Original MIF resource inspection; artwork stays in the user's local library.
struct GameLibraryMetadata: Sendable {
  let url: URL
  let title: String
  let publisher: String
  let classID: UInt32
  let artwork: Data?
  let artworkWidth: Int
  let artworkHeight: Int

  init(url: URL) throws {
    try self.init(package: GamePackage(url: url))
  }
  init(package: GamePackage) throws {
    let url = package.url
    self.url = url.standardizedFileURL
    title = package.title.replacingOccurrences(
      of: " - Zeebo Edition", with: "", options: .caseInsensitive)
    classID = package.classID
    let resources = package.resources
    let resourceBase = resources.appletResourceBase(classID: package.classID)
    let associatedIDs: Set<UInt16> = Set((1...3).compactMap { offset in
      guard let resourceBase, Int(resourceBase) + offset <= 65535 else { return nil }
      let id = resourceBase + UInt16(offset)
      return resources.resource(type: 6, id: id) == nil ? nil : id
    })
    publisher = resources.stringUnits(id: 6).map { String(decoding: $0, as: UTF16.self) } ?? ""
    var largest: (Data, Int, Int)?
    let images = resources.entries.filter { $0.type == 6 }.flatMap { entry in
      (0...entry.additionalIDs).compactMap {
        let id = entry.firstID + UInt16($0)
        // A MIF may contain artwork for several applets. Use this applet's icon/image/thumb.
        // Some shipped MIFs (e.g. Double Dragon) have a stale base. With no matching
        // resources, retain the existing largest-image fallback instead of losing the icon.
        if !associatedIDs.isEmpty && !associatedIDs.contains(id) {
          return nil as Data?
        }
        return resources.resource(type: 6, id: id)
      }
    }
    for bytes in images {
      guard bytes.count >= 2 else { continue }
      let start = Int(try bytes.u16(0))
      guard start >= 3, start < bytes.count, bytes.count - start <= 2 * 1024 * 1024 else {
        continue
      }
      let image = try bytes.checked(start, bytes.count - start)
      guard let source = CGImageSourceCreateWithData(image as CFData, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int,
        (1...1024).contains(width), (1...1024).contains(height),
        CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
      else { continue }
      if width * height > (largest.map { $0.1 * $0.2 } ?? 0) { largest = (image, width, height) }
    }
    artwork = largest?.0
    artworkWidth = largest?.1 ?? 0
    artworkHeight = largest?.2 ?? 0
  }
}

struct BREWCopyrightInfo: Sendable, Identifiable {
  let id = UUID()
  let title: String
  let publisher: String
  let copyright: String
  let version: String
  let artwork: Data?
  init(package: GamePackage) throws {
    let resources = package.resources
    func text(_ id: UInt16) -> String {
      resources.stringUnits(id: id).map { String(decoding: $0, as: UTF16.self) } ?? ""
    }
    let originalTitle = resources.appletResourceBase(classID: package.classID).map(text) ?? ""
    title = originalTitle.isEmpty ? package.title : originalTitle
    publisher = text(6)
    copyright = text(7)
    version = text(8)
    artwork = try GameLibraryMetadata(package: package).artwork
  }
}

struct LibraryGame: Codable, Identifiable, Sendable {
  var id = UUID()
  var url: URL
  var bookmark: Data?
  var title: String
  var publisher: String
  var classID: UInt32
  var artwork: Data?
  var artworkWidth: Int
  var artworkHeight: Int
  var addedAt = Date()
  var lastPlayed: Date?
  var favorite = false

  init(metadata: GameLibraryMetadata) {
    url = metadata.url
    bookmark = try? url.bookmarkData(
      options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    title = metadata.title
    publisher = metadata.publisher.trimmingCharacters(in: .controlCharacters)
    classID = metadata.classID
    artwork = metadata.artwork
    artworkWidth = metadata.artworkWidth
    artworkHeight = metadata.artworkHeight
  }
  func resolvedURL() -> URL {
    guard let bookmark else { return url }
    var stale = false
    return
      (try? URL(
        resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
        bookmarkDataIsStale: &stale)) ?? url
  }
}

struct GameLibraryStore {
  let fileURL: URL
  static func applicationStore() throws -> Self {
    let root = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    return Self(fileURL: root.appendingPathComponent("ZeeSwift/library.json"))
  }
  func load() throws -> [LibraryGame] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 64 * 1024 * 1024 else { throw EmulationError.invalid("Library too large") }
    let games = try JSONDecoder().decode([LibraryGame].self, from: Data(contentsOf: fileURL))
    try validate(games)
    return games
  }
  func save(_ games: [LibraryGame]) throws {
    try validate(games)
    let data = try JSONEncoder().encode(games)
    guard data.count <= 64 * 1024 * 1024 else { throw EmulationError.invalid("Library too large") }
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: fileURL, options: .atomic)
  }
  private func validate(_ games: [LibraryGame]) throws {
    guard games.count <= 1000, Set(games.map(\.id)).count == games.count,
      Set(games.map(\.classID)).count == games.count,
      games.allSatisfy({
        $0.url.isFileURL && $0.title.count <= 512 && ($0.artwork?.count ?? 0) <= 2 * 1024 * 1024
      })
    else { throw EmulationError.invalid("Library data") }
  }
}
