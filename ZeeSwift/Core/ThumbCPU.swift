import Foundation

extension ARMCPU {
  func stepThumb() throws {
    let op = try memory.read16(pc)
    let next = pc &+ 2
    let d = Int(op & 7)
    let s = Int((op >> 3) & 7)
    let t = Int((op >> 6) & 7)
    var jumped = false
    if op & 0xf800 == 0x1800 {
      let b = op & 0x0400 != 0 ? UInt32(t) : r[t]
      r[d] =
        op & 0x0200 != 0
        ? arithmetic(r[s], ~b, 1, flags: true) : arithmetic(r[s], b, 0, flags: true)
    } else if op & 0xe000 == 0 {
      let result = shift(r[s], type: (op >> 11) & 3, amount: Int((op >> 6) & 31), immediate: true)
      r[d] = result.0
      nz(result.0)
      carry(result.1)
    } else if op & 0xe000 == 0x2000 {
      let rd = Int((op >> 8) & 7)
      let imm = op & 255
      switch (op >> 11) & 3 {
      case 0:
        r[rd] = imm
        nz(imm)
      case 1: _ = arithmetic(r[rd], ~imm, 1, flags: true)
      case 2: r[rd] = arithmetic(r[rd], imm, 0, flags: true)
      default: r[rd] = arithmetic(r[rd], ~imm, 1, flags: true)
      }
    } else if op & 0xfc00 == 0x4000 {
      let code = (op >> 6) & 15
      let a = r[d]
      let b = r[s]
      var out = a
      var write = true
      switch code {
      case 0:
        out = a & b
        nz(out)
      case 1:
        out = a ^ b
        nz(out)
      case 2, 3, 4, 7:
        let kind: UInt32 = code == 7 ? 3 : code - 2
        let q = shift(a, type: kind, amount: Int(b & 255), immediate: false)
        out = q.0
        nz(out)
        carry(q.1)
      case 5: out = arithmetic(a, b, c ? 1 : 0, flags: true)
      case 6: out = arithmetic(a, ~b, c ? 1 : 0, flags: true)
      case 8:
        out = a & b
        nz(out)
        write = false
      case 9: out = arithmetic(0, ~b, 1, flags: true)
      case 10:
        _ = arithmetic(a, ~b, 1, flags: true)
        write = false
      case 11:
        _ = arithmetic(a, b, 0, flags: true)
        write = false
      case 12:
        out = a | b
        nz(out)
      case 13:
        out = a &* b
        nz(out)
      case 14:
        out = a & ~b
        nz(out)
      default:
        out = ~b
        nz(out)
      }
      if write { r[d] = out }
    } else if op & 0xfc00 == 0x4400 {
      let rd = d | Int((op >> 4) & 8)
      let rs = Int((op >> 3) & 15)
      let code = (op >> 8) & 3
      if code == 3 {
        let value = reg(rs)
        if op & 128 != 0 { r[14] = next | 1 }
        branch(value)
        jumped = true
      } else if code == 1 {
        _ = arithmetic(reg(rd), ~reg(rs), 1, flags: true)
      } else {
        let out = code == 0 ? reg(rd) &+ reg(rs) : reg(rs)
        if rd == 15 {
          branch(out, exchange: false)
          jumped = true
        } else {
          r[rd] = out
        }
      }
    } else if op & 0xf800 == 0x4800 {
      r[Int((op >> 8) & 7)] = try memory.read32((pc &+ 4) & ~3 &+ ((op & 255) << 2))
    } else if op & 0xf000 == 0x5000 {
      let a = r[s] &+ r[Int((op >> 6) & 7)]
      switch (op >> 9) & 7 {
      case 0: try memory.write32(a, r[d])
      case 1: try memory.write16(a, r[d])
      case 2: try memory.write8(a, r[d])
      case 3: r[d] = UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: try memory.read8(a))))
      case 4: r[d] = try memory.read32(a)
      case 5: r[d] = try memory.read16(a)
      case 6: r[d] = try memory.read8(a)
      default: r[d] = UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: try memory.read16(a))))
      }
    } else if op & 0xe000 == 0x6000 {
      let byte = op & 0x1000 != 0
      let a = r[s] &+ (((op >> 6) & 31) << (byte ? 0 : 2))
      if op & 0x0800 != 0 {
        r[d] = try byte ? memory.read8(a) : memory.read32(a)
      } else if byte {
        try memory.write8(a, r[d])
      } else {
        try memory.write32(a, r[d])
      }
    } else if op & 0xf000 == 0x8000 {
      let a = r[s] &+ (((op >> 6) & 31) << 1)
      if op & 0x0800 != 0 { r[d] = try memory.read16(a) } else { try memory.write16(a, r[d]) }
    } else if op & 0xf000 == 0x9000 {
      let rd = Int((op >> 8) & 7)
      let a = r[13] &+ ((op & 255) << 2)
      if op & 0x0800 != 0 { r[rd] = try memory.read32(a) } else { try memory.write32(a, r[rd]) }
    } else if op & 0xf000 == 0xa000 {
      r[Int((op >> 8) & 7)] = (op & 0x0800 != 0 ? r[13] : (pc &+ 4) & ~3) &+ ((op & 255) << 2)
    } else if op & 0xff00 == 0xb000 {
      r[13] = op & 128 != 0 ? r[13] &- ((op & 127) << 2) : r[13] &+ ((op & 127) << 2)
    } else if op & 0xf600 == 0xb400 {
      var regs = (0..<8).filter { op & (1 << $0) != 0 }
      let pop = op & 0x0800 != 0
      if op & 0x100 != 0 { regs.append(pop ? 15 : 14) }
      guard !regs.isEmpty else { throw EmulationError.instruction(pc, op, true) }
      var a = pop ? r[13] : r[13] &- UInt32(regs.count * 4)
      for i in regs {
        if pop {
          let value = try memory.read32(a)
          if i == 15 {
            branch(value)
            jumped = true
          } else {
            r[i] = value
          }
        } else {
          try memory.write32(a, r[i])
        }
        a &+= 4
      }
      r[13] = pop ? a : r[13] &- UInt32(regs.count * 4)
    } else if op & 0xf000 == 0xc000 {
      let rn = Int((op >> 8) & 7)
      let regs = (0..<8).filter { op & (1 << $0) != 0 }
      guard !regs.isEmpty else { throw EmulationError.instruction(pc, op, true) }
      var a = r[rn]
      for i in regs {
        if op & 0x800 != 0 { r[i] = try memory.read32(a) } else { try memory.write32(a, r[i]) }
        a &+= 4
      }
      if op & 0x800 == 0 || !regs.contains(rn) { r[rn] = a }
    } else if op & 0xf000 == 0xd000, (op >> 8) & 15 < 14 {
      if condition((op >> 8) & 15) {
        pc = pc &+ 4 &+ UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: op)) << 1)
        jumped = true
      }
    } else if op & 0xf800 == 0xe000 {
      pc = pc &+ 4 &+ UInt32(bitPattern: Int32(bitPattern: op << 21) >> 20)
      jumped = true
    } else if op & 0xf800 == 0xf000 {
      r[14] = pc &+ 4 &+ UInt32(bitPattern: Int32(bitPattern: op << 21) >> 9)
    } else if op & 0xf800 == 0xf800 || op & 0xf800 == 0xe800 {
      let target = r[14] &+ ((op & 0x7ff) << 1)
      r[14] = next | 1
      branch(op & 0xf800 == 0xf800 ? target | 1 : target & ~3)
      jumped = true
    } else if op & 0xff00 == 0xdf00, let supervisorCall,
      try supervisorCall(self, op & 0xff) {
      // Legacy Thumb semihosting uses SVC #0xab.
    } else {
      throw EmulationError.instruction(pc, op, true)
    }
    if !jumped { pc = next }
  }
}
