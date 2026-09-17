import Foundation

extension BREWRuntime {
  /// BREW qsort calls the game's comparator with pointers into the guest array.
  /// A bounded heapsort keeps host stack use independent of the input ordering.
  func sortGuest(base: UInt32, count: UInt32, size: UInt32, comparator: UInt32) throws {
    guard count > 1, size > 0 else { return }
    let bytes = UInt64(count) * UInt64(size)
    guard bytes <= 32 * 1024 * 1024 else { throw EmulationError.invalid("QSORT size") }
    _ = try memory.region(base, Int(bytes))
    let registers = (0..<16).map { cpu.r[$0] }
    let status = cpu.cpsr
    defer {
      for i in 0..<16 { cpu.r[i] = registers[i] }
      cpu.cpsr = status
    }
    func address(_ index: Int) -> UInt32 { base + UInt32(index) * size }
    func less(_ a: Int, _ b: Int) throws -> Bool {
      // invoke() changes caller registers and LR. The outer HLE call must resume
      // with its own register frame after all nested guest callbacks have returned.
      let result = try invoke(comparator, [address(a), address(b)])
      return Int32(bitPattern: result) < 0
    }
    func swap(_ a: Int, _ b: Int) throws {
      guard a != b else { return }
      let value = try memory.data(address(a), count: Int(size))
      try memory.write(address(a), data: memory.data(address(b), count: Int(size)))
      try memory.write(address(b), data: value)
    }
    func sift(_ start: Int, _ end: Int) throws {
      var root = start
      while root * 2 + 1 < end {
        var child = root * 2 + 1
        if child + 1 < end, try less(child, child + 1) { child += 1 }
        if try !less(root, child) { return }
        try swap(root, child)
        root = child
      }
    }
    let n = Int(count)
    for root in stride(from: n / 2 - 1, through: 0, by: -1) { try sift(root, n) }
    for end in stride(from: n - 1, through: 1, by: -1) {
      try swap(0, end)
      try sift(0, end)
    }
  }
}
