//! SK-121 — BBR-lite Startup / Drain (non-x86).
//!
//! Classic slow start can undershoot high-BDP paths. While Startup is active,
//! grow cwnd toward 2·BDP from the delivery-rate sample, then Drain to 1·BDP.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-121] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-121] tcp bbr-lite startup non-x86: OK\n");
        return;
    }

    // 1MB/s · 50ms → BDP 50000 → Startup target 100000.
    if (tcp.probeBbrStartupCwnd(1_000_000, 50) != 100_000) {
        fail("target");
        return;
    }
    if (tcp.probeBbrStartupCwnd(0, 50) != 0 or tcp.probeBbrStartupCwnd(1000, 0) != 0) {
        fail("target0");
        return;
    }

    if (!tcp.probeBbrStartupDone(100_000, 100_000) or
        !tcp.probeBbrStartupDone(100_001, 100_000) or
        tcp.probeBbrStartupDone(99_999, 100_000) or
        tcp.probeBbrStartupDone(1, 0))
    {
        fail("done");
        return;
    }

    arch.serial.writeString("[SK-121] tcp bbr-lite startup non-x86: OK\n");
}
