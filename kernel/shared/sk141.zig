//! SK-141 — AccECN ACE baseline sync after handshake (non-x86).
//!
//! The first ACE seen once AccECN is negotiated establishes ace_peer without
//! treating the undefined→value transition as congestion.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-141] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-141] tcp ace baseline sync non-x86: OK\n");
        return;
    }

    if (!tcp.probeAceBaselineOnly(false) or tcp.probeAceBaselineOnly(true)) {
        fail("baseline");
        return;
    }
    // After sync, a jump from baseline 5 to 6 is one CE (not five from 0).
    if (tcp.probeAceDelta(5, 6) != 1 or tcp.probeAceDelta(0, 5) != 5) {
        fail("delta after sync");
        return;
    }
    // Unpacking AccECN SYN-ACK (AE+ECE) yields ACE=5 — must not cut if unsynced.
    if (tcp.probeAceUnpack(0x51, 0x52) != 5) {
        fail("synack ace");
        return;
    }

    arch.serial.writeString("[SK-141] tcp ace baseline sync non-x86: OK\n");
}
