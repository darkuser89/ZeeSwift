import Foundation

/// Owns the guest on one queue. UI cancellation never races with guest memory access.
final class EmulationSession: @unchecked Sendable {
  struct Update: Sendable {
    let status: String
    let report: String
    let error: String?
    var completed = false
  }
  private let queue = DispatchQueue(label: "ZeeSwift.Guest", qos: .userInitiated)
  private let cancellation = EmulationCancellation()
  private let onVibration: @Sendable (UInt16) -> Void
  private let onCopyright: (@Sendable (BREWCopyrightInfo?) -> Void)?
  private var copyright: BREWCopyrightInfo?
  private var dialogInput = ShellDialogInput()
  private var inputRouter: MultiplayerInputRouter
  private var physicalButtons = [Set<ControllerInput>(), Set<ControllerInput>()]
  private var keyboardKeys = Set<UInt16>()
  private var editingController = false
  private var temporalEnabled: Bool
  private var pixelExactMagnification: Bool
  private let msaa: MSAA
  private let renderResolution: RenderResolution
  private let saveStoreFactory: @Sendable (UInt32) throws -> GameSaveStore?
  private let frames: FrameStore
  private let frameSession: UUID
  private var runtime: BREWRuntime?
  private var onUpdate: ((Update) -> Void)?
  private var lastUpdate: TimeInterval = 0
  private var scheduled: DispatchSourceTimer?
  private var timerGeneration: UInt64 = 0
  init(frames: FrameStore, controllerMapping: ControllerMapping = .standard,
    playerInputs: [PlayerInputConfiguration]? = nil, connectedControllers: Set<Int> = [],
    pixelExactMagnification: Bool = false, temporalEnabled: Bool = false, renderResolution: RenderResolution = .native, msaa: MSAA = .off,
    onCopyright: (@Sendable (BREWCopyrightInfo?) -> Void)? = nil,
    saveStoreFactory: @escaping @Sendable (UInt32) throws -> GameSaveStore? = {
      try GameSaveStore.applicationStore(classID: $0)
    },
    onVibration: @escaping @Sendable (UInt16) -> Void = { _ in }) {
    self.onVibration = onVibration
    var defaults = MultiplayerPreferences().global
    defaults[0].controller = controllerMapping
    self.inputRouter = MultiplayerInputRouter(configurations: playerInputs ?? defaults,
      connectedSlots: connectedControllers)
    self.temporalEnabled = temporalEnabled
    self.pixelExactMagnification = pixelExactMagnification
    self.msaa = msaa
    self.renderResolution = renderResolution
    self.onCopyright = onCopyright
    self.saveStoreFactory = saveStoreFactory
    self.frames = frames
    frameSession = frames.beginSession()
  }
  func stop() {
    cancellation.cancel()
    onVibration(0)
    frames.endSession(frameSession)
    queue.async { [self] in
      copyright = nil
      onCopyright?(nil)
      scheduled?.cancel()
      scheduled = nil
      if let runtime {
        for object in runtime.media.values { object.player?.stop() }
      }
      runtime = nil
    }
  }
  func sendButton(_ button: Int, down: Bool) {
    queue.async { [self] in
      guard !isCancelled, let runtime else { return }
      let input = dialogInput.button(button, down: down)
      if input.dismiss { closeCopyright() }
      guard input.forward else { return }
      runtime.setButton(button, down: down)
      scheduleNext()
    }
  }
  func sendControllerState(_ state: NativeControllerState) {
    queue.async { [self] in
      guard !isCancelled, let runtime else { return }
      let input = dialogInput.controller(state)
      if input.dismiss { closeCopyright() }
      guard let state = input.state else { return }
      runtime.setControllerState(state)
      scheduleNext()
    }
  }
  func sendPhysicalControllerState(_ state: PhysicalControllerState, slot: Int = 0, connected: Bool = true) {
    queue.async { [self] in
      guard !isCancelled, (0..<2).contains(slot) else { return }
      let pressed = state.buttons.subtracting(physicalButtons[slot])
      physicalButtons[slot] = state.buttons
      inputRouter.setPhysical(state, slot: slot, connected: connected)
      guard let runtime else { return }
      if copyright != nil || editingController {
        inputRouter.suppress(classID: runtime.package.classID)
        let assigned = inputRouter.configurations.contains { $0.source.usesController && $0.controllerSlot == slot }
        if assigned && copyright != nil && !editingController && !pressed.isDisjoint(with: [.south, .menu, .home, .options]) {
          closeCopyright()
        }
      }
      applyInputs()
    }
  }
  func sendKeyboardKeys(_ keys: Set<UInt16>) {
    queue.async { [self] in
      guard !isCancelled else { return }
      let pressed = keys.subtracting(keyboardKeys)
      keyboardKeys = keys
      inputRouter.setKeys(keys)
      guard let runtime else { return }
      if copyright != nil || editingController {
        let dismiss = inputRouter.configurations.contains {
          $0.source.usesKeyboard && !$0.keyboardState(pressed, classID: runtime.package.classID).buttons.isDisjoint(with: [1,8,9])
        }
        inputRouter.suppress(classID: runtime.package.classID)
        if copyright != nil && !editingController && dismiss { closeCopyright() }
      }
      applyInputs()
    }
  }
  private func applyInputs() {
    guard let runtime else { return }
    for player in 0..<2 {
      runtime.setControllerConnected(inputRouter.connected(player: player), player: player)
      let state = inputRouter.state(player: player, classID: runtime.package.classID)
      runtime.setControllerState(copyright != nil || editingController ? .init() : state, player: player)
    }
    scheduleNext()
  }
  private func suppressInputs() {
    inputRouter.suppress(classID: runtime?.package.classID ?? 0)
    for player in 0..<2 { runtime?.setControllerState(.init(), player: player) }
  }
  func setPlayerInputs(_ configurations: [PlayerInputConfiguration]) {
    queue.async { [self] in
      guard !isCancelled else { return }
      inputRouter.replace(configurations, classID: runtime?.package.classID ?? 0)
      applyInputs()
    }
  }
  func setControllerMapping(_ mapping: ControllerMapping) {
    queue.async { [self] in
      guard !isCancelled else { return }
      var configs = inputRouter.configurations
      configs[0].controller = mapping
      inputRouter.replace(configs, classID: runtime?.package.classID ?? 0)
      applyInputs()
    }
  }
  func setTemporalEnabled(_ enabled: Bool) {
    queue.async { [self] in
      guard !isCancelled else { return }
      temporalEnabled = enabled
      (runtime?.gl.backend as? Metal4GLESRenderer)?.temporalCaptureEnabled = enabled
    }
  }
  func setPixelExactMagnification(_ enabled: Bool) {
    queue.async { [self] in
      guard !isCancelled else { return }
      pixelExactMagnification = enabled
      (runtime?.gl.backend as? Metal4GLESRenderer)?.pixelExactMagnification = enabled
    }
  }
  func setControllerEditing(_ editing: Bool) {
    queue.async { [self] in
      guard !isCancelled else { return }
      editingController = editing
      suppressInputs()
      if runtime != nil { scheduleNext() }
    }
  }
  func dismissCopyright() {
    queue.async { [self] in
      guard !isCancelled else { return }
      closeCopyright()
    }
  }
  private func closeCopyright() {
    guard copyright != nil else { return }
    copyright = nil
    dialogInput.end()
    suppressInputs()
    onCopyright?(nil)
    scheduleNext()
  }
  private var isCancelled: Bool {
    cancellation.isCancelled
  }
  func start(url: URL, onUpdate: @escaping (Update) -> Void) {
    queue.async { [self] in
      guard !isCancelled else { return }
      self.onUpdate = onUpdate
      do {
        let package = try GamePackage(url: url)
        try cancellation.check()
        let saves = try saveStoreFactory(package.classID)
        let guest = try BREWRuntime(
          package: package, frames: frames, saveStore: saves, cancellation: cancellation,
          frameSession: frameSession)
        runtime = guest
        for player in 0..<2 { guest.setControllerConnected(inputRouter.connected(player: player), player: player) }
        guest.onVibration = onVibration
        guest.onCopyright = { [weak self, weak guest] info in
          guard let self, let guest, !self.isCancelled, let presenter = self.onCopyright,
            self.copyright == nil else { return false }
          for button in self.dialogInput.begin() { guest.setButton(button, down: false) }
          self.suppressInputs()
          self.copyright = info
          presenter(info)
          return true
        }
        guest.executionPolicy = .cancellable
        let renderer = try Metal4GLESRenderer(renderScale: renderResolution.rawValue, sampleCount: msaa.rawValue)
        renderer.pixelExactMagnification = pixelExactMagnification
        renderer.temporalCaptureEnabled = temporalEnabled
        guest.gl.backend = renderer
        guest.cpu.tracing = true
        try guest.boot()
        try guest.createApplet()
        try guest.event(0)
        onUpdate(Update(status: L10n.text("Emulation running"), report: guest.report, error: nil))
        scheduleNext()
      } catch { finish(error) }
    }
  }
  private func scheduleNext() {
    timerGeneration &+= 1
    scheduled?.cancel()
    scheduled = nil
    guard !isCancelled, let runtime else {
      self.runtime = nil
      return
    }
    do { try runtime.pumpMedia() } catch {
      finish(error)
      return
    }
    guard runtime.nextTimerDelay != nil || runtime.hasPendingMedia else {
      onUpdate?(
        Update(status: L10n.text("Emulation waiting for events"), report: runtime.report, error: nil))
      return
    }
    let delay = min(runtime.nextTimerDelay ?? 60_000, runtime.hasPendingMedia ? 10 : 60_000)
    let generation = timerGeneration
    // Avoid host timer coalescing stretching every guest frame. The runtime
    // still checks the guest deadline before delivering any callback.
    let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
    timer.setEventHandler { [weak self] in
      guard let self, self.timerGeneration == generation else { return }
      self.tick()
    }
    timer.schedule(deadline: .now() + .milliseconds(Int(delay)), leeway: .nanoseconds(0))
    scheduled = timer
    timer.activate()
  }
  private func tick() {
    scheduled?.cancel()
    scheduled = nil
    guard !isCancelled else {
      self.runtime = nil
      return
    }
    guard let runtime else { return }
    do {
      try runtime.pumpTimers(onlyDue: true)
      let now = ProcessInfo.processInfo.systemUptime
      if now - lastUpdate >= 0.5 {
        lastUpdate = now
        onUpdate?(
          Update(
            status: L10n.format("Emulation running · %lld frames", runtime.guestFrames), report: runtime.report,
            error: nil))
      }
      scheduleNext()
    } catch { finish(error) }
  }
  private func finish(_ error: Error) {
    let closed: Bool
    if case EmulationError.appletClosed = error { closed = true } else { closed = false }
    copyright = nil
    onCopyright?(nil)
    onVibration(0)
    frames.endSession(frameSession)
    scheduled?.cancel()
    scheduled = nil
    if let runtime {
      for object in runtime.media.values { object.player?.stop() }
    }
    if !isCancelled {
      onUpdate?(
        Update(
          status: closed ? L10n.text("Game ended") : L10n.text("Emulation paused"), report: runtime?.report ?? "",
          error: closed ? nil : error.localizedDescription, completed: closed))
    }
    runtime = nil
  }
}
