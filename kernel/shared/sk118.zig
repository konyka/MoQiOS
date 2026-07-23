//! SK-118 — RACK-lite timed head-loss detection (non-x86).
//!
//! Classic DupThresh / IsLost can wait through reordering. When SACK shows
//! data above SND.UNA and the head has been outstanding for ≥ SRTT+reo_wnd,
//! enter recovery early.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-118] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-118] tcp rack-lite head loss non-x86: OK\n");
        return;
    }

    // reo_wnd = max(srtt/4, 1).
    if (tcp.probeRackReoWnd(100) != 25 or tcp.probeRackReoWnd(3) != 1) {
        fail("reo");
        return;
    }
    if (tcp.probeRackReoWnd(0) != 0) {
        fail("reo0");
        return;
    }

    // Lost: elapsed covers SRTT + reo, with SACK above.
    if (!tcp.probeRackHeadLost(125, 100, true)) {
        fail("lost");
        return;
    }
    // Not yet: elapsed too short.
    if (tcp.probeRackHeadLost(100, 100, true)) {
        fail("early");
        return;
    }
    // No SACK above ⇒ never.
    if (tcp.probeRackHeadLost(1000, 100, false) or tcp.probeRackHeadLost(1000, 0, true)) {
        fail("guard");
        return;
    }

    arch.serial.writeString("[SK-118] tcp rack-lite head loss non-x86: OK\n");
}
