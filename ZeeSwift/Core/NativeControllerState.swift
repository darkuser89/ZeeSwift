import Foundation
import GameController

/// A modal shell dialog consumes its input, including releases after dismissal.
struct ShellDialogInput {
  private(set) var presented = false
  private var controllerState = NativeControllerState()
  private var keyboardHeld = Set<Int>()
  private var blockedKeyboard = Set<Int>()
  private var blockedController = Set<Int>()
  mutating func begin() -> Set<Int> {
    presented = true
    blockedKeyboard.formUnion(keyboardHeld)
    blockedController.formUnion(controllerState.buttons)
    return keyboardHeld
  }
  mutating func end() { presented = false }
  mutating func button(_ button: Int, down: Bool) -> (forward: Bool, dismiss: Bool) {
    let pressed = down && !keyboardHeld.contains(button)
    if down { keyboardHeld.insert(button) } else { keyboardHeld.remove(button) }
    if presented {
      if down { blockedKeyboard.insert(button) } else { blockedKeyboard.remove(button) }
      return (false, pressed && [1, 8, 9].contains(button))
    }
    if blockedKeyboard.contains(button) {
      if !down { blockedKeyboard.remove(button) }
      return (false, false)
    }
    return (true, false)
  }
  mutating func controller(_ state: NativeControllerState) -> (state: NativeControllerState?, dismiss: Bool) {
    let pressed = state.buttons.subtracting(controllerState.buttons)
    controllerState = state
    blockedController.formIntersection(state.buttons)
    if presented {
      blockedController.formUnion(state.buttons)
      return (nil, !pressed.isDisjoint(with: [1, 8, 9]))
    }
    return (NativeControllerState(buttons: state.buttons.subtracting(blockedController),
      sticks: state.sticks, automaticHomeRouting: state.automaticHomeRouting), false)
  }
}

struct NativeControllerState: Sendable, Equatable {
  var buttons: Set<Int> = []
  var automaticHomeRouting = true
  // Native Apple coordinates: positive Y is up. The BREW adapter converts to HID coordinates.
  var sticks = SIMD4<Float>(repeating: 0)
  init(buttons: Set<Int> = [], sticks: SIMD4<Float> = .zero, automaticHomeRouting: Bool = true) {
    self.buttons = buttons
    self.sticks = sticks
    self.automaticHomeRouting = automaticHomeRouting
  }
  init(gamepad: GCExtendedGamepad) {
    let pressed: [(Int, Bool)] = [
      // Z-Pad labels on a PlayStation layout: 1=Cross, 2=Square,
      // 3=Triangle, 4=Circle. Guest HID indices are ordered 4,1,2,3.
      (0, gamepad.buttonB.isPressed), (1, gamepad.buttonA.isPressed),
      (2, gamepad.buttonX.isPressed), (3, gamepad.buttonY.isPressed),
      (4, gamepad.leftShoulder.isPressed || gamepad.leftTrigger.isPressed),
      (5, gamepad.rightShoulder.isPressed || gamepad.rightTrigger.isPressed),
      (8, gamepad.buttonMenu.isPressed || gamepad.buttonHome?.isPressed == true),
      (9, gamepad.buttonOptions?.isPressed == true),
      (12, gamepad.dpad.up.isPressed), (13, gamepad.dpad.left.isPressed),
      (14, gamepad.dpad.down.isPressed), (15, gamepad.dpad.right.isPressed),
    ]
    buttons = Set(pressed.filter(\.1).map(\.0))
    sticks = SIMD4(
      gamepad.leftThumbstick.xAxis.value, gamepad.leftThumbstick.yAxis.value,
      gamepad.rightThumbstick.xAxis.value, gamepad.rightThumbstick.yAxis.value)
  }
  var hidAxes: [UInt32] {
    (0..<4).map { index in
      var value = sticks[index]
      guard value.isFinite else { return 128 }
      value = min(1, max(-1, value))
      if abs(value) <= 0.12 {
        value = 0
      } else {
        value = (value < 0 ? -1 : 1) * (abs(value) - 0.12) / 0.88
      }
      if index == 1 || index == 3 { value = -value }
      return UInt32((128 + value * (value < 0 ? 128 : 127)).rounded())
    }
  }
}
