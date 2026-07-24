//! SK-127 — RACK-timed repair of non-head holes (non-x86).
//!
//! SK-126 marks the head lost from per-segment times. Also enter recovery and
//! retransmit when a later hole is RACK-lost while an earlier hole is not yet.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-127] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-127] tcp rack hole rexmit non-x86: OK\n");
        return;
    }

    // No SACK above ⇒ never.
    if (tcp.probeRackHoleLost(1000, 1010, 100, 1125, false)) {
        fail("no sack");
        return;
    }
    if (!tcp.probeRackHoleLost(1000, 1010, 100, 1125, true)) {
        fail("lost");
        return;
    }
    if (tcp.probeRackHoleLost(1000, 1010, 100, 1124, true)) {
        fail("early");
        return;
    }

    // Prefer later RACK-lost hole over earlier not-lost hole.
    if (tcp.probeRackRexmitSeq(100, false, 5000, true) != 5000) {
        fail("prefer lost");
        return;
    }
    if (tcp.probeRackRexmitSeq(100, true, 5000, true) != 100) {
        fail("keep first lost");
        return;
    }
    if (tcp.probeRackRexmitSeq(100, false, 5000, false) != 100) {
        fail("keep first");
        return;
    }

    arch.serial.writeString("[SK-127] tcp rack hole rexmit non-x86: OK\n");
}
