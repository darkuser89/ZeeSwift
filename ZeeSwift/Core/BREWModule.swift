import Foundation

struct BREWLoadedModule {
  let base: UInt32
  let object: UInt32
  let result: UInt32
}

extension BREWRuntime {
  // A guest module may call IShell recursively during its initialization. Give
  // nested calls a separate stack frame and retain the caller's complete state.
  // Instruction counts and memory changes intentionally remain visible.
  func callBundledModule(_ address: UInt32, arguments: [UInt32]) throws -> UInt32 {
    let registers = (0..<16).map { cpu.r[$0] }, flags = cpu.cpsr
    defer {
      for i in 0..<16 { cpu.r[i] = registers[i] }
      cpu.cpsr = flags
    }
    guard cpu.r[13] >= 256 else { throw EmulationError.invalid("Module stack") }
    cpu.r[13] = (cpu.r[13] - 256) & ~UInt32(7)
    _ = try memory.region(cpu.r[13], 256)
    return try invoke(address, arguments, budget: 10_000_000)
  }

  func loadBundledModule(_ image: GamePackage.BundledModule) throws -> BREWLoadedModule {
    if let loaded = bundledModules[image.path] { return loaded }
    guard loadingModules.insert(image.path).inserted else {
      throw EmulationError.unsupported("Cyclic BREW module initialization: " + image.path)
    }
    defer { loadingModules.remove(image.path) }
    guard image.bytes.count >= 64 else { throw EmulationError.invalid("BREW library too short") }
    let first = try image.bytes.u32(0)
    let target = Int64(8) + Int64(Int32(bitPattern: first << 8) >> 6)
    guard try image.bytes.checked(8, 4) == Data("BREW".utf8)
      || first == 0xe52d_e004 || first & 0xffff_0000 == 0xe92d_0000
      || (first >> 24 == 0xea && target >= 0 && target + 4 <= image.bytes.count)
    else { throw EmulationError.unsupported("BREW library format: " + image.path) }
    let codeSize = try AddressSpace(moduleSize: image.bytes.count).codeSize
    let extent = UInt64(codeSize) + 0x1000
    // Heap ends at 0x05000000; the framebuffer begins at 0x06000000.
    guard UInt64(nextModuleRegion) + extent <= UInt64(framebuffer) else {
      throw EmulationError.unsupported("BREW library region exhausted")
    }
    let base = nextModuleRegion + 0x1000
    try memory.map(nextModuleRegion, size: Int(extent), executable: true)
    nextModuleRegion += UInt32(extent)
    try memory.write(base, data: image.bytes)
    try memory.write32(base - 4, hleAddress(0))
    try memory.write32(base - 8, shell)
    let scratch = try allocate(16)
    guard scratch != 0 else { throw EmulationError.invalid("BREW module output: out of memory") }
    defer { try? free(scratch) }
    let result = try callBundledModule(base, arguments: [shell, 0, scratch])
    let object = try memory.read32(scratch)
    let loaded = BREWLoadedModule(base: base, object: object, result: result == 0 && object == 0 ? 3 : result)
    // Retain the module's initial reference for this runtime, including failed
    // initialization results, so repeated class requests never reload its code.
    bundledModules[image.path] = loaded
    log.append("BREW library " + image.path + " @ " + base.hex + " → " + loaded.result.hex)
    return loaded
  }

  func instantiateBundledClass(_ classID: UInt32, output: UInt32) throws -> UInt32? {
    guard let path = package.classModulePaths[classID] else { return nil }
    guard output != 0 else { return 14 }
    _ = try memory.region(output, 4)
    try memory.write32(output, 0)
    let object: UInt32
    if path == package.modulePath {
      object = module
      guard object != 0 else { return 3 }
    } else if let loaded = bundledModules[path] {
      guard loaded.result == 0 else { return loaded.result }
      object = loaded.object
    } else {
      guard let entry = package.archive.entries.first(where: { $0.name == path }) else { return 3 }
      let loaded = try loadBundledModule(.init(path: path, bytes: package.archive.read(entry)))
      guard loaded.result == 0 else { return loaded.result }
      object = loaded.object
    }
    let table = try memory.read32(object)
    let create = try memory.read32(table + 8)
    let result = try callBundledModule(create, arguments: [object, shell, classID, output])
    if result != 0 { try memory.write32(output, 0) }
    log.append("BREW library class " + classID.hex + " → " + result.hex)
    return result
  }
}
