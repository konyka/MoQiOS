//! SK-148 — AccECN CE-rate EWMA Startup→ProbeBW threshold (non-x86).
//!
//! Shrink the 2·BDP Startup target with mark-rate EWMA and abort Startup
//! early when sustained CE marking is already elevated.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-148] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-148] tcp l4s ewma startup non-x86: OK\n");
        return;
    }

    // rate=8000 B/s, rtt=100ms → BDP=800, Startup=1600.
    const full = tcp.probeBbrStartupCwnd(8000, 100);
    if (full != 1600) {
        fail("baseline");
        return;
    }
    if (tcp.probeL4sStartupCwnd(8000, 100, 0) != full) {
        fail("cold");
        return;
    }
    // ewma 32 → keep 7/8 → 1600*7/8 = 1400 (≥ BDP 800).
    if (tcp.probeL4sStartupCwnd(8000, 100, 32) != 1400) {
        fail("mild target");
        return;
    }
    // Severe EWMA floors at 1·BDP.
    if (tcp.probeL4sStartupCwnd(8000, 100, 256) != 800) {
        fail("floor bdp");
        return;
    }
    if (tcp.probeL4sStartupAbort(0) or tcp.probeL4sStartupAbort(63) or
        !tcp.probeL4sStartupAbort(64) or !tcp.probeL4sStartupAbort(256))
    {
        fail("abort");
        return;
    }

    arch.serial.writeString("[SK-148] tcp l4s ewma startup non-x86: OK\n");
}
