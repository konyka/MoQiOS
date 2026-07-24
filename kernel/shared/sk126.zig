//! SK-126 — RACK per-segment TX timestamps (non-x86).
//!
//! SK-118 only timed SND.UNA. Track recent segment send times and mark the
//! head lost when a same-or-later transmission is delivered and RTT+reo elapses.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-126] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-126] tcp rack per-segment non-x86: OK\n");
        return;
    }

    // Unknown xmit / RTT ⇒ never lost.
    if (tcp.probeRackSegLost(0, 10, 100, 125) or tcp.probeRackSegLost(1000, 0, 0, 1125)) {
        fail("guards");
        return;
    }
    // Head at t=1000; later TX delivered; lost once elapsed ≥ RTT+reo (100+25).
    if (tcp.probeRackSegLost(1000, 1010, 100, 1124)) {
        fail("early");
        return;
    }
    if (!tcp.probeRackSegLost(1000, 1010, 100, 1125)) {
        fail("lost");
        return;
    }
    // Delivered reference sent *before* this segment ⇒ no inference.
    if (tcp.probeRackSegLost(1000, 900, 100, 2000)) {
        fail("ref before");
        return;
    }
    // No ref yet: still allow timing against RTT alone.
    if (!tcp.probeRackSegLost(1000, 0, 100, 1125)) {
        fail("no ref");
        return;
    }

    arch.serial.writeString("[SK-126] tcp rack per-segment non-x86: OK\n");
}
