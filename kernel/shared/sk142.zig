//! SK-142 — AccECN reserved ACE 0b010 (non-x86).
//!
//! Do not encode or accept ACE=0b010 as congestion feedback; CE increments
//! skip from 1 → 3, and invalid peer ACE leaves ace_peer unchanged.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-142] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-142] tcp ace invalid 0b010 non-x86: OK\n");
        return;
    }

    if (!tcp.probeAceInvalid(0b010) or tcp.probeAceInvalid(0) or tcp.probeAceInvalid(3) or
        tcp.probeAceInvalid(7))
    {
        fail("invalid");
        return;
    }
    // 0→1, 1→3 (skip 2), 3→4, 7→0.
    if (tcp.probeAceNextCount(0) != 1 or tcp.probeAceNextCount(1) != 3 or
        tcp.probeAceNextCount(3) != 4 or tcp.probeAceNextCount(7) != 0)
    {
        fail("next count");
        return;
    }
    // Packing 0b010 is CWR-only flags (no AE/ECE).
    if (tcp.probeAcePackAe(0b010) != 0 or tcp.probeAcePackFlags(0b010, 0x10) != (0x10 | 0x80)) {
        fail("pack 0b010");
        return;
    }

    arch.serial.writeString("[SK-142] tcp ace invalid 0b010 non-x86: OK\n");
}
