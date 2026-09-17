import Foundation
import CoreText

final class BREWDisplayContext {
  var references: UInt32 = 1
  var destination: UInt32
  var clip: SIMD4<Int>?
  var settings: [UInt32: UInt32]
  init(destination: UInt32, clip: SIMD4<Int>?, settings: [UInt32: UInt32]) {
    self.destination = destination; self.clip = clip; self.settings = settings
  }
}
final class BREWRootForm {
  var references: UInt32 = 1
  var isRoot = true
  var parentForm: UInt32 = 0
  var widget: UInt32 = 0
  var parts: [UInt32: UInt32] = [:]
  var active = false
  var visible = true
  var handler: [UInt32] = [0, 0, 0]
  var stack: [UInt32] = []
}
// IWidget ABI from the original AEEIWidget.h. Root forms own a widget even
// before the application installs its content and event handler.
final class BREWFormWidget {
  struct Child { var handle: UInt32; var x: Int; var y: Int; var visible: Bool }
  var references: UInt32 = 1
  var extent: [UInt32] = [640, 480]
  var parent: UInt32 = 0
  var handler: [UInt32] = [0, 0, 0]
  var focused = false
  var selected = false
  var backgrounds: [UInt32: UInt32] = [:]
  var imageModel: UInt32 = 0
  var isStaticText = false
  var textProperties: [UInt32: UInt32] = [:]
  var modelListener: UInt32 = 0
  var imageFrame: UInt32 = 0
  var imageAnimating = false
  var flags: UInt32 = 0
  var container: UInt32 = 0
  var rootForm: UInt32 = 0
  var children: [Child] = [] // bottom to top
  var focusChild: UInt32 = 0 // weak: the container already owns its children
  var keyRecipients: [UInt32: UInt32] = [:]
  var viewport: BREWViewport?
  var scrollbar: BREWScrollbar?
  var border: BREWBorder?
  var list: BREWListWidget?
  var isDrawDecorator = false
  var drawHandler: [UInt32] = [0, 0, 0]
  var isDecorator: Bool { viewport != nil || scrollbar != nil || border != nil || list != nil || isDrawDecorator }
  var contentInsets: [Int] {
    if let border { return border.padding.map { $0 + border.widths[focused ? 0 : 1] } }
    return viewport?.padding ?? [0, 0, 0, 0]
  }
}
// CBorderWidget's normal rectangular border, from the original BREW SDK.
// Rounded/beveled borders and shadows remain unsupported.
final class BREWBorder {
  var widths = [0, 0]
  var padding = [0, 0, 0, 0]
  var selected = false
  var colors: [UInt32: UInt32] = [:]
}
final class BREWScrollbar {
  var model: UInt32 = 0, listener: UInt32 = 0
  var style: UInt32 = 0
  var handleWidth = 3, gap = 2
  var range = [0, 0], visible = [0, 0], position = [0, 0]
  var colors: [UInt32: UInt32] = [0x184: 0xff, 0x185: 0xff,
    0x187: 0xffffffff, 0x188: 0xffffffff, 0x190: 0x808080ff]
  var axes: [Int] { style == 0 ? [1] : style == 1 ? [0] : [0, 1] }
  var thickness: Int { handleWidth + 4 }
}
final class BREWViewport {
  var x = 0, y = 0, increment = 1
  var padding = [0, 0, 0, 0] // left, right, top, bottom
  var layout: UInt32 = 3
  var viewModel: UInt32 = 0
}
final class BREWCanvas {
  var references: UInt32 = 1
  var bitmap: UInt32 = 0
  var clip: SIMD4<Int> = .zero
  var display: UInt32 = 0
}

extension BREWRuntime {
  func createScrollbarWidget() throws -> UInt32 {
    let handle = try createViewportWidget()
    guard let widget = formWidgets[handle], let viewport = widget.viewport else { return 0 }
    _ = try formInterfaceCall(viewport.viewModel, 4)
    widget.viewport = nil
    let scrollbar = BREWScrollbar(); widget.scrollbar = scrollbar
    scrollbar.listener = try allocate(24)
    try memory.write32(scrollbar.listener + 8, 0xf02cff08)
    try memory.write32(scrollbar.listener + 12, handle)
    return handle
  }
  func detachScrollbarModel(_ scrollbar: BREWScrollbar) throws {
    let cancel = try memory.read32(scrollbar.listener + 16)
    if cancel != 0 { _ = try invokeFormCallback(cancel, [scrollbar.listener]) }
    let old = scrollbar.model; scrollbar.model = 0
    if old != 0 { _ = try formInterfaceCall(old, 4) }
  }
  func setScrollbarModel(_ scrollbar: BREWScrollbar, model: UInt32) throws -> UInt32 {
    let scratch = try allocate(4); defer { try? free(scratch) }
    if model != 0 {
      let result = try formInterfaceCall(model, 8, [0x0101593a, scratch])
      guard result == 0 else { return result }
    }
    let replacement = model == 0 ? 0 : try memory.read32(scratch)
    try detachScrollbarModel(scrollbar); scrollbar.model = replacement
    if replacement != 0 { _ = try formInterfaceCall(replacement, 12, [scrollbar.listener]) }
    return 0
  }
  func bindScrollbarChild(_ handle: UInt32, _ widget: BREWFormWidget) throws {
    guard let scrollbar = widget.scrollbar else { return }
    let scratch = try allocate(4); defer { try? free(scratch) }
    var model: UInt32 = 0
    if let child = widget.children.first,
      try formInterfaceCall(child.handle, 12, [0x800, 0x161, scratch]) != 0 {
      model = try memory.read32(scratch)
    }
    defer { if model != 0 { _ = try? formInterfaceCall(model, 4) } }
    _ = try setScrollbarModel(scrollbar, model: model)
    scrollbar.range = [0, 0]; scrollbar.visible = [0, 0]; scrollbar.position = [0, 0]
    if let child = widget.children.first {
      _ = try formInterfaceCall(child.handle, 12, [0x801, 0x183, 0])
    }
  }
  func scrollbarContentSize(_ widget: BREWFormWidget) -> [Int] {
    guard let scrollbar = widget.scrollbar else { return widget.extent.map(Int.init) }
    var size = widget.extent.map(Int.init)
    for axis in scrollbar.axes { size[1 - axis] = max(0, size[1 - axis] - scrollbar.gap - scrollbar.thickness) }
    return size
  }
  func layoutScrollbar(_ handle: UInt32, _ widget: BREWFormWidget) throws {
    if let child = widget.children.first {
      let scratch = try allocate(8); defer { try? free(scratch) }
      let size = scrollbarContentSize(widget)
      try memory.write32(scratch, UInt32(size[0])); try memory.write32(scratch + 4, UInt32(size[1]))
      _ = try formInterfaceCall(child.handle, 28, [scratch])
    }
    if widget.parent != 0 { _ = try formInterfaceCall(widget.parent, 12, [handle, 0, 0]) }
  }
  func scrollbarNotification(_ handle: UInt32, _ widget: BREWFormWidget, event: UInt32) throws {
    guard let scrollbar = widget.scrollbar, try memory.read32(event) == 0x1064 else { return }
    let axis = try memory.read8(event + 12) != 0 ? 1 : 0
    scrollbar.range[axis] = Int(try memory.read16(event + 14))
    scrollbar.visible[axis] = Int(try memory.read16(event + 16))
    scrollbar.position[axis] = Int(try memory.read16(event + 18))
    if widget.parent != 0 { _ = try formInterfaceCall(widget.parent, 12, [handle, 0, 0]) }
  }
  func scrollbarGeometry(_ widget: BREWFormWidget, axis: Int) -> (bar: SIMD4<Int>, track: SIMD4<Int>, thumb: SIMD4<Int>) {
    let scrollbar = widget.scrollbar!, size = scrollbarContentSize(widget)
    let thickness = scrollbar.thickness, length = size[axis]
    let arrow = widget.flags & 2 != 0 ? min(thickness, length / 2) : 0
    let available = max(0, length - arrow * 2)
    let cross = size[1 - axis] + scrollbar.gap
    func rect(_ along: Int, _ crossOffset: Int, _ alongSize: Int, _ crossSize: Int) -> SIMD4<Int> {
      axis == 1 ? SIMD4(cross + crossOffset, along, crossSize, alongSize)
        : SIMD4(along, cross + crossOffset, alongSize, crossSize)
    }
    let trackLength = max(0, available - 2)
    let range = max(1, scrollbar.range[axis]), visible = min(range, scrollbar.visible[axis])
    let thumbLength = min(trackLength, max(4, trackLength * visible / range))
    let offset = range > visible ? (trackLength - thumbLength) * min(max(0, scrollbar.position[axis]), range - visible) / (range - visible) : 0
    return (rect(0, 0, length, thickness), rect(arrow, 0, available, thickness),
      rect(arrow + 1 + offset, 1, thumbLength, max(0, thickness - 2)))
  }
  func scrollbarEvent(_ handle: UInt32, _ widget: BREWFormWidget, event: UInt32, key: UInt32, value: UInt32) throws -> Bool? {
    guard let scrollbar = widget.scrollbar else { return nil }
    if event == 0x700 {
      widget.focused = key != 0
      if let child = widget.children.first { _ = try formInterfaceCall(child.handle, 12, [event, key, value]) }
      return true
    }
    if event == 0x800 && value != 0 {
      let result: UInt32
      switch key {
      case 0x100: result = 0
      case 0x153: result = widget.flags
      case 0x180: result = UInt32(scrollbar.handleWidth)
      case 0x181: result = UInt32(scrollbar.gap)
      case 0x182: result = scrollbar.style
      case 0x161:
        result = scrollbar.model
        if result != 0 { _ = try formInterfaceCall(result, 0) }
      case 0x184, 0x185, 0x187, 0x188, 0x190: result = scrollbar.colors[key] ?? 0
      case 0x191...0x199:
        let group = Int(key - 0x191) / 3, kind = Int(key - 0x191) % 3
        guard kind != 0 || scrollbar.style != 2 else { return false }
        let axis = kind == 1 ? 1 : kind == 2 ? 0 : scrollbar.style == 0 ? 1 : 0
        let geometry = scrollbarGeometry(widget, axis: axis)
        var rect = group == 0 ? geometry.bar : group == 1 ? geometry.thumb : geometry.track
        if group == 2 { rect.x += 1; rect.y += 1; rect.z = max(0, rect.z - 2); rect.w = max(0, rect.w - 2) }
        try writeFormRect(value, rect); return true
      default: return nil
      }
      try memory.write32(value, result); return true
    }
    if event == 0x801 {
      switch key {
      case 0x100: guard value == 0 else { return false }
      case 0x153:
        guard value & ~3 == 0 else { return false } // Focus-index tracking needs its own model event.
        widget.flags = value
      case 0x180: guard value <= 65531 else { return false }; scrollbar.handleWidth = Int(value)
      case 0x181: guard value <= 65535 else { return false }; scrollbar.gap = Int(value)
      case 0x182: guard value <= 2 else { return false }; scrollbar.style = value
      case 0x184, 0x185, 0x187, 0x188, 0x190: scrollbar.colors[key] = value
      case 0x186: scrollbar.colors[0x184] = value; scrollbar.colors[0x185] = value
      case 0x189: scrollbar.colors[0x187] = value; scrollbar.colors[0x188] = value
      default: return nil
      }
      try layoutScrollbar(handle, widget); return true
    }
    return nil
  }
  func drawScrollbar(_ widget: BREWFormWidget, canvas: UInt32, x: Int, y: Int) throws {
    guard let scrollbar = widget.scrollbar else { return }
    let border = scrollbar.colors[widget.focused ? 0x184 : 0x185] ?? 0xff
    let handleColor = scrollbar.colors[widget.focused ? 0x187 : 0x188] ?? 0xffffffff
    func fill(_ rectangle: SIMD4<Int>, _ color: UInt32) throws {
      let left = max(0, rectangle.x), top = max(0, rectangle.y)
      let right = min(Int(widget.extent[0]), rectangle.x + rectangle.z)
      let bottom = min(Int(widget.extent[1]), rectangle.y + rectangle.w)
      guard right > left, bottom > top else { return }
      let region = BREWFormWidget(); region.extent = [UInt32(right - left), UInt32(bottom - top)]
      region.backgrounds[0x132] = color
      try drawFormWidget(region, canvas: canvas, x: x + left, y: y + top)
    }
    func inset(_ rectangle: SIMD4<Int>) -> SIMD4<Int> {
      SIMD4(rectangle.x + 1, rectangle.y + 1, max(0, rectangle.z - 2), max(0, rectangle.w - 2))
    }
    for axis in scrollbar.axes {
      guard widget.flags & 1 != 0 || scrollbar.range[axis] > scrollbar.visible[axis] else { continue }
      let geometry = scrollbarGeometry(widget, axis: axis)
      try fill(geometry.track, border)
      try fill(inset(geometry.track), scrollbar.colors[0x190] ?? 0x808080ff)
      try fill(geometry.thumb, border); try fill(inset(geometry.thumb), handleColor)
      if widget.flags & 2 != 0 {
        // Native HLE arrow glyphs; no firmware widgets.mif artwork is bundled.
        let length = axis == 1 ? geometry.bar.w : geometry.bar.z
        let extent = min(scrollbar.thickness, length / 2), radius = max(0, (extent - 4) / 2)
        for end in 0..<2 {
          for row in 0...radius {
            let along = end == 0 ? 2 + row : length - 3 - row
            let cross = scrollbar.thickness / 2 - row
            let rect = axis == 1 ? SIMD4(geometry.bar.x + cross, along, row * 2 + 1, 1)
              : SIMD4(along, geometry.bar.y + cross, 1, row * 2 + 1)
            if extent >= 4 { try fill(rect, border) }
          }
        }
      }
    }
  }
}

// Original CViewportWidget: IDecorator owns one IWidget; its IContainer is
// a separate interface with the same lifetime, not an IXYContainer.
extension BREWRuntime {
  func createViewportWidget() throws -> UInt32 {
    let handle = try createFormWidget(), container = try allocate(4)
    guard let widget = formWidgets[handle], container != 0 else { return 0 }
    let table = hleAddress(0x21e00)
    for offset in stride(from: UInt32(0), through: 28, by: 4) {
      try memory.write32(table + offset, 0xf0330000 + offset)
    }
    try memory.write32(container, table); formContainers[container] = handle
    widget.container = container; widget.extent = [0, 0]; widget.viewport = BREWViewport()
    let model = try createValueModel(), modelTable = hleAddress(0x21f00)
    for offset in stride(from: UInt32(0), through: 16, by: 4) {
      try memory.write32(modelTable + offset, 0xf02d0000 + offset)
    }
    try memory.write32(model, modelTable); valueModels[model]!.isViewModel = true
    widget.viewport!.viewModel = model
    return handle
  }
  func setViewportModel(_ widget: BREWFormWidget, model: UInt32) throws -> UInt32 {
    guard let viewport = widget.viewport else { return 3 }
    let scratch = try allocate(4); defer { try? free(scratch) }
    if model != 0 {
      let result = try formInterfaceCall(model, 8, [0x0101593a, scratch])
      guard result == 0 else { return result }
    }
    let replacement = model == 0 ? 0 : try memory.read32(scratch), old = viewport.viewModel
    viewport.viewModel = replacement
    if old != 0 { _ = try formInterfaceCall(old, 4) }
    return 0
  }
  func setViewportChild(_ handle: UInt32, _ widget: BREWFormWidget, child: UInt32) throws -> UInt32 {
    let old = widget.children.first?.handle ?? 0
    if child == old { return 0 }
    if child != 0 {
      guard child > 1 && child != UInt32.max else { return 14 }
      var ancestor = handle
      while ancestor != 0 {
        guard ancestor != child else { return 14 }
        ancestor = formContainers[formWidgets[ancestor]?.parent ?? 0] ?? 0
      }
      let scratch = try allocate(4); defer { try? free(scratch) }
      _ = try formInterfaceCall(child, 32, [scratch])
      let parent = try memory.read32(scratch)
      guard parent == 0 else { _ = try formInterfaceCall(parent, 4); return 14 }
      _ = try formInterfaceCall(child, 0)
      _ = try formInterfaceCall(child, 36, [widget.container])
    }
    widget.children = child == 0 ? [] : [.init(handle: child, x: 0, y: 0, visible: true)]
    if old != 0 { _ = try formInterfaceCall(old, 36, [0]); _ = try formInterfaceCall(old, 4) }
    if widget.scrollbar != nil { try bindScrollbarChild(handle, widget); try layoutScrollbar(handle, widget) }
    else if widget.border != nil { try layoutBorder(handle, widget) }
    else if widget.isDrawDecorator {
      if child != 0 {
        let scratch = try allocate(8); defer { try? free(scratch) }
        try memory.write32(scratch, widget.extent[0]); try memory.write32(scratch + 4, widget.extent[1])
        _ = try formInterfaceCall(child, 28, [scratch])
      }
      if widget.parent != 0 { _ = try formInterfaceCall(widget.parent, 12, [handle, 0, 0]) }
    }
    else if widget.list != nil { try updateListWidget(handle, widget) }
    else { try updateViewport(handle, widget, notify: true) }
    return 0
  }
  func updateViewport(_ handle: UInt32, _ widget: BREWFormWidget, notify: Bool) throws {
    guard let viewport = widget.viewport else { return }
    let scratch = try allocate(28); defer { try? free(scratch) }
    var content = [UInt32(0), 0]
    let visible = [max(0, Int(widget.extent[0]) - viewport.padding[0] - viewport.padding[1]),
      max(0, Int(widget.extent[1]) - viewport.padding[2] - viewport.padding[3])]
    if let child = widget.children.first {
      _ = try formInterfaceCall(child.handle, 24, [scratch])
      content = [try memory.read32(scratch), try memory.read32(scratch + 4)]
      if widget.flags & 1 != 0 {
        let fitted = zip(content, visible).map { max($0, UInt32($1)) }
        if fitted != content {
          content = fitted
          try memory.write32(scratch, content[0]); try memory.write32(scratch + 4, content[1])
          _ = try formInterfaceCall(child.handle, 28, [scratch])
        }
      }
    }
    let oldX = viewport.x, oldY = viewport.y
    viewport.x = viewport.layout & 2 == 0 ? 0 : max(0, min(viewport.x, Int(content[0]) - visible[0]))
    viewport.y = viewport.layout & 1 == 0 ? 0 : max(0, min(viewport.y, Int(content[1]) - visible[1]))
    if !widget.children.isEmpty {
      widget.children[0].x = viewport.padding[0] - viewport.x
      widget.children[0].y = viewport.padding[2] - viewport.y
    }
    if notify || oldX != viewport.x || oldY != viewport.y {
      if viewport.viewModel != 0 {
        for axis in 0..<2 where viewport.layout & (axis == 0 ? 2 : 1) != 0 {
          // ScrollEvent: ModelEvent(12), boolean, padding, uint16 range/visible/position.
          try memory.write32(scratch, 0x1064); try memory.write32(scratch + 4, viewport.viewModel)
          try memory.write32(scratch + 8, 0); try memory.write8(scratch + 12, UInt32(axis))
          try memory.write8(scratch + 13, 0)
          try memory.write16(scratch + 14, min(content[axis], 65535))
          try memory.write16(scratch + 16, UInt32(min(visible[axis], 65535)))
          try memory.write16(scratch + 18, UInt32(min(axis == 0 ? viewport.x : viewport.y, 65535)))
          _ = try formInterfaceCall(viewport.viewModel, 16, [scratch])
        }
      }
      if widget.parent != 0 { _ = try formInterfaceCall(widget.parent, 12, [handle, 0, 0]) }
    }
  }
  func viewportEvent(_ handle: UInt32, _ widget: BREWFormWidget, event: UInt32, key: UInt32, value: UInt32) throws -> Bool? {
    guard let viewport = widget.viewport else { return nil }
    if event == 0x700 {
      widget.focused = key != 0
      if let child = widget.children.first { _ = try formInterfaceCall(child.handle, 12, [event, key, value]) }
      return true
    }
    if event == 0x800, value != 0 {
      let result: UInt32
      switch key {
      case 0x100: result = 0 // The default border is hidden.
      case 0x121...0x124: result = UInt32(viewport.padding[Int(key - 0x121)])
      case 0x154: result = UInt32(viewport.x)
      case 0x155: result = UInt32(viewport.y)
      case 0x156: result = UInt32(viewport.increment)
      case 0x153: result = widget.flags
      case 0x207: result = viewport.layout
      case 0x161:
        result = viewport.viewModel
        if result != 0 { _ = try formInterfaceCall(result, 0) }
      default: return nil
      }
      try memory.write32(value, result); return true
    }
    if event == 0x801 {
      switch key {
      case 0x100:
        guard value == 0 else { return false } // Visible border rendering is not implemented yet.
      case 0x120...0x124:
        guard value <= 65535 else { return false }
        if key == 0x120 { viewport.padding = Array(repeating: Int(value), count: 4) }
        else { viewport.padding[Int(key - 0x121)] = Int(value) }
      case 0x154: viewport.x = Int(Int32(bitPattern: value))
      case 0x155: viewport.y = Int(Int32(bitPattern: value))
      case 0x156:
        guard Int32(bitPattern: value) > 0 else { return false }
        viewport.increment = Int(value)
      case 0x153: widget.flags = value
      case 0x207:
        guard value <= 3 else { return false }; viewport.layout = value
      case 0x183:
        // The legacy request emits ScrollEvent; ScrollXYEvent needs its own ABI.
        guard value == 0 else { return false }
      default: return nil
      }
      try updateViewport(handle, widget, notify: true); return true
    }
    if event == 0x100 && widget.flags & 2 == 0 && (0xe031...0xe034).contains(key) {
      let oldX = viewport.x, oldY = viewport.y
      if key == 0xe031 { viewport.y -= viewport.increment }
      if key == 0xe032 { viewport.y += viewport.increment }
      if key == 0xe033 { viewport.x -= viewport.increment }
      if key == 0xe034 { viewport.x += viewport.increment }
      try updateViewport(handle, widget, notify: true)
      return oldX != viewport.x || oldY != viewport.y
    }
    return nil
  }
  func dispatchViewportContainer(_ offset: UInt32) throws {
    let container = cpu.r[0]
    guard let handle = formContainers[container], let widget = formWidgets[handle], widget.isDecorator
    else { throw EmulationError.invalid("Released viewport container") }
    switch offset {
    case 0: widget.references += 1; cpu.r[0] = widget.references
    case 4: cpu.r[0] = try releaseFormWidget(handle)
    case 8:
      let type = cpu.r[1], output = cpu.r[2]
      guard output != 0 else { cpu.r[0] = 14; return }
      let result: UInt32 = [0x01000001, 0x01015932].contains(type) ? container
        : [0x01015952, 0x01015956, 0x01015934].contains(type) ? handle : 0
      if result != 0 { widget.references += 1 }
      try memory.write32(output, result); cpu.r[0] = result != 0 ? 0 : 3
    case 12:
      if widget.list?.binding == true { cpu.r[0] = 0; return }
      try updateViewport(handle, widget, notify: false)
      if widget.parent != 0 { _ = try formInterfaceCall(widget.parent, 12, [handle, 0, cpu.r[3]]) }
      cpu.r[0] = 0
    case 16: cpu.r[0] = 20 // Locate needs full ancestor-relative rectangle propagation.
    case 20:
      guard widget.children.isEmpty else { cpu.r[0] = 14; return }
      cpu.r[0] = try setViewportChild(handle, widget, child: cpu.r[1])
    case 24:
      guard let child = widget.children.first, cpu.r[1] == 0 || cpu.r[1] == child.handle else { cpu.r[0] = 14; return }
      cpu.r[0] = try setViewportChild(handle, widget, child: 0)
    case 28:
      let child = widget.children.first?.handle ?? 0
      cpu.r[0] = cpu.r[1] == 0 || cpu.r[1] == child && cpu.r[3] != 0 ? child : 0
    default: throw EmulationError.hle("Viewport IContainer+" + offset.hex, cpu.r[14])
    }
  }
}

// CStaticWidget uses IValueModel text, not the older IStatic control ABI.
extension BREWRuntime {
  func createStaticWidget() throws -> UInt32 {
    let handle = try createFormWidget()
    guard let widget = formWidgets[handle] else { return 0 }
    widget.isStaticText = true; widget.extent = [0, 0]
    widget.modelListener = try allocate(24)
    try memory.write32(widget.modelListener + 8, 0xf02cff00)
    try memory.write32(widget.modelListener + 12, handle)
    let model = try createValueModel()
    _ = try setImageWidgetModel(widget, model: model)
    _ = try releaseValueModel(model)
    return handle
  }
  func staticWidgetProperty(_ widget: BREWFormWidget, event: UInt32, key: UInt32, value: UInt32) throws -> Bool {
    guard event == 0x800 || event == 0x801 else { return false }
    let colors = (0x140...0x145).contains(key)
    let scalar = [UInt32(0x171), 0x173, 0x303].contains(key)
    guard colors || scalar else { return false }
    if event == 0x800 {
      guard value != 0 else { return false }
      let property: UInt32 = key == 0x140 ? 0x142 : key == 0x145 ? 0x144 : key
      try memory.write32(value, widget.textProperties[property] ?? (colors ? 0x000000ff : 0))
    } else {
      if scalar && (Int32(bitPattern: value) < 0 || value > 65536) { return false }
      let keys: [UInt32] = key == 0x140 ? [0x141, 0x142, 0x143, 0x144] : key == 0x145 ? [0x143, 0x144] : [key]
      for property in keys { widget.textProperties[property] = value }
    }
    return true
  }
  func staticWidgetText(_ widget: BREWFormWidget) throws -> String {
    guard widget.imageModel != 0 else { return "" }
    let out = try allocate(4); defer { try? free(out) }
    let pointer = try formInterfaceCall(widget.imageModel, 24, [out])
    guard pointer != 0 else { return "" }
    let length = Int32(bitPattern: try memory.read32(out))
    guard length >= -1, length <= 65536 else { throw EmulationError.invalid("StaticWidget text length") }
    var units: [UInt16] = []
    // The text specialization stores the AECHAR count; -1 denotes a terminated string.
    for index in 0..<(length == -1 ? 65536 : Int(length)) {
      let unit = UInt16(try memory.read16(pointer + UInt32(index * 2)))
      if unit == 0 { return String(decoding: units, as: UTF16.self) }
      units.append(unit)
    }
    guard length != -1 else { throw EmulationError.invalid("Unterminated StaticWidget text") }
    return String(decoding: units, as: UTF16.self)
  }
  func staticWidgetLines(_ widget: BREWFormWidget, width: Int) throws -> (lines: [CTLine], width: Int, lineHeight: Int) {
    let font = BREWHostFonts.faces[0x8000]!
    let color = widget.textProperties[(widget.focused ? 0x141 : 0x142) + (widget.selected ? 2 : 0)] ?? 0x000000ff
    let foreground = CGColor(red: CGFloat(color >> 8 & 255) / 255,
      green: CGFloat(color >> 16 & 255) / 255, blue: CGFloat(color >> 24) / 255,
      alpha: CGFloat(color & 255) / 255)
    let attributed = NSAttributedString(string: try staticWidgetText(widget), attributes: [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground])
    let typesetter = CTTypesetterCreateWithAttributedString(attributed)
    let wrap = widget.flags & 0x500000 != 0 && width > 0
    var lines: [CTLine] = [], index = 0, measured = 0
    while index < attributed.length {
      let count: Int
      if wrap {
        count = max(1, widget.flags & 0x400000 != 0
          ? CTTypesetterSuggestClusterBreak(typesetter, index, Double(width))
          : CTTypesetterSuggestLineBreak(typesetter, index, Double(width)))
      } else { count = attributed.length - index }
      let line = CTTypesetterCreateLine(typesetter, CFRange(location: index, length: count))
      measured = max(measured, Int(ceil(CTLineGetTypographicBounds(line, nil, nil, nil))))
      lines.append(line); index += count
    }
    let lineHeight = BREWHostFonts.ascent(font) + BREWHostFonts.descent(font) + Int(widget.textProperties[0x303] ?? 0)
    return (lines, measured, lineHeight)
  }
  func drawStaticWidget(_ widget: BREWFormWidget, canvas: UInt32, x: Int, y: Int) throws {
    let scratch = try allocate(12); defer { try? free(scratch) }
    guard try formInterfaceCall(canvas, 12, [scratch]) == 0 else { return }
    let bitmap = try memory.read32(scratch)
    guard bitmap != 0 else { return }
    defer { _ = try? formInterfaceCall(bitmap, 4) }
    guard try formInterfaceCall(canvas, 20, [scratch + 4]) == 0 else { return }
    let clip = try (0..<4).map { Int(Int16(truncatingIfNeeded: try memory.read16(scratch + 4 + UInt32($0 * 2)))) }
    let surface = try bitmapLayout(bitmap)
    let left = max(0, x, clip[0]), top = max(0, y, clip[1])
    let right = min(surface.width, x + Int(widget.extent[0]), clip[0] + clip[2])
    let bottom = min(surface.height, y + Int(widget.extent[1]), clip[1] + clip[3])
    guard left < right, top < bottom else { return }
    let width = right - left, height = bottom - top
    guard width * height <= 8 * 1024 * 1024 else { throw EmulationError.invalid("StaticWidget canvas size") }
    let text = try staticWidgetLines(widget, width: Int(widget.extent[0]))
    guard !text.lines.isEmpty else { return }
    var pixels = [UInt32](repeating: 0, count: width * height)
    for i in pixels.indices {
      let rgb = try bitmapRGB(bitmapReadPixel(surface, left + i % width, top + i / width), surface)
      pixels[i] = 0xff000000 | (rgb & 0xff00) << 8 | (rgb >> 8) & 0xff00 | rgb >> 24
    }
    try pixels.withUnsafeMutableBytes { bytes in
      guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
      else { throw EmulationError.unsupported("StaticWidget canvas") }
      let extentWidth = Int(widget.extent[0]), extentHeight = Int(widget.extent[1])
      let blockHeight = text.lines.count * text.lineHeight
      let vertical = widget.flags & 0x400 != 0 ? extentHeight - blockHeight : widget.flags & 0x200 != 0 ? (extentHeight - blockHeight) / 2 : 0
      let font = BREWHostFonts.faces[0x8000]!
      let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]))
      let color = widget.textProperties[widget.focused ? 0x141 : 0x142] ?? 0xff
      context.setFillColor(red: CGFloat(color >> 8 & 255) / 255, green: CGFloat(color >> 16 & 255) / 255,
        blue: CGFloat(color >> 24) / 255, alpha: CGFloat(color & 255) / 255)
      for (index, original) in text.lines.enumerated() {
        let rowY = y + vertical + index * text.lineHeight
        if rowY >= bottom { break }
        var line = original
        if text.lines.count == 1 && widget.flags & 0x700000 == 0 {
          line = CTLineCreateTruncatedLine(line, Double(extentWidth), .end, token) ?? line
        }
        let lineWidth = Int(ceil(CTLineGetTypographicBounds(line, nil, nil, nil)))
        let horizontal = widget.flags & 0x40 != 0 ? extentWidth - lineWidth : widget.flags & 0x20 != 0 ? (extentWidth - lineWidth) / 2 : 0
        context.textPosition = CGPoint(x: x + horizontal - left, y: bottom - rowY - BREWHostFonts.ascent(font))
        CTLineDraw(line, context)
      }
    }
    for i in pixels.indices {
      let pixel = pixels[i], rgb = (pixel & 255) << 24 | (pixel & 0xff00) << 8 | (pixel >> 8) & 0xff00
      try bitmapWritePixel(surface, left + i % width, top + i / width, bitmapNative(rgb, surface))
    }
  }
}
final class BREWValueModel {
  var isViewModel = false
  var references: UInt32 = 1
  var value: UInt32 = 0, length: UInt32 = 0, freeValue: UInt32 = 0
  var listeners: [UInt32] = []
  var adaptGet: [UInt32] = [0, 0], adaptSet: [UInt32] = [0, 0]
  var vectorItems: [UInt32]? = nil
  var freeItem: UInt32 = 0
  var interfaceType: UInt32? = nil
}
final class BREWStaticControl {
  var references: UInt32 = 1
  var active = false
  var properties: UInt32 = 0
  var rectangle = Data([0, 0, 0, 0, 0x80, 2, 0xe0, 1])
  var title = Data([0, 0]), text = Data([0, 0])
  var titleFont: UInt32 = 0x8001, textFont: UInt32 = 0x8000
}
final class BREWMenuControl {
  struct Item { var id: UInt32; var text: Data; var data: UInt32 }
  var references: UInt32 = 1, properties: UInt32 = 0, selected: UInt32 = 0
  var active = false, commands = false
  var rectangle = Data([0, 0, 0xc8, 1, 0x80, 2, 24, 0])
  var colors = Data(repeating: 0, count: 40)
  var items: [Item] = []
  var title = Data([0, 0])
}

extension BREWRuntime {
  func sendShellEvent() throws {
    let flags = cpu.r[1], cls = cpu.r[2], code = UInt32(UInt16(truncatingIfNeeded: cpu.r[3]))
    let key = UInt32(UInt16(truncatingIfNeeded: try argument(4))), value = try argument(5)
    guard flags & ~3 == 0, cls == 0 || cls == package.classID,
      cls != 0 || code < 0x7000 else { cpu.r[0] = 0; return }
    // CreateInstance has already published this applet pointer before its own
    // initialization calls SendEvent. It is also the GETAPPINSTANCE value.
    let target = applet != 0 ? applet : try memory.read32(hleAddress(0x4004))
    guard target != 0, !appletClosed else { cpu.r[0] = 0; return }
    let event = [target, code, key, value]
    let asynchronous = flags & 2 != 0 || [0x100, 0x101, 0x102, 0x104, 0x105, 0x504, 0x505, 0x506, 0x508].contains(code)
    if asynchronous {
      guard postedShellEvents.count < 4096,
        flags & 1 == 0 || !postedShellEvents.values.contains(where: { $0[0] == target && $0[1] == code })
      else { cpu.r[0] = 0; return }
      cpu.r[0] = enqueueShellEvent(target: target, code: code, key: key, value: value) ? 1 : 0
    } else {
      let table = try memory.read32(target)
      cpu.r[0] = try invokeFormCallback(memory.read32(table + 8), event) != 0 ? 1 : 0
    }
  }
  @discardableResult
  func enqueueShellEvent(target: UInt32, code: UInt32, key: UInt32, value: UInt32 = 0) -> Bool {
    guard target != 0, !appletClosed, postedShellEvents.count < 4096 else { return false }
    while postedShellEvents[nextShellEvent] != nil { nextShellEvent &+= 1 }
    let token = nextShellEvent; nextShellEvent &+= 1
    postedShellEvents[token] = [target, code, key, value]
    scheduleCallback(delay: 0, callback: 0xf001ff00, context: token)
    return true
  }
  func displaySettings() -> [UInt32: UInt32] {
    graphicsState.filter { (0x2800..<0x2900).contains($0.key) || (0x4400..<0x14400).contains($0.key) }
  }
  func captureDisplayContext() -> BREWDisplayContext {
    BREWDisplayContext(destination: displayDestination, clip: displayClip, settings: displaySettings())
  }
  func applyDisplayContext(_ context: BREWDisplayContext) {
    displayDestination = context.destination; displayClip = context.clip
    for key in Array(displaySettings().keys) { graphicsState.removeValue(forKey: key) }
    for (key, value) in context.settings { graphicsState[key] = value }
  }
  func releaseDisplay(_ handle: UInt32) throws -> UInt32 {
    guard let context = clonedDisplays[handle] else { return 1 }
    context.references -= 1
    if context.references == 0 {
      try releaseBitmap(context.destination); clonedDisplays.removeValue(forKey: handle); try free(handle)
    }
    return context.references
  }
  // Give nested guest callbacks their own outgoing argument area. Restoring a
  // copy of the caller's stack would erase outputs pointing into that stack.
  func invokeFormCallback(_ callback: UInt32, _ arguments: [UInt32]) throws -> UInt32 {
    let registers = (0..<16).map { cpu.r[$0] }, flags = cpu.cpsr
    let outgoing = UInt32((max(32, max(0, arguments.count - 4) * 4) + 7) & ~7)
    guard cpu.r[13] >= outgoing else { throw EmulationError.invalid("Guest callback stack") }
    let stack = (cpu.r[13] - outgoing) & ~UInt32(7)
    _ = try memory.region(stack, Int(outgoing))
    defer {
      for i in 0..<16 { cpu.r[i] = registers[i] }; cpu.cpsr = flags
    }
    cpu.r[13] = stack
    return try invoke(callback, arguments)
  }
  func createRootForm(isRoot: Bool = true) throws -> UInt32 {
    let handle = try allocate(4); guard handle != 0 else { return 0 }
    let table = hleAddress(0x21300)
    for offset in stride(from: UInt32(0), through: 0x24, by: 4) { try memory.write32(table + offset, 0xf0290000 + offset) }
    let form = BREWRootForm()
    form.handler = [0xf029ff04, handle, 0]
    form.isRoot = isRoot
    if isRoot {
      let container = try createXYContainer()
      form.widget = formContainers[container] ?? 0
      formWidgets[form.widget]?.rootForm = handle
      formWidgets[form.widget]?.extent = [640, 480]
    } else { form.widget = try createFormWidget() }
    form.parts[0x5002] = try createFormWidget()
    try memory.write32(handle, table); rootForms[handle] = form; return handle
  }
  func createFormWidget() throws -> UInt32 {
    let handle = try allocate(4); guard handle != 0 else { return 0 }
    let table = hleAddress(0x21700)
    for offset in stride(from: UInt32(0), through: 0x40, by: 4) {
      try memory.write32(table + offset, 0xf02c0000 + offset)
    }
    try memory.write32(handle, table); formWidgets[handle] = BREWFormWidget()
    formWidgets[handle]!.handler = [0xf02cff04, handle, 0]
    return handle
  }
  func createDrawDecorator() throws -> UInt32 {
    let handle = try createViewportWidget()
    guard let widget = formWidgets[handle] else { return 0 }
    if let model = widget.viewport?.viewModel { _ = try formInterfaceCall(model, 4) }
    widget.viewport = nil; widget.isDrawDecorator = true
    widget.drawHandler = [0xf02cff0c, handle, 0]
    return handle
  }
  func createBorderWidget() throws -> UInt32 {
    let handle = try createViewportWidget()
    guard let widget = formWidgets[handle] else { return 0 }
    if let model = widget.viewport?.viewModel { _ = try formInterfaceCall(model, 4) }
    widget.viewport = nil; widget.border = BREWBorder()
    return handle
  }
  func layoutBorder(_ handle: UInt32, _ widget: BREWFormWidget) throws {
    let insets = widget.contentInsets
    if let child = widget.children.first {
      widget.children[0].x = insets[0]; widget.children[0].y = insets[2]
      let scratch = try allocate(8); defer { try? free(scratch) }
      try memory.write32(scratch, UInt32(max(0, Int(widget.extent[0]) - insets[0] - insets[1])))
      try memory.write32(scratch + 4, UInt32(max(0, Int(widget.extent[1]) - insets[2] - insets[3])))
      _ = try formInterfaceCall(child.handle, 28, [scratch])
    }
    if widget.parent != 0 { _ = try formInterfaceCall(widget.parent, 12, [handle, 0, 0]) }
  }
  func borderEvent(_ handle: UInt32, _ widget: BREWFormWidget, event: UInt32, key: UInt32, value: UInt32) throws -> Bool? {
    guard let border = widget.border else { return nil }
    if event == 0x700 {
      widget.focused = key != 0
      if let child = widget.children.first { _ = try formInterfaceCall(child.handle, 12, [event, key, value]) }
      try layoutBorder(handle, widget); return true
    }
    if event == 0x800 {
      guard value != 0 else { return false }
      let result: UInt32
      switch key {
      case 0x100, 0x101: result = UInt32(border.widths[0])
      case 0x102: result = UInt32(border.widths[1])
      case 0x119: result = 0
      case 0x110...0x115:
        result = border.colors[key == 0x110 ? 0x111 : key == 0x115 ? 0x113 : key] ?? 0xff
      case 0x130...0x135:
        result = widget.backgrounds[key == 0x130 ? 0x131 : key == 0x135 ? 0x133 : key] ?? 0
      case 0x121...0x124: result = UInt32(border.padding[Int(key - 0x121)])
      case 0x151: try memory.write8(value, border.selected ? 1 : 0); return true
      case 0x320:
        let insets = widget.contentInsets
        let rect = [insets[0], insets[2], max(0, Int(widget.extent[0]) - insets[0] - insets[1]),
          max(0, Int(widget.extent[1]) - insets[2] - insets[3])]
        for i in 0..<4 { try memory.write16(value + UInt32(i * 2), UInt32(min(rect[i], 32767))) }
        return true
      default: return nil
      }
      try memory.write32(value, result); return true
    }
    if event == 0x801 {
      switch key {
      case 0x100...0x102:
        guard value <= 32767 else { return false }
        if key == 0x100 { border.widths = [Int(value), Int(value)] }
        else { border.widths[Int(key - 0x101)] = Int(value) }
      case 0x119: return value == 0
      case 0x110...0x115:
        let properties: [UInt32] = key == 0x110 ? [0x111, 0x112, 0x113, 0x114] : key == 0x115 ? [0x113, 0x114] : [key]
        for property in properties { border.colors[property] = value }
      case 0x130...0x135:
        let properties: [UInt32] = key == 0x130 ? [0x131, 0x132, 0x133, 0x134] : key == 0x135 ? [0x133, 0x134] : [key]
        for property in properties { widget.backgrounds[property] = value }
      case 0x120...0x124:
        guard value <= 32767 else { return false }
        if key == 0x120 { border.padding = Array(repeating: Int(value), count: 4) }
        else { border.padding[Int(key - 0x121)] = Int(value) }
      case 0x151: border.selected = value != 0
      default: return nil
      }
      try layoutBorder(handle, widget); return true
    }
    return nil
  }
  func drawBorder(_ widget: BREWFormWidget, canvas: UInt32, x: Int, y: Int) throws {
    guard let border = widget.border else { return }
    let width = Int(widget.extent[0]), height = Int(widget.extent[1])
    let thickness = border.widths[widget.focused ? 0 : 1]
    let top = min(height, thickness), bottom = min(height - top, thickness)
    let left = min(width, thickness), right = min(width - left, thickness)
    let key: UInt32 = (widget.focused ? 0x111 : 0x112) + (border.selected ? 2 : 0)
    for rectangle in [SIMD4(0, 0, width, top), SIMD4(0, height - bottom, width, bottom),
      SIMD4(0, top, left, height - top - bottom), SIMD4(width - right, top, right, height - top - bottom)] {
      guard rectangle.z > 0, rectangle.w > 0 else { continue }
      let region = BREWFormWidget(); region.extent = [UInt32(rectangle.z), UInt32(rectangle.w)]
      region.backgrounds[0x132] = border.colors[key] ?? 0xff
      try drawFormWidget(region, canvas: canvas, x: x + rectangle.x, y: y + rectangle.y)
    }
  }
  func releaseFormWidget(_ handle: UInt32) throws -> UInt32 {
    guard let widget = formWidgets[handle] else { return 0 }
    guard widget.references != 0 else { return 0 }
    widget.references -= 1
    if widget.references == 0 {
      if let list = widget.list {
        try detachListModel(list)
        if list.viewModel != 0 { _ = try formInterfaceCall(list.viewModel, 4) }
        try free(list.listener)
      }
      if let scrollbar = widget.scrollbar {
        try detachScrollbarModel(scrollbar); try free(scrollbar.listener)
      }
      for child in widget.children {
        _ = try formInterfaceCall(child.handle, 0x24, [0])
        _ = try formInterfaceCall(child.handle, 4)
      }
      if widget.container != 0 {
        formContainers.removeValue(forKey: widget.container); try free(widget.container)
      }
      if widget.modelListener != 0 {
        try detachFormWidgetModel(widget)
        try free(widget.modelListener)
      }
      if let viewport = widget.viewport, viewport.viewModel != 0 {
        _ = try formInterfaceCall(viewport.viewModel, 4)
      }
      if widget.handler[2] != 0 { _ = try invokeFormCallback(widget.handler[2], [widget.handler[1]]) }
      if widget.drawHandler[2] != 0 { _ = try invokeFormCallback(widget.drawHandler[2], [widget.drawHandler[1]]) }
      formWidgets.removeValue(forKey: handle); try free(handle)
    }
    return widget.references
  }
  func dispatchFormWidget(_ requestedOffset: UInt32) throws {
    let offset: UInt32 = requestedOffset == 0xff04 ? 0xc : requestedOffset == 0xff0c ? 0x28 : requestedOffset
    let handle = cpu.r[0]
    guard let widget = formWidgets[handle] else { throw EmulationError.invalid("Released IWidget") }
    if offset == 0xff00 {
      if widget.parent != 0 { _ = try formInterfaceCall(widget.parent, 12, [handle, 0, 0]) }
      cpu.r[0] = 0; return
    }
    if offset == 0xff10 {
      try updateListWidget(handle, widget); cpu.r[0] = 0; return
    }
    if offset == 0xff08 {
      try scrollbarNotification(handle, widget, event: cpu.r[1]); cpu.r[0] = 0; return
    }
    switch offset {
    case 0: widget.references += 1; cpu.r[0] = widget.references
    case 4: cpu.r[0] = try releaseFormWidget(handle)
    case 8:
      guard cpu.r[2] != 0 else { cpu.r[0] = 14; return }
      if widget.container != 0 && (cpu.r[1] == 0x01015932 || !widget.isDecorator && cpu.r[1] == 0x01015954) {
        try memory.write32(cpu.r[2], widget.container); widget.references += 1; cpu.r[0] = 0; return
      }
      let supported = [0x01000001, 0x01015956, 0x01015952].contains(cpu.r[1]) || widget.isDecorator && cpu.r[1] == 0x01015934
      try memory.write32(cpu.r[2], supported ? handle : 0)
      if supported { widget.references += 1 }; cpu.r[0] = supported ? 0 : 3
    case 0xc:
      let event = cpu.r[1], key = cpu.r[2], value = cpu.r[3]
      if requestedOffset != 0xff04 && widget.handler[0] != 0 {
        cpu.r[0] = try invokeFormCallback(widget.handler[0], [widget.handler[1], event, key, value])
        return
      }
      if widget.list != nil, let handled = try listWidgetEvent(handle, widget, event: event, key: key, value: value) {
        cpu.r[0] = handled ? 1 : 0; return
      }
      if widget.viewport != nil, let handled = try viewportEvent(handle, widget, event: event, key: key, value: value) {
        cpu.r[0] = handled ? 1 : 0; return
      }
      if widget.scrollbar != nil, let handled = try scrollbarEvent(handle, widget, event: event, key: key, value: value) {
        cpu.r[0] = handled ? 1 : 0; return
      }
      if widget.border != nil, let handled = try borderEvent(handle, widget, event: event, key: key, value: value) {
        cpu.r[0] = handled ? 1 : 0; return
      }
      if widget.isStaticText, try staticWidgetProperty(widget, event: event, key: key, value: value) {
        if event == 0x801, widget.parent != 0 {
          _ = try formInterfaceCall(widget.parent, 12, [handle, 0, 0])
        }
        cpu.r[0] = 1; return
      }
      if widget.container != 0 && !widget.isDecorator,
        let handled = try containerFocusEvent(widget, event: event, key: key, value: value) {
        cpu.r[0] = handled ? 1 : 0; return
      }
      switch event {
      case 0x801 where key == 0x151:
        widget.selected = value != 0; cpu.r[0] = 1
      case 0x800 where key == 0x151 && value != 0:
        try memory.write8(value, widget.selected ? 1 : 0); cpu.r[0] = 1
      case 0x801 where key == 0x153: widget.flags = value; cpu.r[0] = 1
      case 0x800 where key == 0x153 && value != 0:
        try memory.write32(value, widget.flags); cpu.r[0] = 1
      case 0x801 where key == 0x346 && !widget.isStaticText && widget.imageModel != 0:
        widget.imageFrame = value; cpu.r[0] = 1
      case 0x800 where key == 0x346 && !widget.isStaticText && widget.imageModel != 0 && value != 0:
        try memory.write32(value, widget.imageFrame); cpu.r[0] = 1
      case 0x800 where key == 0x414 && !widget.isStaticText && widget.imageModel != 0 && value != 0:
        try memory.write32(value, try widgetImageFrameCount(widget)); cpu.r[0] = 1
      case 0x800 where key == 0x216 && !widget.isStaticText && widget.imageModel != 0 && value != 0:
        try memory.write8(value, widget.imageAnimating ? 1 : 0); cpu.r[0] = 1
      case 0x801 where key == 0x216 && !widget.isStaticText && widget.imageModel != 0:
        if value != 0, try widgetImageFrameCount(widget) > 1 {
          throw EmulationError.unsupported("ImageWidget multi-frame animation")
        }
        widget.imageAnimating = value != 0; cpu.r[0] = 1
      case 0x801 where key == 0x215 && !widget.isStaticText && widget.imageModel != 0 && value != 0:
        let image = try widgetImage(widget)
        defer { if image != 0 { _ = try? formInterfaceCall(image, 4) } }
        guard image != 0 else { cpu.r[0] = 0; return }
        _ = try formInterfaceCall(image, 0x14, (0..<3).map { try memory.read32(value + UInt32($0 * 4)) })
        cpu.r[0] = 1
      case 0x800 where value != 0 && (0x131...0x134).contains(key):
        try memory.write32(value, widget.backgrounds[key] ?? 0); cpu.r[0] = 1
      case 0x801 where (0x130...0x135).contains(key):
        let keys: [UInt32] = key == 0x130 ? [0x131, 0x132, 0x133, 0x134] : key == 0x135 ? [0x133, 0x134] : [key]
        for property in keys { widget.backgrounds[property] = value }; cpu.r[0] = 1
      case 0x700: widget.focused = key != 0; cpu.r[0] = 1
      case 0x701, 0x702:
        if value != 0 { try memory.write8(value, event == 0x702 || widget.focused ? 1 : 0) }
        cpu.r[0] = value != 0 ? 1 : 0
      default:
        if widget.isDecorator, let child = widget.children.first {
          cpu.r[0] = try formInterfaceCall(child.handle, 12, [event, key, value])
        } else if widget.container != 0 {
          cpu.r[0] = try routeContainerEvent(widget, event: event, key: key, value: value)
        } else { cpu.r[0] = 0 }
      }
    case 0x10:
      let descriptor = cpu.r[1]
      let handler = descriptor == 0 ? [0xf02cff04, handle, 0] : try (0..<3).map { try memory.read32(descriptor + UInt32($0 * 4)) }
      if descriptor != 0 {
        for i in 0..<3 { try memory.write32(descriptor + UInt32(i * 4), widget.handler[i]) }
      }
      widget.handler = handler; cpu.r[0] = 0
    case 0x14 where widget.list != nil:
      let output = cpu.r[1], list = widget.list!
      let size = try listItemSize(widget)
      try memory.write32(output, UInt32(clamping: size[0]))
      try memory.write32(output + 4, UInt32(clamping: size[1] * (list.hintRows ?? min(try listCount(list), 8))))
      cpu.r[0] = 0
    case 0x14 where widget.scrollbar != nil:
      let output = cpu.r[1], scrollbar = widget.scrollbar!
      if let child = widget.children.first { _ = try formInterfaceCall(child.handle, 20, [output]) }
      else { try memory.write32(output, 0); try memory.write32(output + 4, 0) }
      for axis in scrollbar.axes {
        let dimension = output + UInt32((1 - axis) * 4)
        try memory.write32(dimension, UInt32(clamping: UInt64(try memory.read32(dimension)) + UInt64(scrollbar.gap + scrollbar.thickness)))
      }
      cpu.r[0] = 0
    case 0x14 where widget.viewport != nil || widget.border != nil:
      let output = cpu.r[1], padding = widget.contentInsets
      if let child = widget.children.first { _ = try formInterfaceCall(child.handle, 20, [output]) }
      else { try memory.write32(output, 0); try memory.write32(output + 4, 0) }
      try memory.write32(output, UInt32(clamping: UInt64(try memory.read32(output)) + UInt64(padding[0] + padding[1])))
      try memory.write32(output + 4, UInt32(clamping: UInt64(try memory.read32(output + 4)) + UInt64(padding[2] + padding[3])))
      cpu.r[0] = 0
    case 0x14 where widget.isStaticText:
      let output = cpu.r[1]
      let layout = try staticWidgetLines(widget, width: Int(widget.textProperties[0x173] ?? 0))
      let width = widget.textProperties[0x173] ?? UInt32(layout.width)
      let rows = widget.textProperties[0x171] ?? UInt32(layout.lines.count)
      try memory.write32(output, width)
      try memory.write32(output + 4, rows * UInt32(layout.lineHeight)); cpu.r[0] = 0
    case 0x14 where widget.modelListener != 0:
      let output = cpu.r[1], image = try widgetImage(widget)
      var preferred: [UInt32] = [0, 0]
      if image != 0 {
        defer { _ = try? formInterfaceCall(image, 4) }
        let scratch = try allocate(12); defer { try? free(scratch) }
        _ = try formInterfaceCall(image, 16, [scratch])
        preferred = [try memory.read16(scratch + 8), try memory.read16(scratch + 2)]
      }
      try memory.write32(output, preferred[0]); try memory.write32(output + 4, preferred[1]); cpu.r[0] = 0
    case 0x14 where widget.isDrawDecorator && !widget.children.isEmpty:
      cpu.r[0] = try formInterfaceCall(widget.children[0].handle, 20, [cpu.r[1]])
    case 0x14, 0x18:
      try memory.write32(cpu.r[1], widget.extent[0]); try memory.write32(cpu.r[1] + 4, widget.extent[1]); cpu.r[0] = 0
    case 0x1c:
      widget.extent = [try memory.read32(cpu.r[1]), try memory.read32(cpu.r[1] + 4)]; cpu.r[0] = 0
      if widget.list != nil { try updateListWidget(handle, widget) }
      if widget.viewport != nil { try updateViewport(handle, widget, notify: true) }
      if widget.scrollbar != nil { try layoutScrollbar(handle, widget) }
      if widget.border != nil { try layoutBorder(handle, widget) }
      if widget.isDrawDecorator, let child = widget.children.first {
        _ = try formInterfaceCall(child.handle, 28, [cpu.r[1]])
      }
    case 0x20:
      if widget.parent != 0 { _ = try formInterfaceCall(widget.parent, 0) }
      try memory.write32(cpu.r[1], widget.parent); cpu.r[0] = 0
    case 0x24: widget.parent = cpu.r[1]; cpu.r[0] = 0
    case 0x28:
      if widget.isDrawDecorator, requestedOffset != 0xff0c, widget.drawHandler[0] != 0 {
        _ = try invokeFormCallback(widget.drawHandler[0], [widget.drawHandler[1], cpu.r[1], cpu.r[2], cpu.r[3]])
        cpu.r[0] = 0; return
      }
      try drawFormWidget(widget, canvas: cpu.r[1], x: Int(Int32(bitPattern: cpu.r[2])), y: Int(Int32(bitPattern: cpu.r[3])))
      if widget.isStaticText {
        try drawStaticWidget(widget, canvas: cpu.r[1], x: Int(Int32(bitPattern: cpu.r[2])), y: Int(Int32(bitPattern: cpu.r[3])))
      } else if widget.imageModel != 0 {
        try drawImageWidget(widget, canvas: cpu.r[1], x: Int(Int32(bitPattern: cpu.r[2])), y: Int(Int32(bitPattern: cpu.r[3])))
      }
      if widget.list != nil {
        try drawListWidget(widget, canvas: cpu.r[1], x: Int(Int32(bitPattern: cpu.r[2])), y: Int(Int32(bitPattern: cpu.r[3])))
      } else if widget.container != 0 {
        try drawContainerWidget(widget, canvas: cpu.r[1], x: Int(Int32(bitPattern: cpu.r[2])), y: Int(Int32(bitPattern: cpu.r[3])))
      }
      if widget.scrollbar != nil {
        try drawScrollbar(widget, canvas: cpu.r[1], x: Int(Int32(bitPattern: cpu.r[2])), y: Int(Int32(bitPattern: cpu.r[3])))
      }
      if widget.border != nil {
        try drawBorder(widget, canvas: cpu.r[1], x: Int(Int32(bitPattern: cpu.r[2])), y: Int(Int32(bitPattern: cpu.r[3])))
      }
      cpu.r[0] = 0
    case 0x2c: cpu.r[0] = 0 // Empty root has no opaque region.
    case 0x30:
      guard cpu.r[2] != 0 else { cpu.r[0] = 14; return }
      if let list = widget.list, list.model != 0 {
        cpu.r[0] = try formInterfaceCall(list.model, 8, [cpu.r[1], cpu.r[2]])
      } else if let scrollbar = widget.scrollbar, scrollbar.model != 0 {
        cpu.r[0] = try formInterfaceCall(scrollbar.model, 8, [cpu.r[1], cpu.r[2]])
      } else if let viewport = widget.viewport, viewport.viewModel != 0 {
        cpu.r[0] = try formInterfaceCall(viewport.viewModel, 8, [cpu.r[1], cpu.r[2]])
      } else if widget.imageModel != 0 {
        cpu.r[0] = try formInterfaceCall(widget.imageModel, 8, [cpu.r[1], cpu.r[2]])
      } else { try memory.write32(cpu.r[2], 0); cpu.r[0] = 3 }
    case 0x34:
      if widget.list != nil { cpu.r[0] = try setListModel(handle, widget, model: cpu.r[1]); return }
      if widget.scrollbar != nil { cpu.r[0] = try setScrollbarModel(widget.scrollbar!, model: cpu.r[1]); return }
      if widget.viewport != nil { cpu.r[0] = try setViewportModel(widget, model: cpu.r[1]); return }
      guard widget.modelListener != 0 else { cpu.r[0] = 3; return }
      cpu.r[0] = try setImageWidgetModel(widget, model: cpu.r[1])
    case 0x38 where widget.isDecorator:
      cpu.r[0] = try setViewportChild(handle, widget, child: cpu.r[1])
    case 0x3c where widget.isDecorator:
      let child = widget.children.first?.handle ?? 0, output = cpu.r[1]
      if child != 0 { _ = try formInterfaceCall(child, 0) }
      try memory.write32(output, child); cpu.r[0] = 0
    case 0x40 where widget.isDrawDecorator:
      let descriptor = cpu.r[1]
      let next: [UInt32] = descriptor == 0 ? [0xf02cff0c, handle, 0]
        : try (0..<3).map { try memory.read32(descriptor + UInt32($0 * 4)) }
      if descriptor != 0 {
        for i in 0..<3 { try memory.write32(descriptor + UInt32(i * 4), widget.drawHandler[i]) }
      }
      widget.drawHandler = next; cpu.r[0] = 0
    default: throw EmulationError.hle("IWidget+" + offset.hex, cpu.r[14])
    }
  }
  func formInterfaceCall(_ object: UInt32, _ slot: UInt32, _ args: [UInt32] = []) throws -> UInt32 {
    let table = try memory.read32(object)
    return try invokeFormCallback(memory.read32(table + slot), [object] + args)
  }
  func drawFormWidget(_ widget: BREWFormWidget, canvas: UInt32, x: Int, y: Int) throws {
    let key: UInt32 = (widget.focused ? 0x131 : 0x132) + (widget.selected || widget.border?.selected == true ? 2 : 0)
    let color = widget.backgrounds[key] ?? 0
    let alpha = Int(color & 255)
    guard alpha != 0 else { return }
    let scratch = try allocate(16)
    defer { try? free(scratch) }
    guard try formInterfaceCall(canvas, 12, [scratch]) == 0 else { return }
    let bitmap = try memory.read32(scratch)
    guard bitmap != 0 else { return }
    defer { _ = try? formInterfaceCall(bitmap, 4) }
    guard try formInterfaceCall(canvas, 20, [scratch + 4]) == 0 else { return }
    let clip: [Int] = try (0..<4).map { Int(Int16(truncatingIfNeeded: try memory.read16(scratch + 4 + UInt32($0 * 2)))) }
    let layout = try bitmapLayout(bitmap)
    let left = max(0, x, clip[0]), top = max(0, y, clip[1])
    let right = min(layout.width, x + Int(widget.extent[0]), clip[0] + clip[2])
    let bottom = min(layout.height, y + Int(widget.extent[1]), clip[1] + clip[3])
    guard left < right, top < bottom else { return }
    let source: [Int] = [Int(color >> 24), Int(color >> 16 & 255), Int(color >> 8 & 255)]
    for row in top..<bottom { for col in left..<right {
      var rgb = color & 0xffffff00
      if alpha != 255 {
        let old = try bitmapRGB(bitmapReadPixel(layout, col, row), layout)
        let destination: [Int] = [Int(old >> 24), Int(old >> 16 & 255), Int(old >> 8 & 255)]
        rgb = 0
        for i in 0..<3 {
          let foreground: Int = source[i] * alpha
          let background: Int = destination[i] * (255 - alpha)
          let blended: Int = (foreground + background + 127) / 255
          rgb |= UInt32(blended) << UInt32(24 - i * 8)
        }
      }
      try bitmapWritePixel(layout, col, row, bitmapNative(rgb, layout))
    } }
  }
  // AEEIRootForm.h and AEEIForm.h: properties are IHandler events, not
  // extra vtable slots. Unimplemented widget properties return FALSE.
  func dispatchRootForm(_ requestedOffset: UInt32) throws {
    let offset: UInt32 = requestedOffset == 0xff04 ? 0xc : requestedOffset
    let handle = cpu.r[0]
    guard let object = rootForms[handle] else { throw EmulationError.invalid("Released IRootForm") }
    if requestedOffset == 0xff08 { try drawRootForm(handle); cpu.r[0] = 0; return }
    switch offset {
    case 0: object.references += 1; cpu.r[0] = object.references
    case 4:
      // A guest free handler can release its saved form pointer while the
      // outer Release is already destroying that form. Do not decrement zero
      // or invoke the same cleanup handler a second time.
      guard object.references != 0 else { cpu.r[0] = 0; return }
      object.references -= 1; cpu.r[0] = object.references
      if object.references == 0 {
        timers.removeAll { $0.callback == 0xf029ff08 && $0.context == handle }
        let forms = object.stack; object.stack = []
        for form in forms {
          if let child = rootForms[form] { child.parentForm = 0 }
          _ = try formInterfaceCall(form, 4)
        }
        if object.handler[2] != 0 { _ = try invokeFormCallback(object.handler[2], [object.handler[1]]) }
        if object.widget != 0 { _ = try formInterfaceCall(object.widget, 4) }
        for part in object.parts.values where part != 0 { _ = try formInterfaceCall(part, 4) }
        rootForms.removeValue(forKey: handle); try free(handle)
      }
    case 8:
      guard cpu.r[2] != 0 else { cpu.r[0] = 14; return }
      let supported = [0x01000001, 0x01013604, 0x01013603, 0x01015956].contains(cpu.r[1])
      try memory.write32(cpu.r[2], supported ? handle : 0)
      if supported { object.references += 1 }; cpu.r[0] = supported ? 0 : 3
    case 0xc:
      let event = cpu.r[1], property = cpu.r[2], value = cpu.r[3]
      if requestedOffset != 0xff04 && object.handler[0] != 0 {
        cpu.r[0] = try invokeFormCallback(object.handler[0], [object.handler[1], event, property, value]); return
      }
      if event == 0x801 && property == 0x5000 {
        if value != 0 { _ = try formInterfaceCall(value, 0) }
        let old = object.widget; object.widget = value
        if old != 0 { _ = try formInterfaceCall(old, 4) }
        cpu.r[0] = 1
      } else if event == 0x801 && (0x5001...0x5003).contains(property) {
        if value != 0 { _ = try formInterfaceCall(value, 0) }
        if let old = object.parts[property], old != 0 { _ = try formInterfaceCall(old, 4) }
        object.parts[property] = value; cpu.r[0] = 1
      } else if event == 0x801 && property == 0x5065 && !object.isRoot {
        object.parentForm = value; cpu.r[0] = 1
      } else if event == 0x801 && (property == 0x5064 || property == 0x507b) {
        if property == 0x5064 { object.active = value != 0 } else { object.visible = value != 0 }
        if object.isRoot, property == 0x5064, let top = object.stack.last {
          _ = try formInterfaceCall(top, 12, [event, property, value])
        }
        invalidateRootForm(object.isRoot ? handle : object.parentForm)
        cpu.r[0] = 1
      } else if event == 0x800 && value != 0 {
        switch property {
        case 0x5000:
          try memory.write32(value, object.widget)
          if object.widget != 0 { _ = try formInterfaceCall(object.widget, 0) }
        case 0x5001...0x5003:
          let part = object.parts[property] ?? 0
          if part != 0 { _ = try formInterfaceCall(part, 0) }
          try memory.write32(value, part)
        case 0x5064: try memory.write8(value, object.active ? 1 : 0)
        case 0x507b: try memory.write8(value, object.visible ? 1 : 0)
        case 0x5065:
          guard !object.isRoot else { cpu.r[0] = 0; return }
          if object.parentForm != 0 { _ = try formInterfaceCall(object.parentForm, 0) }
          try memory.write32(value, object.parentForm)
        case 0x5075: try memory.write32(value, shell)
        case 0x5079: try memory.write32(value, defaultDisplay ?? display)
        default: cpu.r[0] = 0; return
        }
        cpu.r[0] = 1
      } else if object.isRoot, let top = object.stack.last {
        cpu.r[0] = try formInterfaceCall(top, 12, [event, property, value])
      } else if object.widget != 0 {
        cpu.r[0] = try formInterfaceCall(object.widget, 12, [event, property, value])
      } else { cpu.r[0] = 0 }
    case 0x10:
      let pointer = cpu.r[1]
      let handler = pointer == 0 ? [0xf029ff04, handle, 0] : try (0..<3).map { try memory.read32(pointer + UInt32($0 * 4)) }
      if pointer != 0 {
        for i in 0..<3 { try memory.write32(pointer + UInt32(i * 4), object.handler[i]) }
      }
      object.handler = handler; cpu.r[0] = 0
    case 0x14: cpu.r[0] = try insertRootForm(handle, form: cpu.r[1], before: cpu.r[2])
    case 0x18: cpu.r[0] = try removeRootForm(handle, form: cpu.r[1])
    case 0x1c:
      let reference = cpu.r[1], next = cpu.r[2] != 0, wrap = cpu.r[3] != 0
      guard !object.stack.isEmpty else { cpu.r[0] = 0; return }
      let index: Int
      if reference == 0 { index = next ? 0 : object.stack.count - 1 }
      else if let current = object.stack.firstIndex(of: reference) { index = current + (next ? 1 : -1) }
      else { cpu.r[0] = 0; return }
      let resolved = wrap ? (index + object.stack.count) % object.stack.count : index
      cpu.r[0] = object.stack.indices.contains(resolved) ? object.stack[resolved] : 0
    case 0x24:
      let container = formWidgets[object.widget]?.container ?? 0
      if cpu.r[1] != 0 {
        if container != 0 { _ = try formInterfaceCall(container, 0) }
        try memory.write32(cpu.r[1], container)
      }
      if cpu.r[2] != 0 { try writeFormRect(cpu.r[2], SIMD4(0, 0, 640, 480)) }
      cpu.r[0] = 0
    default: throw EmulationError.hle("IRootForm+" + offset.hex, cpu.r[14])
    }
  }
  func createStaticControl() throws -> UInt32 {
    let handle = try allocate(4); guard handle != 0 else { return 0 }
    let table = hleAddress(0x21400)
    for offset in stride(from: UInt32(0), through: 0x40, by: 4) { try memory.write32(table + offset, 0xf02a0000 + offset) }
    try memory.write32(handle, table); staticControls[handle] = BREWStaticControl(); return handle
  }
  func staticText(_ pointer: UInt32) throws -> Data {
    if pointer == 0 { return Data([0, 0]) }
    var bytes = Data()
    for index in 0..<65536 {
      let unit = try memory.read16(pointer + UInt32(index * 2))
      bytes.append(UInt8(truncatingIfNeeded: unit)); bytes.append(UInt8(truncatingIfNeeded: unit >> 8))
      if unit == 0 { return bytes }
    }
    throw EmulationError.invalid("IStatic text without terminator")
  }
  func dispatchStaticControl(_ offset: UInt32) throws {
    let handle = cpu.r[0]
    guard let object = staticControls[handle] else { throw EmulationError.invalid("Released IStatic") }
    switch offset {
    case 0: object.references += 1; cpu.r[0] = object.references
    case 4:
      object.references -= 1; cpu.r[0] = object.references
      if object.references == 0 { staticControls.removeValue(forKey: handle); try free(handle) }
    case 8: cpu.r[0] = 0
    case 0xc:
      guard object.properties & 0x00800000 == 0 else { throw EmulationError.hle("IStatic icon text", cpu.r[14]) }
      let titleHeight = object.title.count > 2 ? 28 : 0
      try drawControlText(object.title, font: object.titleFont, rectangle: object.rectangle, y: 0,
        centered: object.properties & 0x00020000 != 0)
      try drawControlText(object.text, font: object.textFont, rectangle: object.rectangle, y: titleHeight,
        centered: object.properties & 0x00010000 != 0)
      cpu.r[0] = 1
    case 0x10: object.active = cpu.r[1] != 0; cpu.r[0] = 0
    case 0x14: cpu.r[0] = object.active ? 1 : 0
    case 0x18: object.rectangle = try memory.data(cpu.r[1], count: 8); cpu.r[0] = 0
    case 0x1c: try memory.write(cpu.r[1], data: object.rectangle); cpu.r[0] = 0
    case 0x20: object.properties = cpu.r[1]; cpu.r[0] = 0
    case 0x24: cpu.r[0] = object.properties
    case 0x28: object.title = Data([0, 0]); object.text = Data([0, 0]); object.active = false; cpu.r[0] = 0
    case 0x2c:
      let title = try staticText(cpu.r[1]), text = try staticText(cpu.r[2])
      object.title = title; object.text = text; object.titleFont = cpu.r[3]; object.textFont = try argument(4); cpu.r[0] = 1
    case 0x30: object.textFont = cpu.r[1]; object.titleFont = cpu.r[2]; cpu.r[0] = 0
    default: throw EmulationError.hle("IStatic+" + offset.hex, cpu.r[14])
    }
  }

  func drawControlText(_ bytes: Data, font: UInt32, rectangle: Data, y startY: Int, centered: Bool) throws {
    let units = stride(from: 0, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
    let string = String(decoding: units.prefix(while: { $0 != 0 }), as: UTF16.self)
    guard !string.isEmpty else { return }
    let width = Int(Int16(bitPattern: UInt16(rectangle[4]) | UInt16(rectangle[5]) << 8))
    let height = Int(Int16(bitPattern: UInt16(rectangle[6]) | UInt16(rectangle[7]) << 8))
    guard width > 0, height > 0 else { return }
    let face = BREWHostFonts.font(font) ?? BREWHostFonts.faces[0x8000]!
    let attributed = NSAttributedString(string: string, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): face])
    let typesetter = CTTypesetterCreateWithAttributedString(attributed)
    let lineHeight = BREWHostFonts.ascent(face) + BREWHostFonts.descent(face)
    let textPointer = try allocate(UInt32(bytes.count)), rectPointer = try allocate(8)
    defer { try? free(textPointer); try? free(rectPointer) }
    try memory.write(textPointer, data: bytes); try memory.write(rectPointer, data: rectangle)
    var index = 0, y = startY
    while index < attributed.length && y < height {
      let count = CTTypesetterSuggestLineBreak(typesetter, index, Double(width))
      guard count > 0 else { break }
      let line = CTTypesetterCreateLine(typesetter, CFRange(location: index, length: count))
      let x = centered ? max(0, (width - Int(ceil(CTLineGetTypographicBounds(line, nil, nil, nil)))) / 2) : 0
      let originX = Int(Int16(bitPattern: UInt16(rectangle[0]) | UInt16(rectangle[1]) << 8))
      let originY = Int(Int16(bitPattern: UInt16(rectangle[2]) | UInt16(rectangle[3]) << 8))
      _ = try invokeFormCallback(0xf0020010, [defaultDisplay ?? display, font, textPointer + UInt32(index * 2), UInt32(count), UInt32(truncatingIfNeeded: originX + x), UInt32(truncatingIfNeeded: originY + y), rectPointer, 0])
      index += count; y += lineHeight
    }
  }
  func createMenuControl() throws -> UInt32 {
    let handle = try allocate(4); guard handle != 0 else { return 0 }
    let table = hleAddress(0x21600)
    for offset in stride(from: UInt32(0), through: 0x90, by: 4) { try memory.write32(table + offset, 0xf02b0000 + offset) }
    try memory.write32(handle, table); menuControls[handle] = BREWMenuControl(); return handle
  }
  func menuText(file: UInt32, id: UInt32, pointer: UInt32) throws -> Data? {
    if pointer != 0 { return try staticText(pointer) }
    guard file != 0, let units = try resourceFile(file)?.stringUnits(id: UInt16(truncatingIfNeeded: id)) else { return nil }
    var bytes = Data()
    for unit in units { bytes.append(UInt8(truncatingIfNeeded: unit)); bytes.append(UInt8(unit >> 8)) }
    bytes.append(contentsOf: [0, 0]); return bytes
  }
  func dispatchMenuControl(_ offset: UInt32) throws {
    let handle = cpu.r[0]
    guard let object = menuControls[handle] else { throw EmulationError.invalid("Released IMenuCtl") }
    switch offset {
    case 0: object.references += 1; cpu.r[0] = object.references
    case 4:
      object.references -= 1; cpu.r[0] = object.references
      if object.references == 0 { menuControls.removeValue(forKey: handle); try free(handle) }
    case 8:
      let event = cpu.r[1], key = cpu.r[2]
      guard object.active, event == 0x100, !object.items.isEmpty else { cpu.r[0] = 0; return }
      let index = object.items.firstIndex { $0.id == object.selected } ?? 0
      if key == 0xe031 || key == 0xe033 { object.selected = object.items[(index + object.items.count - 1) % object.items.count].id }
      else if key == 0xe032 || key == 0xe034 { object.selected = object.items[(index + 1) % object.items.count].id }
      else if object.commands && (key == 0xe035 || key == 0xe036 || key == 0xe037) {
        let item = key == 0xe036 ? object.items.first! : key == 0xe037 ? object.items.last! : object.items[index]
        object.selected = item.id
        let table = try memory.read32(applet)
        _ = try invokeFormCallback(memory.read32(table + 8), [applet, 0x200, item.id, item.data])
      }
      else { cpu.r[0] = 0; return }
      cpu.r[0] = 1
    case 0xc:
      for (index, item) in object.items.enumerated() {
        var rect = object.rectangle
        let width = (Int(rect[4]) | Int(rect[5]) << 8) / max(1, object.items.count)
        let x = index * width
        rect[0] = UInt8(truncatingIfNeeded: x); rect[1] = UInt8(truncatingIfNeeded: x >> 8)
        rect[4] = UInt8(truncatingIfNeeded: width); rect[5] = UInt8(truncatingIfNeeded: width >> 8)
        try drawControlText(item.text, font: 0x8000, rectangle: rect, y: 0, centered: true)
      }
      cpu.r[0] = 1
    case 0x10: object.active = cpu.r[1] != 0; cpu.r[0] = 0
    case 0x14: cpu.r[0] = object.active ? 1 : 0
    case 0x18: object.rectangle = try memory.data(cpu.r[1], count: 8); cpu.r[0] = 0
    case 0x1c: try memory.write(cpu.r[1], data: object.rectangle); cpu.r[0] = 0
    case 0x20: object.properties = cpu.r[1]; cpu.r[0] = 0
    case 0x24: cpu.r[0] = object.properties
    case 0x28, 0x40: object.items.removeAll(); object.selected = 0; cpu.r[0] = 1
    case 0x2c:
      if let text = try menuText(file: cpu.r[1], id: cpu.r[2], pointer: cpu.r[3]) { object.title = text; cpu.r[0] = 1 }
      else { cpu.r[0] = 0 }
    case 0x30:
      let id = UInt32(UInt16(truncatingIfNeeded: cpu.r[3])), pointer = try argument(4), data = try argument(5)
      guard object.items.count < 1024, !object.items.contains(where: { $0.id == id }), let text = try menuText(file: cpu.r[1], id: cpu.r[2], pointer: pointer) else { cpu.r[0] = 0; return }
      object.items.append(.init(id: id, text: text, data: data)); if object.items.count == 1 { object.selected = id }; cpu.r[0] = 1
    case 0x38:
      guard cpu.r[2] != 0, let item = object.items.first(where: { $0.id == cpu.r[1] }) else { cpu.r[0] = 0; return }
      try memory.write32(cpu.r[2], item.data); cpu.r[0] = 1
    case 0x3c:
      let count = object.items.count; object.items.removeAll { $0.id == cpu.r[1] }; cpu.r[0] = object.items.count < count ? 1 : 0
    case 0x44: if object.items.contains(where: { $0.id == cpu.r[1] }) { object.selected = cpu.r[1] }; cpu.r[0] = 0
    case 0x48: cpu.r[0] = object.selected
    case 0x4c: object.commands = cpu.r[1] != 0; cpu.r[0] = 0
    case 0x60:
      let bytes = try memory.data(cpu.r[1], count: 40)
      let mask = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
      let oldMask = UInt16(object.colors[0]) | UInt16(object.colors[1]) << 8
      object.colors[0] = UInt8(truncatingIfNeeded: oldMask | mask); object.colors[1] = UInt8((oldMask | mask) >> 8)
      for (index, flag): (Int, UInt16) in [1, 2, 4, 8, 16, 64, 128, 256, 512].enumerated().map({ ($0.offset, UInt16($0.element)) }) where mask & flag != 0 {
        let start = 4 + index * 4; object.colors.replaceSubrange(start..<start + 4, with: bytes[start..<start + 4])
      }
      cpu.r[0] = 0
    case 0x68: cpu.r[0] = UInt32(object.items.count)
    case 0x6c: cpu.r[0] = Int(cpu.r[1]) < object.items.count ? object.items[Int(cpu.r[1])].id : 0
    default: throw EmulationError.hle("IMenuCtl+" + offset.hex, cpu.r[14])
    }
  }
}

// Original AEEIModel/AEEIValueModel layout: values remain guest-owned, and
// ModelListener callbacks execute as ARM code with their original context.
extension BREWRuntime {
  func createValueModel() throws -> UInt32 {
    let handle = try allocate(4); guard handle != 0 else { return 0 }
    let table = hleAddress(0x21800)
    for offset in stride(from: UInt32(0), through: 0x20, by: 4) {
      try memory.write32(table + offset, 0xf02d0000 + offset)
    }
    try memory.write32(handle, table); valueModels[handle] = BREWValueModel()
    return handle
  }
  func cancelValueListener(_ listener: UInt32) throws {
    let owner = try memory.read32(listener + 20)
    guard let model = valueModels[owner], let index = model.listeners.firstIndex(of: listener) else { return }
    let previous: UInt32 = index == 0 ? 0 : model.listeners[index - 1]
    let next: UInt32 = index + 1 == model.listeners.count ? 0 : model.listeners[index + 1]
    if previous != 0 { try memory.write32(previous, next) }
    if next != 0 { try memory.write32(next + 4, previous) }
    model.listeners.remove(at: index)
    for offset: UInt32 in [0, 4, 16, 20] { try memory.write32(listener + offset, 0) }
  }
  func releaseValueModel(_ handle: UInt32) throws -> UInt32 {
    guard let model = valueModels[handle] else { return 0 }
    model.references -= 1
    if model.references == 0 {
      for listener in model.listeners { try cancelValueListener(listener) }
      let callback = model.freeValue, value = model.value
      model.freeValue = 0
      valueModels.removeValue(forKey: handle)
      if model.interfaceType != nil && value != 0 { _ = try formInterfaceCall(value, 4) }
      if let items = model.vectorItems {
        for item in items { try releaseVectorItem(item, callback: model.freeItem) }
      }
      if callback != 0 { _ = try invokeFormCallback(callback, [value]) }
      try free(handle)
    }
    return model.references
  }
  func notifyValueModel(_ handle: UInt32, event: UInt32) throws {
    guard let model = valueModels[handle] else { return }
    _ = try memory.region(event, 12)
    model.references += 1
    defer { _ = try? releaseValueModel(handle) }
    for listener in model.listeners {
      guard model.listeners.contains(listener) else { continue }
      let callback = try memory.read32(listener + 8), context = try memory.read32(listener + 12)
      if callback != 0 { _ = try invokeFormCallback(callback, [context, event]) }
    }
  }
  func dispatchValueModel(_ offset: UInt32) throws {
    if offset == 0xff00 { try cancelValueListener(cpu.r[0]); cpu.r[0] = 0; return }
    let handle = cpu.r[0]
    guard let model = valueModels[handle] else { throw EmulationError.invalid("Released IValueModel") }
    if model.isViewModel && offset > 16 { throw EmulationError.hle("IModel+" + offset.hex, cpu.r[14]) }
    switch offset {
    case 0: model.references += 1; cpu.r[0] = model.references
    case 4: cpu.r[0] = try releaseValueModel(handle)
    case 8:
      guard cpu.r[2] != 0 else { cpu.r[0] = 14; return }
      let supported = [0x01000001, 0x0101593a].contains(cpu.r[1]) || !model.isViewModel && cpu.r[1] == 0x0101593b
      try memory.write32(cpu.r[2], supported ? handle : 0)
      if supported { model.references += 1 }; cpu.r[0] = supported ? 0 : 3
    case 12:
      let listener = cpu.r[1]
      guard listener != 0 else { cpu.r[0] = 14; return }
      _ = try memory.region(listener, 24)
      let cancel = try memory.read32(listener + 16)
      if cancel != 0 { _ = try invokeFormCallback(cancel, [listener]) }
      let previous = model.listeners.last ?? 0
      try memory.write32(listener, 0); try memory.write32(listener + 4, previous)
      if previous != 0 { try memory.write32(previous, listener) }
      try memory.write32(listener + 16, 0xf02dff00); try memory.write32(listener + 20, handle)
      model.listeners.append(listener); cpu.r[0] = 0
    case 16:
      try notifyValueModel(handle, event: cpu.r[1]); cpu.r[0] = 0
    case 20:
      var value = cpu.r[1], length = cpu.r[2], release = cpu.r[3]
      if model.adaptSet[0] != 0 {
        let scratch = try allocate(12); defer { try? free(scratch) }
        try memory.write32(scratch, value); try memory.write32(scratch + 4, length); try memory.write32(scratch + 8, release)
        _ = try invokeFormCallback(model.adaptSet[0], [model.adaptSet[1], value, length, scratch, scratch + 4, scratch + 8])
        value = try memory.read32(scratch); length = try memory.read32(scratch + 4); release = try memory.read32(scratch + 8)
      }
      let oldValue = model.value, oldRelease = model.freeValue
      model.value = value; model.length = length; model.freeValue = release
      if oldRelease != 0 { _ = try invokeFormCallback(oldRelease, [oldValue]) }
      let event = try allocate(12); defer { try? free(event) }
      try memory.write32(event, 0x1000); try memory.write32(event + 4, handle); try memory.write32(event + 8, 0)
      try notifyValueModel(handle, event: event); cpu.r[0] = 0
    case 24:
      let output = cpu.r[1]
      var value = model.value, length = model.length
      if model.adaptGet[0] != 0 {
        let scratch = try allocate(8); defer { try? free(scratch) }
        try memory.write32(scratch, value); try memory.write32(scratch + 4, length)
        _ = try invokeFormCallback(model.adaptGet[0], [model.adaptGet[1], value, length, scratch, scratch + 4])
        value = try memory.read32(scratch); length = try memory.read32(scratch + 4)
      }
      if output != 0 { try memory.write32(output, length) }; cpu.r[0] = value
    case 28: model.adaptGet = [cpu.r[1], cpu.r[2]]; cpu.r[0] = 0
    case 32: model.adaptSet = [cpu.r[1], cpu.r[2]]; cpu.r[0] = 0
    default: throw EmulationError.hle("IValueModel+" + offset.hex, cpu.r[14])
    }
  }
}

extension BREWRuntime {
  // The shipped tectoy.mod requests class 0x01011810 as ICM. Its diagnostics
  // name GetSSInfo, and its call sites pass (output, byteCount) at slot 0x70.
  // The host has no Zeebo cellular modem: expose object lifetime, but report
  // unsupported radio queries rather than inventing a service/signal structure.
  func createCallManager() throws -> UInt32 {
    let handle = try allocate(4); guard handle != 0 else { return 0 }
    let table = hleAddress(0x21900)
    for offset in stride(from: UInt32(0), through: 0x70, by: 4) {
      try memory.write32(table + offset, 0xf02e0000 + offset)
    }
    try memory.write32(handle, table); callManagers[handle] = 1
    return handle
  }
  func dispatchCallManager(_ offset: UInt32) throws {
    let handle = cpu.r[0]
    guard let references = callManagers[handle] else { throw EmulationError.invalid("Released ICM") }
    switch offset {
    case 0: callManagers[handle] = references + 1; cpu.r[0] = references + 1
    case 4:
      cpu.r[0] = references - 1
      if references == 1 { callManagers.removeValue(forKey: handle); try free(handle) }
      else { callManagers[handle] = references - 1 }
    case 8:
      guard cpu.r[2] != 0 else { cpu.r[0] = 14; return }
      let supported = cpu.r[1] == 0x01000001
      try memory.write32(cpu.r[2], supported ? handle : 0)
      if supported { callManagers[handle] = references + 1 }; cpu.r[0] = supported ? 0 : 3
    case 0x70:
      guard cpu.r[1] != 0, cpu.r[2] != 0 else { cpu.r[0] = 14; return }
      _ = try memory.region(cpu.r[1], Int(cpu.r[2]))
      cpu.r[0] = 20
    default: throw EmulationError.hle("ICM+" + offset.hex, cpu.r[14])
    }
  }
}

extension BREWRuntime {
  func saveShellAlarms(_ alarms: [UInt16: Int64]) throws {
    let record = Dictionary(uniqueKeysWithValues: alarms.map { (String($0.key), $0.value) })
    let bytes = try JSONEncoder().encode(record)
    try saveFile(Self.alarmSavePath, data: bytes)
    shellAlarms = alarms
  }
  func restoreShellAlarms() throws {
    guard let bytes = savedFiles[Self.alarmSavePath] else { return }
    let record = try JSONDecoder().decode([String: Int64].self, from: bytes)
    for (key, deadline) in record {
      guard let code = UInt16(key), deadline >= 0 else { throw EmulationError.invalid("Saved BREW alarm") }
      shellAlarms[code] = deadline
      queueShellAlarm(code, deadline: deadline)
    }
  }
  func queueShellAlarm(_ code: UInt16, deadline: Int64) {
    timers.removeAll { $0.callback == 0xf001fe00 && $0.context == UInt32(code) }
    // Persist UTC milliseconds; translate the remaining duration to the timer
    // clock on each session. A closed emulator does not wake the host computer.
    let remaining = UInt64(max(0, deadline - shellAlarmWallMilliseconds))
    let timer = ScheduledCallback(deadline: timerMilliseconds + remaining,
      callback: 0xf001fe00, context: UInt32(code))
    let index = timers.firstIndex { $0.deadline > timer.deadline } ?? timers.endIndex
    timers.insert(timer, at: index)
  }
  func changeShellAlarm(cancel: Bool) throws {
    guard cpu.r[1] == package.classID else { cpu.r[0] = 14; return }
    let key = UInt16(truncatingIfNeeded: cpu.r[2])
    var alarms = shellAlarms
    if cancel {
      guard alarms.removeValue(forKey: key) != nil else { cpu.r[0] = 1; return }
      try saveShellAlarms(alarms)
      timers.removeAll { $0.callback == 0xf001fe00 && $0.context == UInt32(key) }
    } else {
      let duration: Int64 = cpu.r[3] == 0 ? 5000 : Int64(cpu.r[3]) * 60_000
      let deadline = shellAlarmWallMilliseconds + duration
      alarms[key] = deadline
      try saveShellAlarms(alarms)
      queueShellAlarm(key, deadline: deadline)
    }
    cpu.r[0] = 0
  }
}

extension BREWRuntime {
  // AEEIVectorModel inherits IListModel/IModel. Reuse the base model's
  // listener registration and lifetime, while exposing the separate vector ABI.
  func createVectorModel() throws -> UInt32 {
    let handle = try createValueModel(); guard handle != 0 else { return 0 }
    valueModels[handle]!.vectorItems = []
    let table = hleAddress(0x21a00)
    for offset in stride(from: UInt32(0), through: 0x30, by: 4) {
      try memory.write32(table + offset, 0xf02f0000 + offset)
    }
    try memory.write32(handle, table)
    return handle
  }
  func releaseVectorItem(_ item: UInt32, callback: UInt32) throws {
    guard item != 0 else { return }
    if callback == UInt32.max { _ = try formInterfaceCall(item, 4) }
    else if callback != 0 { _ = try invokeFormCallback(callback, [item]) }
  }
  func notifyVector(_ handle: UInt32, position: Int, oldSize: Int) throws {
    guard let count = valueModels[handle]?.vectorItems?.count else { return }
    let event = try allocate(24); defer { try? free(event) }
    let words: [UInt32] = [0x1001, handle, 0, UInt32(position), UInt32(oldSize), UInt32(count)]
    for (i, word) in words.enumerated() { try memory.write32(event + UInt32(i * 4), word) }
    try notifyValueModel(handle, event: event)
  }
  func dispatchVectorModel(_ offset: UInt32) throws {
    let handle = cpu.r[0]
    guard let model = valueModels[handle], let items = model.vectorItems else {
      throw EmulationError.invalid("Released IVectorModel")
    }
    if [UInt32(0), 4, 12, 16].contains(offset) { try dispatchValueModel(offset); return }
    let index = Int(cpu.r[1]), oldSize = items.count
    switch offset {
    case 8:
      guard cpu.r[2] != 0 else { cpu.r[0] = 14; return }
      let supported = [0x01000001, 0x0101593a, 0x01015936, 0x0101594f].contains(cpu.r[1])
      try memory.write32(cpu.r[2], supported ? handle : 0)
      if supported { model.references += 1 }; cpu.r[0] = supported ? 0 : 3
    case 20: cpu.r[0] = UInt32(items.count)
    case 24:
      guard index < items.count, cpu.r[2] != 0 else { cpu.r[0] = 14; return }
      try memory.write32(cpu.r[2], items[index]); cpu.r[0] = 0
    case 28:
      guard index < items.count else { cpu.r[0] = 14; return }
      model.vectorItems![index] = cpu.r[2]
      try releaseVectorItem(items[index], callback: model.freeItem)
      try notifyVector(handle, position: index, oldSize: oldSize); cpu.r[0] = 0
    case 32:
      let destination = cpu.r[1] == UInt32.max ? items.count : index
      guard destination <= items.count else { cpu.r[0] = 14; return }
      guard items.count < 1_048_576 else { cpu.r[0] = 2; return }
      model.vectorItems!.insert(cpu.r[2], at: destination)
      try notifyVector(handle, position: destination, oldSize: oldSize); cpu.r[0] = 0
    case 36:
      guard index < items.count else { cpu.r[0] = 14; return }
      model.vectorItems!.remove(at: index)
      try releaseVectorItem(items[index], callback: model.freeItem)
      try notifyVector(handle, position: index, oldSize: oldSize); cpu.r[0] = 0
    case 40:
      model.vectorItems!.removeAll(keepingCapacity: true)
      for item in items { try releaseVectorItem(item, callback: model.freeItem) }
      try notifyVector(handle, position: 0, oldSize: oldSize); cpu.r[0] = 0
    case 44:
      guard index <= 1_048_576, cpu.r[2] <= 1_048_576 else { cpu.r[0] = 2; return }
      model.vectorItems!.reserveCapacity(index); cpu.r[0] = 0
    case 48:
      let previous = model.freeItem; model.freeItem = cpu.r[1]; cpu.r[0] = previous
    default: throw EmulationError.hle("IVectorModel+" + offset.hex, cpu.r[14])
    }
  }
}

// ImageWidget and IInterfaceModel use the original BREW UI interfaces. The
// stored IImage may be a guest implementation; drawing calls its actual ABI.
extension BREWRuntime {
  func createInterfaceModel() throws -> UInt32 {
    let handle = try createValueModel()
    guard handle != 0 else { return 0 }
    valueModels[handle]!.interfaceType = 0
    let table = hleAddress(0x21b00)
    for offset in stride(from: UInt32(0), through: 24, by: 4) {
      try memory.write32(table + offset, 0xf0300000 + offset)
    }
    try memory.write32(handle, table)
    return handle
  }
  func dispatchInterfaceModel(_ offset: UInt32) throws {
    let handle = cpu.r[0]
    guard let model = valueModels[handle], model.interfaceType != nil else {
      throw EmulationError.invalid("Released IInterfaceModel")
    }
    switch offset {
    case 0, 4, 12, 16: try dispatchValueModel(offset)
    case 8:
      guard cpu.r[2] != 0 else { cpu.r[0] = 14; return }
      let supported = [0x01000001, 0x0101593a, 0x0101593c].contains(cpu.r[1])
      try memory.write32(cpu.r[2], supported ? handle : 0)
      if supported { model.references += 1 }; cpu.r[0] = supported ? 0 : 3
    case 20:
      let value = cpu.r[1], type = cpu.r[2], old = model.value
      if value != 0 { _ = try formInterfaceCall(value, 0) }
      model.value = value; model.interfaceType = type
      if old != 0 { _ = try formInterfaceCall(old, 4) }
      let event = try allocate(12); defer { try? free(event) }
      try memory.write32(event, 0x1000); try memory.write32(event + 4, handle); try memory.write32(event + 8, 0)
      try notifyValueModel(handle, event: event); cpu.r[0] = 0
    case 24:
      let type = cpu.r[1], output = cpu.r[2]
      guard output != 0 else { cpu.r[0] = 14; return }
      guard type == model.interfaceType else { try memory.write32(output, 0); cpu.r[0] = 3; return }
      let value = model.value
      if value != 0 { _ = try formInterfaceCall(value, 0) }
      try memory.write32(output, value); cpu.r[0] = 0
    default: throw EmulationError.hle("IInterfaceModel+" + offset.hex, cpu.r[14])
    }
  }
  func createImageWidget() throws -> UInt32 {
    let handle = try createFormWidget()
    guard let widget = formWidgets[handle] else { return 0 }
    widget.extent = [0, 0]
    widget.modelListener = try allocate(24)
    try memory.write32(widget.modelListener + 8, 0xf02cff00)
    try memory.write32(widget.modelListener + 12, handle)
    let model = try createInterfaceModel()
    _ = try setImageWidgetModel(widget, model: model)
    _ = try releaseValueModel(model)
    return handle
  }
  func detachFormWidgetModel(_ widget: BREWFormWidget) throws {
    let cancel = try memory.read32(widget.modelListener + 16)
    if cancel != 0 { _ = try invokeFormCallback(cancel, [widget.modelListener]) }
    let old = widget.imageModel; widget.imageModel = 0
    if old != 0 { _ = try formInterfaceCall(old, 4) }
  }
  func setImageWidgetModel(_ widget: BREWFormWidget, model: UInt32) throws -> UInt32 {
    let scratch = try allocate(4); defer { try? free(scratch) }
    if model != 0 {
      let result = try formInterfaceCall(model, 8, [widget.isStaticText ? 0x0101593b : 0x0101593c, scratch])
      guard result == 0 else { return result }
    }
    let replacement = model == 0 ? 0 : try memory.read32(scratch)
    try detachFormWidgetModel(widget)
    widget.imageModel = replacement
    if replacement != 0 {
      let result = try formInterfaceCall(replacement, 12, [widget.modelListener])
      if result != 0 { try detachFormWidgetModel(widget); return result }
    }
    return 0
  }
  func widgetImage(_ widget: BREWFormWidget) throws -> UInt32 {
    guard widget.imageModel != 0 else { return 0 }
    let scratch = try allocate(4); defer { try? free(scratch) }
    guard try formInterfaceCall(widget.imageModel, 24, [0x01013110, scratch]) == 0 else { return 0 }
    return try memory.read32(scratch)
  }
  func widgetImageFrameCount(_ widget: BREWFormWidget) throws -> UInt32 {
    let image = try widgetImage(widget)
    guard image != 0 else { return 0 }
    defer { _ = try? formInterfaceCall(image, 4) }
    let scratch = try allocate(12); defer { try? free(scratch) }
    _ = try formInterfaceCall(image, 16, [scratch])
    let width = try memory.read16(scratch), frameWidth = try memory.read16(scratch + 8)
    return frameWidth > 0 ? max(1, width / frameWidth) : 1
  }
  func drawImageWidget(_ widget: BREWFormWidget, canvas: UInt32, x: Int, y: Int) throws {
    let image = try widgetImage(widget)
    guard image != 0 else { return }
    defer { _ = try? formInterfaceCall(image, 4) }
    // Tiling and selected-image composition need their own layout rules.
    guard widget.flags & 0x11000000 == 0 else { throw EmulationError.unsupported("ImageWidget tiled/selected image") }
    let scratch = try allocate(32); defer { try? free(scratch) }
    guard try formInterfaceCall(canvas, 12, [scratch]) == 0 else { return }
    let destination = try memory.read32(scratch)
    guard destination != 0 else { return }
    defer { _ = try? formInterfaceCall(destination, 4) }
    guard try formInterfaceCall(canvas, 20, [scratch + 4]) == 0 else { return }
    let rect = try (0..<4).map { Int(Int16(truncatingIfNeeded: try memory.read16(scratch + 4 + UInt32($0 * 2)))) }
    let left = max(x, rect[0]), top = max(y, rect[1])
    let right = min(x + Int(widget.extent[0]), rect[0] + rect[2])
    let bottom = min(y + Int(widget.extent[1]), rect[1] + rect[3])
    guard left < right, top < bottom else { return }
    _ = try formInterfaceCall(image, 16, [scratch + 16])
    let width = Int(try memory.read16(scratch + 24)), height = Int(try memory.read16(scratch + 18))
    var drawX = x, drawY = y
    if widget.flags & 0x40 != 0 { drawX += Int(widget.extent[0]) - width }
    else if widget.flags & 0x20 != 0 { drawX += (Int(widget.extent[0]) - width) / 2 }
    if widget.flags & 0x400 != 0 { drawY += Int(widget.extent[1]) - height }
    else if widget.flags & 0x200 != 0 { drawY += (Int(widget.extent[1]) - height) / 2 }
    let saved = captureDisplayContext(); defer { applyDisplayContext(saved) }
    displayDestination = destination; displayClip = SIMD4(left, top, right - left, bottom - top)
    _ = try formInterfaceCall(image, 12, [widget.imageFrame, UInt32(truncatingIfNeeded: drawX), UInt32(truncatingIfNeeded: drawY)])
  }
}

extension BREWRuntime {
  func createFormCanvas(bitmap: UInt32, clip: SIMD4<Int>) throws -> UInt32 {
    let handle = try allocate(4), table = hleAddress(0x21d00)
    guard handle != 0 else { return 0 }
    for offset in stride(from: UInt32(0), through: 32, by: 4) {
      try memory.write32(table + offset, 0xf0320000 + offset)
    }
    if bitmap != 0 { _ = try formInterfaceCall(bitmap, 0) }
    let canvas = BREWCanvas(); canvas.bitmap = bitmap; canvas.clip = clip
    try memory.write32(handle, table); formCanvases[handle] = canvas
    return handle
  }
  func writeFormRect(_ pointer: UInt32, _ rect: SIMD4<Int>) throws {
    for index in 0..<4 { try memory.write16(pointer + UInt32(index * 2), UInt32(UInt16(truncatingIfNeeded: rect[index]))) }
  }
  func dispatchFormCanvas(_ offset: UInt32) throws {
    let handle = cpu.r[0], pointer = cpu.r[1]
    guard let canvas = formCanvases[handle] else { throw EmulationError.invalid("Released ICanvas") }
    if canvas.display != 0 {
      let context = clonedDisplays[canvas.display] ?? captureDisplayContext()
      if context.destination != canvas.bitmap {
        try retainBitmap(context.destination)
        try releaseBitmap(canvas.bitmap); canvas.bitmap = context.destination
      }
      let size = try bitmapDimensions(canvas.bitmap)
      canvas.clip = context.clip ?? SIMD4(0, 0, size.x, size.y)
    }
    switch offset {
    case 0: canvas.references += 1; cpu.r[0] = canvas.references
    case 4:
      canvas.references -= 1
      if canvas.references == 0 {
        formCanvases.removeValue(forKey: handle)
        if canvas.bitmap != 0 { _ = try formInterfaceCall(canvas.bitmap, 4) }
        if canvas.display != 0 { _ = try releaseDisplay(canvas.display) }
        try free(handle)
      }
      cpu.r[0] = canvas.references
    case 8:
      guard cpu.r[2] != 0 else { cpu.r[0] = 14; return }
      let supported = [0x01000001, 0x0101e3f2, 0x0101e443].contains(pointer)
      try memory.write32(cpu.r[2], supported ? handle : 0)
      if supported { canvas.references += 1 }; cpu.r[0] = supported ? 0 : 3
    case 12:
      guard pointer != 0 else { cpu.r[0] = 14; return }
      if canvas.bitmap != 0 { _ = try formInterfaceCall(canvas.bitmap, 0) }
      try memory.write32(pointer, canvas.bitmap); cpu.r[0] = 0
    case 16:
      if canvas.display != 0 { _ = try formInterfaceCall(canvas.display, 0x38, [pointer]) }
      if pointer != 0 { _ = try formInterfaceCall(pointer, 0) }
      let old = canvas.bitmap; canvas.bitmap = pointer
      if old != 0 { _ = try formInterfaceCall(old, 4) }
      cpu.r[0] = 0
    case 20:
      guard pointer != 0 else { cpu.r[0] = 14; return }
      try writeFormRect(pointer, canvas.clip); cpu.r[0] = 0
    case 24:
      if canvas.display != 0 { _ = try formInterfaceCall(canvas.display, 0x48, [pointer]) }
      if pointer != 0 {
        canvas.clip = try SIMD4((0..<4).map { Int(Int16(truncatingIfNeeded: try memory.read16(pointer + UInt32($0 * 2)))) })
      } else if canvas.bitmap != 0 {
        let size = try bitmapDimensions(canvas.bitmap); canvas.clip = SIMD4(0, 0, size.x, size.y)
      } else { canvas.clip = .zero }
      cpu.r[0] = 0
    case 28:
      guard pointer != 0 else { cpu.r[0] = 14; return }
      if canvas.display == 0 {
        guard canvas.bitmap != 0 else { try memory.write32(pointer, 0); cpu.r[0] = 1; return }
        let clone = try allocate(4)
        guard clone != 0 else { try memory.write32(pointer, 0); cpu.r[0] = 2; return }
        try memory.write32(clone, memory.read32(display))
        try retainBitmap(canvas.bitmap)
        let settings = defaultDisplay.flatMap { clonedDisplays[$0]?.settings } ?? displaySettings()
        clonedDisplays[clone] = BREWDisplayContext(destination: canvas.bitmap, clip: canvas.clip, settings: settings)
        canvas.display = clone
      }
      _ = try formInterfaceCall(canvas.display, 0)
      try memory.write32(pointer, canvas.display); cpu.r[0] = 0
    case 32:
      guard pointer == 0 || pointer == display || clonedDisplays[pointer] != nil else { cpu.r[0] = 1; return }
      if pointer != 0 { _ = try formInterfaceCall(pointer, 0) }
      let old = canvas.display; canvas.display = pointer
      if old != 0 { _ = try releaseDisplay(old) }
      // Subsequent ICanvas queries read the wrapped display's live destination/clip.
      cpu.r[0] = 0
    default: throw EmulationError.hle("ICanvas+" + offset.hex, cpu.r[14])
    }
  }
  func createXYContainer() throws -> UInt32 {
    let widgetHandle = try createFormWidget(), handle = try allocate(4), table = hleAddress(0x21c00)
    guard let widget = formWidgets[widgetHandle], handle != 0 else { return 0 }
    for offset in stride(from: UInt32(0), through: 36, by: 4) {
      try memory.write32(table + offset, 0xf0310000 + offset)
    }
    widget.extent = [0, 0]; widget.container = handle
    formContainers[handle] = widgetHandle; try memory.write32(handle, table)
    return handle
  }
  func containerChildIndex(_ widget: BREWFormWidget, _ handle: UInt32) -> Int? {
    guard !widget.children.isEmpty else { return nil }
    if handle == 0 || handle == 1 { return widget.children.count - 1 }
    if handle == UInt32.max { return 0 }
    return widget.children.firstIndex { $0.handle == handle }
  }
  func moveContainerFocus(_ widget: BREWFormWidget, to target: UInt32) throws -> Bool {
    guard target == 0 || widget.children.contains(where: { $0.handle == target && $0.visible }) else { return false }
    let old = widget.focusChild
    guard old != target else { return true }
    widget.focusChild = 0
    if old != 0, widget.children.contains(where: { $0.handle == old }) {
      _ = try formInterfaceCall(old, 12, [0x700, 0, 0])
    }
    if target != 0, widget.children.contains(where: { $0.handle == target && $0.visible }) {
      widget.focusChild = target
      _ = try formInterfaceCall(target, 12, [0x700, 1, 0])
    }
    return widget.focusChild == target
  }
  func containerFocusEvent(_ widget: BREWFormWidget, event: UInt32, key: UInt32, value: UInt32) throws -> Bool? {
    switch event {
    case 0x713:
      guard value != 0 else { return false }
      let focused = widget.focusChild
      if focused != 0 { _ = try formInterfaceCall(focused, 0) }
      try memory.write32(value, focused); return true
    case 0x712:
      if widget.focusChild == value { _ = try moveContainerFocus(widget, to: 0) }
      widget.keyRecipients = widget.keyRecipients.filter { $0.value != value }
      return true
    case 0x700:
      widget.focused = key != 0
      if let child = widget.children.first(where: { $0.handle == widget.focusChild }) {
        _ = try formInterfaceCall(child.handle, 12, [event, key, value]); return true
      }
      if key == 0 { return true }
      return try containerFocusEvent(widget, event: 0x711, key: 0, value: 1)
    case 0x711:
      if value == 0 || value > 4 { return try moveContainerFocus(widget, to: value) }
      let indices = Array(widget.children.indices)
      let current = widget.children.firstIndex { $0.handle == widget.focusChild }
      let candidates: [Int]
      switch value {
      case 1: candidates = indices
      case 2: candidates = indices.reversed()
      case 3: candidates = indices.filter { $0 > (current ?? -1) }
      default: candidates = indices.reversed().filter { $0 < (current ?? indices.count) }
      }
      let scratch = try allocate(4); defer { try? free(scratch) }
      let children = candidates.map { widget.children[$0] }
      for child in children {
        guard widget.children.contains(where: { $0.handle == child.handle && $0.visible }) else { continue }
        try memory.write32(scratch, 0)
        if try formInterfaceCall(child.handle, 12, [0x702, 0, scratch]) != 0,
          try memory.read8(scratch) != 0 { return try moveContainerFocus(widget, to: child.handle) }
      }
      return false
    default: return nil
    }
  }
  func routeContainerEvent(_ widget: BREWFormWidget, event: UInt32, key: UInt32, value: UInt32) throws -> UInt32 {
    guard widget.flags & 4 == 0 else { return 0 }
    if widget.flags & 1 != 0 {
      for child in widget.children.reversed() where child.visible {
        if try formInterfaceCall(child.handle, 12, [event, key, value]) != 0 { return 1 }
      }
      return 0
    }
    var target = widget.focusChild
    if widget.flags & 2 == 0 {
      if event == 0x101 { widget.keyRecipients[key] = target }
      if event == 0x100 || event == 0x102 { target = widget.keyRecipients[key] ?? 0 }
      if event == 0x102 { widget.keyRecipients.removeValue(forKey: key) }
    }
    guard target != 0, widget.children.contains(where: { $0.handle == target && $0.visible }) else { return 0 }
    return try formInterfaceCall(target, 12, [event, key, value])
  }
  func dispatchXYContainer(_ offset: UInt32) throws {
    let handle = cpu.r[0]
    guard let widgetHandle = formContainers[handle], let widget = formWidgets[widgetHandle] else {
      throw EmulationError.invalid("Released IXYContainer")
    }
    let child = cpu.r[1]
    switch offset {
    case 0: widget.references += 1; cpu.r[0] = widget.references
    case 4: cpu.r[0] = try releaseFormWidget(widgetHandle)
    case 8:
      let output = cpu.r[2]
      guard output != 0 else { cpu.r[0] = 14; return }
      let isContainer = [0x01000001, 0x01015932, 0x01015954].contains(child)
      let isWidget = [0x01015952, 0x01015956].contains(child)
      try memory.write32(output, isContainer ? handle : isWidget ? widgetHandle : 0)
      if isContainer || isWidget { widget.references += 1 }; cpu.r[0] = isContainer || isWidget ? 0 : 3
    case 12:
      // Invalidations propagate through the hierarchy in container coordinates.
      if widget.parent != 0 { _ = try formInterfaceCall(widget.parent, 12, [widgetHandle, 0, cpu.r[3]]) }
      else if widget.rootForm != 0 { invalidateRootForm(widget.rootForm) }
      cpu.r[0] = 0
    case 20, 32:
      let before = cpu.r[2], pointer = cpu.r[3]
      let updating = offset == 32
      let oldIndex = containerChildIndex(widget, child)
      guard updating ? oldIndex != nil : child > 1 && child != UInt32.max && child != widgetHandle
        && !widget.children.contains(where: { $0.handle == child }) else { cpu.r[0] = 14; return }
      guard [0, 1, UInt32.max].contains(before) || widget.children.contains(where: { $0.handle == before }) else {
        cpu.r[0] = 14; return
      }
      let target = updating ? widget.children[oldIndex!].handle : child
      var entry = BREWFormWidget.Child(handle: target, x: 0, y: 0, visible: true)
      if pointer != 0 {
        entry.x = Int(Int32(bitPattern: try memory.read32(pointer)))
        entry.y = Int(Int32(bitPattern: try memory.read32(pointer + 4)))
        entry.visible = try memory.read8(pointer + 8) != 0
      }
      if !updating {
        // Reject parenting cycles and widgets that already belong to another container.
        var ancestor: UInt32 = handle
        while let parentWidget = formContainers[ancestor] {
          guard parentWidget != target else { cpu.r[0] = 14; return }
          ancestor = formWidgets[parentWidget]?.parent ?? 0
        }
        let scratch = try allocate(4); defer { try? free(scratch) }
        _ = try formInterfaceCall(target, 0x20, [scratch])
        let oldParent = try memory.read32(scratch)
        guard oldParent == 0 else { _ = try formInterfaceCall(oldParent, 4); cpu.r[0] = 14; return }
        _ = try formInterfaceCall(target, 0)
        _ = try formInterfaceCall(target, 0x24, [handle])
      }
      if updating && (before == 0 || before == target) { widget.children[oldIndex!] = entry }
      else {
        if updating { widget.children.remove(at: oldIndex!) }
        let index = before == UInt32.max ? 0 : (before == 0 || before == 1) ? widget.children.count
          : widget.children.firstIndex(where: { $0.handle == before })!
        widget.children.insert(entry, at: index)
      }
      if !entry.visible && widget.focusChild == target { _ = try moveContainerFocus(widget, to: 0) }
      cpu.r[0] = 0
    case 24:
      guard let index = containerChildIndex(widget, child) else { cpu.r[0] = 14; return }
      let removing = widget.children[index].handle
      if widget.focusChild == removing { _ = try moveContainerFocus(widget, to: 0) }
      widget.keyRecipients = widget.keyRecipients.filter { $0.value != removing }
      guard let currentIndex = widget.children.firstIndex(where: { $0.handle == removing }) else { cpu.r[0] = 0; return }
      let removed = widget.children.remove(at: currentIndex)
      _ = try formInterfaceCall(removed.handle, 0x24, [0]); _ = try formInterfaceCall(removed.handle, 4)
      cpu.r[0] = 0
    case 28:
      let next = cpu.r[2] != 0, wrap = cpu.r[3] != 0
      guard !widget.children.isEmpty else { cpu.r[0] = 0; return }
      let index: Int
      if child == 0 { index = next ? 0 : widget.children.count - 1 }
      else if let current = containerChildIndex(widget, child) {
        index = current + (next ? 1 : -1)
      } else { cpu.r[0] = 0; return }
      let resolved = wrap ? (index + widget.children.count) % widget.children.count : index
      cpu.r[0] = widget.children.indices.contains(resolved) ? widget.children[resolved].handle : 0
    case 36:
      let output = cpu.r[2]
      guard output != 0, let index = containerChildIndex(widget, child) else { cpu.r[0] = 14; return }
      let entry = widget.children[index]
      try memory.write32(output, UInt32(truncatingIfNeeded: entry.x)); try memory.write32(output + 4, UInt32(truncatingIfNeeded: entry.y))
      try memory.write8(output + 8, entry.visible ? 1 : 0); cpu.r[0] = 0
    default: throw EmulationError.hle("IXYContainer+" + offset.hex, cpu.r[14])
    }
  }
  func drawContainerWidget(_ widget: BREWFormWidget, canvas: UInt32, x: Int, y: Int) throws {
    let scratch = try allocate(12); defer { try? free(scratch) }
    guard try formInterfaceCall(canvas, 12, [scratch]) == 0 else { return }
    let bitmap = try memory.read32(scratch)
    guard bitmap != 0 else { return }
    defer { _ = try? formInterfaceCall(bitmap, 4) }
    guard try formInterfaceCall(canvas, 20, [scratch + 4]) == 0 else { return }
    let clip = try (0..<4).map { Int(Int16(truncatingIfNeeded: try memory.read16(scratch + 4 + UInt32($0 * 2)))) }
    let padding = widget.contentInsets
    let left = max(x + padding[0], clip[0]), top = max(y + padding[2], clip[1])
    let right = min(x + Int(widget.extent[0]) - padding[1], clip[0] + clip[2])
    let bottom = min(y + Int(widget.extent[1]) - padding[3], clip[1] + clip[3])
    guard left < right, top < bottom else { return }
    let localCanvas = try createFormCanvas(bitmap: bitmap, clip: SIMD4(left, top, right - left, bottom - top))
    defer { _ = try? formInterfaceCall(localCanvas, 4) }
    // Child canvases wrap the same display. Guest drawing code and its images
    // must see the same SetDestination changes while assembling an offscreen row.
    let wrappedDisplay = formCanvases[canvas]?.display ?? 0
    if wrappedDisplay != 0 {
      _ = try formInterfaceCall(localCanvas, 32, [wrappedDisplay])
      try writeFormRect(scratch + 4, SIMD4(left, top, right - left, bottom - top))
      _ = try formInterfaceCall(localCanvas, 24, [scratch + 4])
    }
    defer {
      if wrappedDisplay != 0 {
        try? writeFormRect(scratch + 4, SIMD4(clip))
        _ = try? formInterfaceCall(wrappedDisplay, 0x48, [scratch + 4])
      }
    }
    for child in widget.children where child.visible {
      guard widget.children.contains(where: { $0.handle == child.handle }) else { continue }
      _ = try formInterfaceCall(child.handle, 40, [localCanvas, UInt32(truncatingIfNeeded: x + child.x), UInt32(truncatingIfNeeded: y + child.y)])
    }
  }
}

extension BREWRuntime {
  func invalidateRootForm(_ handle: UInt32) {
    guard let root = rootForms[handle], root.isRoot,
      !timers.contains(where: { $0.callback == 0xf029ff08 && $0.context == handle }) else { return }
    scheduleCallback(delay: 0, callback: 0xf029ff08, context: handle)
  }
  func formContent(_ form: UInt32) throws -> UInt32 {
    let out = try allocate(4); defer { try? free(out) }
    guard try formInterfaceCall(form, 12, [0x800, 0x5000, out]) != 0 else { return 0 }
    return try memory.read32(out)
  }
  func updateRootFormStack(_ handle: UInt32, oldTop: UInt32?) throws {
    guard let root = rootForms[handle], let container = formWidgets[root.widget] else { return }
    let top = root.stack.last
    if oldTop != top, let oldTop {
      _ = try formInterfaceCall(oldTop, 12, [0x801, 0x5064, 0])
    }
    for (index, form) in root.stack.enumerated() {
      let content = try formContent(form)
      if content != 0 {
        if let child = container.children.firstIndex(where: { $0.handle == content }) {
          container.children[child].visible = index == root.stack.count - 1
        }
        _ = try formInterfaceCall(content, 4)
      }
    }
    if let top, oldTop != top {
      // IRootForm_PushForm activates the newly frontmost form. Subsequent
      // explicit activation/deactivation of the root is forwarded separately.
      _ = try formInterfaceCall(top, 12, [0x801, 0x5064, 1])
    }
    invalidateRootForm(handle)
  }
  func insertRootForm(_ handle: UInt32, form: UInt32, before: UInt32) throws -> UInt32 {
    guard let root = rootForms[handle], root.isRoot, form > 5, form != handle,
      !root.stack.contains(form), let container = formWidgets[root.widget], container.container != 0,
      [0, 1, 2].contains(before) || root.stack.contains(before) else { return 14 }
    if let child = rootForms[form], child.parentForm != 0 { return 14 }
    let content = try formContent(form)
    guard content != 0 else { return 3 }
    defer { _ = try? formInterfaceCall(content, 4) }
    let scratch = try allocate(8); defer { try? free(scratch) }
    try memory.write32(scratch, 640); try memory.write32(scratch + 4, 480)
    _ = try formInterfaceCall(content, 28, [scratch])
    let index = before == 2 ? 0 : [0, 1].contains(before) ? root.stack.count : root.stack.firstIndex(of: before)!
    let beforeWidget: UInt32
    if index < root.stack.count {
      beforeWidget = try formContent(root.stack[index])
    } else { beforeWidget = 1 }
    defer { if beforeWidget > 1 { _ = try? formInterfaceCall(beforeWidget, 4) } }
    let result = try formInterfaceCall(container.container, 20, [content, beforeWidget, 0])
    guard result == 0 else { return result }
    let oldTop = root.stack.last
    _ = try formInterfaceCall(form, 0)
    root.stack.insert(form, at: index)
    _ = try formInterfaceCall(form, 12, [0x801, 0x5065, handle])
    try updateRootFormStack(handle, oldTop: oldTop)
    return 0
  }
  func removeRootForm(_ handle: UInt32, form: UInt32) throws -> UInt32 {
    guard let root = rootForms[handle], root.isRoot, !root.stack.isEmpty,
      let container = formWidgets[root.widget] else { return 14 }
    if form == 5 {
      while let top = root.stack.last { _ = try removeRootForm(handle, form: top) }
      return 0
    }
    let index: Int
    if form == 0 || form == 1 { index = root.stack.count - 1 }
    else if form == 2 { index = 0 }
    else if let position = root.stack.firstIndex(of: form) { index = position }
    else { return 14 }
    let removed = root.stack[index], oldTop = root.stack.last
    let content = try formContent(removed)
    root.stack.remove(at: index)
    if content != 0 {
      _ = try formInterfaceCall(container.container, 24, [content]); _ = try formInterfaceCall(content, 4)
    }
    _ = try formInterfaceCall(removed, 12, [0x801, 0x5065, 0])
    try updateRootFormStack(handle, oldTop: oldTop)
    _ = try formInterfaceCall(removed, 4)
    return 0
  }
  func drawRootForm(_ handle: UInt32) throws {
    // Focus/activation does not hide a visible form.
    guard let root = rootForms[handle], root.isRoot, root.visible, root.widget != 0 else { return }
    let canvas = try createFormCanvas(bitmap: bitmap, clip: SIMD4(0, 0, 640, 480))
    defer { _ = try? formInterfaceCall(canvas, 4) }
    _ = try formInterfaceCall(canvas, 32, [display])
    _ = try formInterfaceCall(root.widget, 40, [canvas, 0, 0])
    try publishFrame()
  }
}

// CListWidget, original BREW IListModel + IDecorator ABI. One original item
// widget is rebound and drawn for each visible row; the application owns its data.
final class BREWListWidget {
  var model: UInt32 = 0, viewModel: UInt32 = 0, listener: UInt32 = 0
  var indexer: [UInt32] = [0, 0]
  var focus = 0, top = 0, height = 0, width = 0
  var hintRows: Int?
  var binding = false
}
extension BREWRuntime {
  func createListWidget() throws -> UInt32 {
    let handle = try createViewportWidget(), widget = formWidgets[handle]!
    let list = BREWListWidget(); list.viewModel = widget.viewport!.viewModel
    widget.viewport = nil; widget.list = list
    list.model = try createVectorModel()
    list.listener = try allocate(24)
    try memory.write32(list.listener + 8, 0xf02cff10)
    try memory.write32(list.listener + 12, handle)
    _ = try formInterfaceCall(list.model, 12, [list.listener])
    return handle
  }
  func detachListModel(_ list: BREWListWidget) throws {
    let cancel = try memory.read32(list.listener + 16)
    if cancel != 0 { _ = try invokeFormCallback(cancel, [list.listener]) }
    let old = list.model; list.model = 0
    if old != 0 { _ = try formInterfaceCall(old, 4) }
  }
  func setListModel(_ handle: UInt32, _ widget: BREWFormWidget, model: UInt32) throws -> UInt32 {
    let list = widget.list!, scratch = try allocate(4); defer { try? free(scratch) }
    if model != 0 {
      let error = try formInterfaceCall(model, 8, [0x01015936, scratch])
      guard error == 0 else { return error }
    }
    let replacement = model == 0 ? 0 : try memory.read32(scratch)
    try detachListModel(list); list.model = replacement
    if replacement != 0 { _ = try formInterfaceCall(replacement, 12, [list.listener]) }
    try updateListWidget(handle, widget)
    return 0
  }
  func listCount(_ list: BREWListWidget) throws -> Int {
    list.model == 0 ? 0 : min(1_048_576, Int(try formInterfaceCall(list.model, 20)))
  }
  func listItemSize(_ widget: BREWFormWidget) throws -> [Int] {
    let list = widget.list!, scratch = try allocate(8); defer { try? free(scratch) }
    var size = [Int(widget.extent[0]), 18]
    if let child = widget.children.first {
      _ = try formInterfaceCall(child.handle, 20, [scratch])
      size = [Int(try memory.read32(scratch)), Int(try memory.read32(scratch + 4))]
    }
    return [max(1, list.width > 0 ? list.width : size[0]), max(1, list.height > 0 ? list.height : size[1])]
  }
  func listNotification(_ list: BREWListWidget, code: UInt32, index: Int) throws {
    guard list.viewModel != 0 else { return }
    let event = try allocate(20); defer { try? free(event) }
    let words: [UInt32] = [code, list.viewModel, UInt32(truncatingIfNeeded: index),
      UInt32(truncatingIfNeeded: list.focus), UInt32(try listCount(list))]
    for (i, word) in words.enumerated() { try memory.write32(event + UInt32(i * 4), word) }
    _ = try formInterfaceCall(list.viewModel, 16, [event])
  }
  func updateListWidget(_ handle: UInt32, _ widget: BREWFormWidget, reveal: Bool = true) throws {
    guard let list = widget.list, !list.binding else { return }
    let count = try listCount(list), size = try listItemSize(widget)
    list.focus = max(0, min(list.focus, count - 1))
    let visible = max(1, Int(widget.extent[1]) / size[1])
    list.top = max(0, min(list.top, count - 1))
    if reveal {
      if list.focus < list.top { list.top = list.focus }
      if list.focus >= list.top + visible { list.top = list.focus - visible + 1 }
    }
    if list.viewModel != 0 {
      let event = try allocate(20); defer { try? free(event) }
      try memory.write32(event, 0x1064); try memory.write32(event + 4, list.viewModel)
      try memory.write8(event + 12, 1)
      try memory.write16(event + 14, UInt32(min(count, 65535)))
      try memory.write16(event + 16, UInt32(min(visible, 65535)))
      try memory.write16(event + 18, UInt32(min(list.top, 65535)))
      _ = try formInterfaceCall(list.viewModel, 16, [event])
    }
    if widget.parent != 0 { _ = try formInterfaceCall(widget.parent, 12, [handle, 0, 0]) }
  }
  func listWidgetEvent(_ handle: UInt32, _ widget: BREWFormWidget, event: UInt32, key: UInt32, value: UInt32) throws -> Bool? {
    let list = widget.list!
    if event == 0x700 {
      widget.focused = key != 0
      if let child = widget.children.first { _ = try formInterfaceCall(child.handle, 12, [event, key, value]) }
      try updateListWidget(handle, widget); return true
    }
    if event == 0x800, value != 0 {
      let result: UInt32
      switch key {
      case 0x161:
        if list.viewModel != 0 { _ = try formInterfaceCall(list.viewModel, 0) }
        result = list.viewModel
      case 0x165: result = UInt32(list.focus)
      case 0x166: result = UInt32(list.top)
      case 0x167: result = UInt32(list.height)
      case 0x168: result = UInt32(list.width)
      case 0x169: result = UInt32(Int(widget.extent[1]) / (try listItemSize(widget))[1])
      case 0x170: result = 1
      case 0x171: result = UInt32(list.hintRows ?? 0)
      default: return nil
      }
      try memory.write32(value, result); return true
    }
    if event == 0x801 {
      switch key {
      case 0x163:
        guard value != 0 else { list.indexer = [0, 0]; return true }
        list.indexer = [try memory.read32(value), try memory.read32(value + 4)]
      case 0x161:
        let scratch = try allocate(4); defer { try? free(scratch) }
        if value != 0, try formInterfaceCall(value, 8, [0x0101593a, scratch]) != 0 { return false }
        let old = list.viewModel; list.viewModel = value == 0 ? 0 : try memory.read32(scratch)
        if old != 0 { _ = try formInterfaceCall(old, 4) }
      case 0x165, 0x164:
        guard Int(value) < (try listCount(list)) else { return false }
        let old = list.focus; list.focus = Int(value)
        try updateListWidget(handle, widget)
        if old != list.focus { try listNotification(list, code: 0x1007, index: list.focus) }
        if key == 0x164 { try listNotification(list, code: 0x1008, index: list.focus) }
        return true
      case 0x166: list.top = Int(value); try updateListWidget(handle, widget, reveal: false); return true
      case 0x167: guard value <= 65535 else { return false }; list.height = Int(value)
      case 0x168: guard value <= 65535 else { return false }; list.width = Int(value)
      case 0x171: guard value <= 65535 else { return false }; list.hintRows = Int(value)
      case 0x183: break
      case 0x153:
        // Fixed vertical lists currently implement wrap and no-selection modes.
        guard value & ~UInt32(3) == 0 else { return false }
        widget.flags = value
      default: return nil
      }
      try updateListWidget(handle, widget); return true
    }
    if event == 0x100 && [UInt32(0xe031), 0xe032, 0xe035].contains(key) {
      let count = try listCount(list)
      guard count > 0 else { return false }
      if key == 0xe035 {
        guard widget.flags & 2 == 0 else { return false }
        try listNotification(list, code: 0x1008, index: list.focus); return true
      }
      let old = list.focus, delta = key == 0xe031 ? -1 : 1
      let next = old + delta
      if widget.flags & 2 != 0 {
        list.top = max(0, min(count - 1, list.top + delta))
        try updateListWidget(handle, widget, reveal: false); return true
      }
      if next < 0 || next >= count {
        guard widget.flags & 1 != 0 else { return false }
        list.focus = (next + count) % count
      } else { list.focus = next }
      try updateListWidget(handle, widget)
      if old != list.focus { try listNotification(list, code: 0x1007, index: list.focus) }
      return true
    }
    return nil
  }
  func drawListWidget(_ widget: BREWFormWidget, canvas: UInt32, x: Int, y: Int) throws {
    guard let list = widget.list, !list.binding, let child = widget.children.first else { return }
    let count = try listCount(list), size = try listItemSize(widget)
    guard list.top < count else { return }
    list.binding = true; defer { list.binding = false }
    let scratch = try allocate(24); defer { try? free(scratch) }
    guard try formInterfaceCall(canvas, 12, [scratch]) == 0 else { return }
    let bitmap = try memory.read32(scratch); guard bitmap != 0 else { return }
    defer { _ = try? formInterfaceCall(bitmap, 4) }
    _ = try formInterfaceCall(canvas, 20, [scratch + 4])
    let clip = try (0..<4).map { Int(Int16(truncatingIfNeeded: try memory.read16(scratch + 4 + UInt32($0 * 2)))) }
    let left = max(x, clip[0]), top = max(y, clip[1])
    let right = min(x + Int(widget.extent[0]), clip[0] + clip[2])
    let bottom = min(y + Int(widget.extent[1]), clip[1] + clip[3])
    guard left < right, top < bottom else { return }
    var itemModel: UInt32 = 0
    if try formInterfaceCall(child.handle, 48, [0x0101593b, scratch]) == 0 { itemModel = try memory.read32(scratch) }
    defer { if itemModel != 0 { _ = try? formInterfaceCall(itemModel, 4) } }
    try memory.write32(scratch, widget.extent[0]); try memory.write32(scratch + 4, UInt32(size[1]))
    _ = try formInterfaceCall(child.handle, 28, [scratch])
    let end = min(count, list.top + (Int(widget.extent[1]) + size[1] - 1) / size[1])
    for index in list.top..<end {
      let rowY = y + (index - list.top) * size[1], rowTop = max(top, rowY), rowBottom = min(bottom, rowY + size[1])
      guard rowTop < rowBottom else { continue }
      if itemModel != 0, try formInterfaceCall(list.model, 24, [UInt32(index), scratch]) == 0 {
        _ = try formInterfaceCall(itemModel, 20, [try memory.read32(scratch), 0, 0])
      }
      let selected: UInt32 = widget.flags & 2 == 0 && index == list.focus ? 1 : 0
      _ = try formInterfaceCall(child.handle, 12, [0x801, 0x151, selected])
      if list.indexer[0] != 0 { _ = try invokeFormCallback(list.indexer[0], [list.indexer[1], UInt32(index), selected]) }
      let rowCanvas = try createFormCanvas(bitmap: bitmap, clip: SIMD4(left, rowTop, right - left, rowBottom - rowTop))
      defer { _ = try? formInterfaceCall(rowCanvas, 4) }
      _ = try formInterfaceCall(child.handle, 40, [rowCanvas, UInt32(truncatingIfNeeded: x), UInt32(truncatingIfNeeded: rowY)])
    }
  }
}
