import Foundation

extension BREWRuntime {
  // Imported modules run in a local, non-expiring HLE profile (LT_NONE).
  // This does not assert a BREW-store purchase or synthesize a purchase receipt.
  func createLicense() throws -> UInt32 {
    let handle = try allocate(4)
    guard handle != 0 else { return 0 }
    let table = hleAddress(0x20700)
    for offset in stride(from: UInt32(0), through: 0x14, by: 4) {
      try memory.write32(table + offset, 0xf01c_0000 + offset)
    }
    try memory.write32(handle, table)
    licenseReferences[handle] = 1
    return handle
  }

  func dispatchLicense(_ offset: UInt32) throws {
    let handle = cpu.r[0]
    guard let references = licenseReferences[handle] else {
      throw EmulationError.invalid("ILicense object " + handle.hex)
    }
    switch offset {
    case 0:
      licenseReferences[handle] = references + 1
      cpu.r[0] = references + 1
    case 4:
      if references == 1 {
        licenseReferences.removeValue(forKey: handle)
        try free(handle)
      } else { licenseReferences[handle] = references - 1 }
      cpu.r[0] = references - 1
    case 8:
      cpu.r[0] = 0  // IsExpired: FALSE for LT_NONE.
    case 0x0c:
      if cpu.r[1] != 0 { try memory.write32(cpu.r[1], 0) }
      cpu.r[0] = 0  // GetInfo: LT_NONE; no associated expiration value.
    case 0x10:
      cpu.r[0] = 1  // SetUsesRemaining: EFAILED unless the module uses LT_USES.
    case 0x14:
      let type = cpu.r[1], expiration = cpu.r[2], sequence = cpu.r[3]
      // AEELicenseType is int8 on the ARM target, unlike the Windows build.
      if type != 0 { _ = try memory.region(type, 1) }
      if expiration != 0 { _ = try memory.region(expiration, 4) }
      if sequence != 0 { _ = try memory.region(sequence, 4) }
      if type != 0 { try memory.write8(type, 0) }
      if expiration != 0 { try memory.write32(expiration, 0) }
      if sequence != 0 { try memory.write32(sequence, 0) }
      cpu.r[0] = 0  // PT_NONE: purchase information is unavailable for local imports.
    default: throw EmulationError.hle("ILicense+" + offset.hex, cpu.r[14])
    }
  }
}
