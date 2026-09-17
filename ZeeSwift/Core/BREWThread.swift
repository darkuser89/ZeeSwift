import Foundation

/// Original cooperative guest scheduling. No host thread shares the guest CPU/memory.
final class BREWThread {
  enum State { case new, running, suspended, ended }
  var state = State.new
  var references: UInt32 = 1
  var registers = [UInt32](repeating: 0, count: 16)
  var cpsr: UInt32 = 0x10
  var stack: UInt32 = 0
  var entry: UInt32 = 0
  var context: UInt32 = 0
  var result: UInt32 = 0
  var depth = 0
  let callback: UInt32
  var allocations = Set<UInt32>()
  var resources: [UInt32] = []
  var joins: [(callback: UInt32, result: UInt32)] = []
  init(callback: UInt32) { self.callback = callback }
}
private enum GuestThreadControl: Error { case suspend, exit }

extension BREWRuntime {
  func createThread() throws -> UInt32 {
    let handle = try allocate(32)
    guard handle != 0 else { return 0 }
    let table: UInt32 = hleAddress(0x16000)
    for offset in stride(from: UInt32(0), through: 0x2c, by: 4) {
      try memory.write32(table + offset, 0xf012_0000 + offset)
    }
    try memory.write32(handle, table)
    let callback = handle + 8
    try memory.write32(callback + 16, 0xf012_0100)
    try memory.write32(callback + 20, handle)
    threads[handle] = BREWThread(callback: callback)
    return handle
  }
  func cancelGuestCallback(_ callback: UInt32) throws {
    guard callback != 0 else { return }
    let previousCancel = try memory.read32(callback + 8)
    if previousCancel != 0 && previousCancel != 0xf012_0104 {
      let registers = (0..<16).map { cpu.r[$0] }
      let flags = cpu.cpsr
      defer {
        for i in 0..<16 { cpu.r[i] = registers[i] }
        cpu.cpsr = flags
      }
      _ = try invoke(previousCancel, [callback])
    }
    timers.removeAll { $0.callback == callback && $0.context == callback }
    for thread in threads.values { thread.joins.removeAll { $0.callback == callback } }
    try memory.write32(callback + 8, 0)
    try memory.write32(callback + 12, 0)
  }
  func scheduleGuestCallback(_ callback: UInt32, delay: UInt32 = 0) throws {
    guard callback != 0 else { return }
    _ = try memory.region(callback, 24)
    try cancelGuestCallback(callback)
    try memory.write32(callback + 8, 0xf012_0104)
    scheduleCallback(delay: delay, callback: callback, context: callback)
  }
  private func finishThread(_ handle: UInt32, result: UInt32) throws {
    guard let thread = threads[handle], thread.state != .ended else { return }
    thread.state = .ended
    thread.result = result
    try cancelGuestCallback(thread.callback)
    if thread.stack != 0 {
      try free(thread.stack)
      thread.stack = 0
    }
    let joins = thread.joins
    thread.joins.removeAll()
    for join in joins {
      if join.result != 0 { try memory.write32(join.result, result) }
      try scheduleGuestCallback(join.callback)
    }
  }
  private func releaseThreadResource(_ object: UInt32) throws -> UInt32 {
    let registers = (0..<16).map { cpu.r[$0] }
    let flags = cpu.cpsr
    defer {
      for i in 0..<16 { cpu.r[i] = registers[i] }
      cpu.cpsr = flags
    }
    let vtable = try memory.read32(object)
    return try invoke(memory.read32(vtable + 4), [object])
  }
  private func destroyThread(_ handle: UInt32) throws {
    guard let thread = threads[handle] else { return }
    guard thread.state != .running || (activeThread == handle && invocationDepth == thread.depth)
    else {
      throw EmulationError.unsupported("IThread release during nested guest execution")
    }
    if thread.state != .new && thread.state != .ended { try finishThread(handle, result: .max) }
    try cancelGuestCallback(thread.callback)
    let pending = thread.joins
    thread.joins.removeAll()
    for join in pending { try cancelGuestCallback(join.callback) }
    threads.removeValue(forKey: handle)
    for pointer in thread.allocations { try free(pointer) }
    for resource in thread.resources { _ = try releaseThreadResource(resource) }
    try free(handle)
  }
  func runThread(_ handle: UInt32, first: Bool = false) throws {
    guard let thread = threads[handle], thread.state == .suspended else { return }
    let registers = (0..<16).map { cpu.r[$0] }
    let flags = cpu.cpsr
    let previous = activeThread
    defer {
      for i in 0..<16 { cpu.r[i] = registers[i] }
      cpu.cpsr = flags
      activeThread = previous
    }
    activeThread = handle
    thread.state = .running
    thread.depth = invocationDepth + 1
    for i in 0..<16 { cpu.r[i] = thread.registers[i] }
    cpu.cpsr = thread.cpsr
    do {
      let result: UInt32
      if first {
        result = try invoke(thread.entry, [handle, thread.context], budget: 100_000_000)
      } else {
        result = try continueGuestExecution(budget: 100_000_000)
      }
      try finishThread(handle, result: result)
    } catch GuestThreadControl.suspend {
      // The Suspend trap saved PC/CPSR/registers before unwinding to the host queue.
    } catch GuestThreadControl.exit {
      // Exit completed the thread and does not return to its guest caller.
    }
  }
  func dispatchThread(_ offset: UInt32) throws {
    if offset == 0x100 {
      try runThread(cpu.r[0])
      return
    }
    if offset == 0x104 {
      try cancelGuestCallback(cpu.r[0])
      return
    }
    let handle = cpu.r[0]
    let p1 = cpu.r[1]
    let p2 = cpu.r[2]
    let p3 = cpu.r[3]
    guard let thread = threads[handle] else {
      throw EmulationError.invalid("Released IThread")
    }
    switch offset {
    case 0:
      thread.references += 1
      cpu.r[0] = thread.references
    case 4:
      thread.references -= 1
      cpu.r[0] = thread.references
      if thread.references == 0 {
        let running = activeThread == handle
        try destroyThread(handle)
        if running {
          cpu.count &+= 1
          throw GuestThreadControl.exit
        }
      }
    case 8:
      let supported = [UInt32(0x0100_1017), 0x0103_67a7, 0x0100_0001].contains(p1)
      try memory.write32(p2, supported ? handle : 0)
      if supported { thread.references += 1 }
      cpu.r[0] = supported ? 0 : 3
    case 0x0c:
      let pointer = try allocate(p1)
      if pointer != 0 { thread.allocations.insert(pointer) }
      cpu.r[0] = pointer
    case 0x10:
      if p1 != 0 {
        guard thread.allocations.remove(p1) != nil else {
          throw EmulationError.invalid("IThread.Free: foreign allocation")
        }
        try free(p1)
      }
      cpu.r[0] = 0
    case 0x14:
      guard p1 != 0 else {
        cpu.r[0] = 14
        return
      }
      _ = try memory.region(p1, 4)
      thread.resources.append(p1)  // HoldRsc transfers ownership without AddRef.
      cpu.r[0] = 0
    case 0x18:
      if let index = thread.resources.firstIndex(of: p1) {
        thread.resources.remove(at: index)
        cpu.r[0] = try releaseThreadResource(p1)
      } else {
        cpu.r[0] = .max
      }
    case 0x1c:
      guard thread.state == .new else {
        cpu.r[0] = 26
        return
      }
      guard Int32(bitPattern: p1) > 0, p1 <= 32 * 1024 * 1024 else {
        cpu.r[0] = 2
        return
      }
      guard p2 != 0 else {
        cpu.r[0] = 14
        return
      }
      // Allow room for ABI stack arguments and HLE callback adapters below the guest SP.
      let bytes = (p1 + 4096 + 7) & ~7
      let stack = try allocate(bytes)
      guard stack != 0 else {
        cpu.r[0] = 2
        return
      }
      thread.stack = stack
      thread.entry = p2
      thread.context = p3
      thread.registers = (0..<16).map { cpu.r[$0] }
      thread.registers[13] = stack + bytes - 64
      thread.cpsr = cpu.cpsr
      thread.state = .suspended
      try runThread(handle, first: true)
      cpu.r[0] = 0
    case 0x20:
      guard thread.state != .new else {
        cpu.r[0] = 1
        return
      }
      guard thread.state != .ended else {
        cpu.r[0] = 26
        return
      }
      if thread.state == .running && (activeThread != handle || invocationDepth != thread.depth) {
        throw EmulationError.unsupported("IThread.Exit from nested HLE guest callback")
      }
      try finishThread(handle, result: p1)
      if activeThread == handle {
        cpu.count &+= 1
        throw GuestThreadControl.exit
      }
      cpu.r[0] = 0
    case 0x24:
      guard p1 != 0 else { return }
      _ = try memory.region(p1, 24)
      if p2 != 0 { _ = try memory.region(p2, 4) }
      try cancelGuestCallback(p1)
      if thread.state == .ended {
        if p2 != 0 { try memory.write32(p2, thread.result) }
        try scheduleGuestCallback(p1)
      } else {
        thread.joins.append((p1, p2))
        try memory.write32(p1 + 8, 0xf012_0104)
      }
    case 0x28:
      guard activeThread == handle else { return }
      guard invocationDepth == thread.depth else {
        throw EmulationError.unsupported("IThread.Suspend from nested HLE guest callback")
      }
      cpu.branch(cpu.r[14])
      thread.registers = (0..<16).map { cpu.r[$0] }
      thread.cpsr = cpu.cpsr
      thread.state = .suspended
      cpu.count &+= 1
      throw GuestThreadControl.suspend
    case 0x2c: cpu.r[0] = thread.callback
    default: throw EmulationError.hle("IThread+" + offset.hex, cpu.r[14])
    }
  }
}
