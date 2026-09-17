import Foundation

/// Counts published guest images against a monotonic host clock, never display refreshes.
struct FrameRateCounter {
  struct Sample: Codable, Sendable {
    let elapsedSeconds: Double
    let durationSeconds: Double
    let frames: UInt64
    var fps: Double { Double(frames) / durationSeconds }
  }
  struct Snapshot: Codable, Sendable {
    let fps: Double
    let averageFPS: Double
    let elapsedSeconds: Double
    let frames: UInt64
    let running: Bool
    let samples: [Sample]
  }
  private let start: Double
  private var windowStart: Double
  private var stoppedAt: Double?
  private var windowFrames: UInt64 = 0
  private var totalFrames: UInt64 = 0
  private var samples: [Sample] = []
  init(now: Double) { start = now; windowStart = now }
  private mutating func advance(to now: Double) {
    let duration = now - windowStart
    guard duration >= 1 else { return }
    samples.append(Sample(elapsedSeconds: now - start, durationSeconds: duration, frames: windowFrames))
    if samples.count > 600 { samples.removeFirst() }
    windowStart = now
    windowFrames = 0
  }
  mutating func record(now: Double) {
    guard stoppedAt == nil else { return }
    advance(to: now)
    windowFrames &+= 1
    totalFrames &+= 1
  }
  mutating func stop(now: Double) { if stoppedAt == nil { stoppedAt = now } }
  mutating func snapshot(now: Double) -> Snapshot {
    let time = stoppedAt ?? now
    advance(to: time)
    let elapsed = max(0, time - start)
    // Wait for a full interval instead of showing a spike immediately after the first image.
    let rate = samples.last?.fps ?? 0
    return Snapshot(fps: stoppedAt == nil ? rate : 0,
      averageFPS: elapsed > 0 ? Double(totalFrames) / elapsed : 0,
      elapsedSeconds: elapsed, frames: totalFrames, running: stoppedAt == nil, samples: samples)
  }
}

/// BGRA pixels and dimensions travel together across threads.
struct RenderedFrame: Sendable {
  let pixels: Data
  var width = 640
  var height = 480
  var temporal: TemporalFrame? = nil
  var isValid: Bool {
    (1...4).contains(width / 640) && width % 640 == 0
      && height == (width / 640) * 480 && pixels.count == width * height * 4
      && (temporal == nil || (temporal!.isValid && temporal!.width == width && temporal!.height == height))
  }
}

/// A snapshot crossing from the single emulation worker to the presentation thread.
final class FrameStore: @unchecked Sendable {
  static let width = 640, height = 480
  private let lock = NSLock()
  private var frame = RenderedFrame(pixels: Data(repeating: 0, count: width * height * 4))
  private var sequence: UInt64 = 0
  private var session: UUID?
  private var frameRate: FrameRateCounter?
  // Allocate the identity before dispatching guest startup to its worker queue.
  func beginSession() -> UUID {
    lock.lock()
    defer { lock.unlock() }
    let id = UUID()
    session = id
    frameRate = FrameRateCounter(now: ProcessInfo.processInfo.systemUptime)
    frame = RenderedFrame(pixels: Data(repeating: 0, count: Self.width * Self.height * 4))
    sequence &+= 1
    return id
  }
  func endSession(_ id: UUID) {
    lock.lock()
    defer { lock.unlock() }
    // Cleanup from an older worker must not revoke a newer game's writer.
    if session == id {
      frameRate?.stop(now: ProcessInfo.processInfo.systemUptime)
      session = nil
    }
  }
  @discardableResult func publish(_ data: Data, session id: UUID) -> Bool {
    publish(RenderedFrame(pixels: data), session: id)
  }
  @discardableResult func publish(_ frame: RenderedFrame, session id: UUID) -> Bool {
    guard frame.isValid else { return false }
    lock.lock()
    defer { lock.unlock() }
    guard session == id else { return false }
    self.frame = frame
    sequence &+= 1
    frameRate?.record(now: ProcessInfo.processInfo.systemUptime)
    return true
  }
  func performance() -> FrameRateCounter.Snapshot? {
    lock.lock()
    defer { lock.unlock() }
    return frameRate?.snapshot(now: ProcessInfo.processInfo.systemUptime)
  }
  func snapshot() -> (Data, UInt64) {
    lock.lock()
    defer { lock.unlock() }
    return (frame.pixels, sequence)
  }
  func presentationSnapshot() -> (frame: RenderedFrame, sequence: UInt64) {
    lock.lock()
    defer { lock.unlock() }
    return (frame, sequence)
  }
}

/// Immutable auxiliary rendering data. Never substituted for guest-visible pixels.
struct TemporalFrame: Sendable {
  let color: Data
  let depth: Data                 // r32Float, canonical near=0/far=1
  let motion: Data                // rg16Float, current -> previous, input pixels
  let reactive: Data              // r8Unorm, 1 rejects unreliable history
  let width: Int
  let height: Int
  let jitter: SIMD2<Float>        // input pixels, positive right/down
  let generation: UUID
  let index: UInt64
  let reset: Bool
  var isValid: Bool {
    width > 0 && height > 0 && width <= 2560 && height <= 1920
      && color.count == width * height * 4 && depth.count == width * height * 4
      && motion.count == width * height * 4 && reactive.count == width * height
      && jitter.x.isFinite && jitter.y.isFinite
  }
}
