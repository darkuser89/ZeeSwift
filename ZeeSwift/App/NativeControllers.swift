import AppKit
import CoreHaptics
import GameController

@MainActor final class NativeControllers {
  var onState: ((Int, PhysicalControllerState, Bool) -> Void)?
  var onName: ((String) -> Void)?
  private var observers: [NSObjectProtocol] = []
  private var slots: [GCController?] = [nil, nil]
  private var hapticSlot = 0
  var connectedSlots: Set<Int> { Set(slots.indices.filter { slots[$0] != nil }) }
  private let availableControllers: () -> [GCController]
  private var hapticEngine: CHHapticEngine?
  private var hapticPlayer: CHHapticPatternPlayer?
  private var foreground = true
  init(availableControllers: @escaping () -> [GCController] = { GCController.controllers() }) {
    self.availableControllers = availableControllers
    foreground = NSApplication.shared.isActive
    GCController.shouldMonitorBackgroundEvents = false
    let center = NotificationCenter.default
    for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.refreshControllers() }
        })
    }
    observers.append(
      center.addObserver(
        forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.foreground = false
          self?.stopVibration()
          self?.publish()
        }
      })
    observers.append(
      center.addObserver(
        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.foreground = true
          self?.publish()
        }
      })
  }
  deinit {
    try? hapticPlayer?.stop(atTime: CHHapticTimeImmediate)
    hapticEngine?.stop(completionHandler: nil)
    for controller in slots { controller?.extendedGamepad?.valueChangedHandler = nil }
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }
  func refreshControllers() {
    let available = availableControllers().filter { $0.extendedGamepad != nil }
    for slot in 0..<2 {
      if let old = slots[slot], !available.contains(where: { $0 === old }) {
        old.extendedGamepad?.valueChangedHandler = nil
        old.playerIndex = .indexUnset
        if slot == hapticSlot {
          stopVibration()
          hapticEngine?.stop(completionHandler: nil)
          hapticEngine = nil
        }
        slots[slot] = nil
        onState?(slot, PhysicalControllerState(), false)
      }
    }
    for controller in available where !slots.contains(where: { $0 === controller }) {
      guard let slot = slots.firstIndex(where: { $0 == nil }) else { break }
      slots[slot] = controller
      controller.playerIndex = slot == 0 ? .index1 : .index2
      controller.handlerQueue = .main
      controller.extendedGamepad?.valueChangedHandler = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.publish() }
      }
    }
    onName?(slots.indices.map { slot in
      L10n.format("Controller %lld: %@", slot + 1,
        slots[slot].map { $0.vendorName ?? L10n.text("Connected") } ?? L10n.text("Not Connected"))
    }.joined(separator: " · "))
    publish()
  }
  func stopVibration() {
    try? hapticPlayer?.stop(atTime: CHHapticTimeImmediate)
    hapticPlayer = nil
  }
  func vibrate(milliseconds: UInt16, slot: Int = 0) {
    stopVibration()
    guard milliseconds > 0, foreground, slots.indices.contains(slot), let haptics = slots[slot]?.haptics else { return }
    if hapticSlot != slot {
      hapticEngine?.stop(completionHandler: nil)
      hapticEngine = nil
      hapticSlot = slot
    }
    if hapticEngine == nil {
      hapticEngine = haptics.createEngine(withLocality: .default)
      hapticEngine?.isAutoShutdownEnabled = true
    }
    guard let engine = hapticEngine else { return }
    do {
      try engine.start()
      let duration = Double(milliseconds) / 1000
      var events: [CHHapticEvent] = []
      var time: Double = 0
      // Keep each continuous event at most 30 s; BREW's uint16 duration can exceed that.
      while time < duration {
        let span = min(30, duration - time)
        events.append(CHHapticEvent(eventType: .hapticContinuous,
          parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)],
          relativeTime: time, duration: span))
        time += span
      }
      let pattern = try CHHapticPattern(events: events, parameters: [])
      let player = try engine.makePlayer(with: pattern)
      try player.start(atTime: CHHapticTimeImmediate)
      hapticPlayer = player
    } catch {
      // Unsupported/disconnected haptics must not interrupt guest execution.
      stopVibration()
      engine.stop(completionHandler: nil)
      hapticEngine = nil
    }
  }
  func publish() {
    for slot in 0..<2 {
      let state = foreground ? slots[slot]?.extendedGamepad.map(PhysicalControllerState.init(gamepad:)) : nil
      onState?(slot, state ?? PhysicalControllerState(), slots[slot] != nil)
    }
  }
}
