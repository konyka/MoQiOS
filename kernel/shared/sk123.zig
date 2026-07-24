//! SK-123 — BBR ProbeBW 8-phase pacing-gain cycle (non-x86).
//!
//! Fixed 1.25× cruise could not drain queues. Cycle gains
//! [5/4, 3/4, 1, 1, 1, 1, 1, 1] each min_rtt to probe and drain.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-123] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-123] tcp bbr cycle gains non-x86: OK\n");
        return;
    }

    if (tcp.probeBbrCycleGainNum(0) != 5 or tcp.probeBbrCycleGainNum(1) != 3 or
        tcp.probeBbrCycleGainNum(2) != 4 or tcp.probeBbrCycleGainNum(7) != 4)
    {
        fail("gain");
        return;
    }

    // BDP 40000 → 5/4=50000, 3/4=30000, 1=40000.
    if (tcp.probeBbrCycleCwnd(40_000, 5) != 50_000 or
        tcp.probeBbrCycleCwnd(40_000, 3) != 30_000 or
        tcp.probeBbrCycleCwnd(40_000, 4) != 40_000)
    {
        fail("cwnd");
        return;
    }

    if (!tcp.probeBbrCycleAdvance(50, 50) or tcp.probeBbrCycleAdvance(49, 50) or
        tcp.probeBbrCycleAdvance(100, 0))
    {
        fail("advance");
        return;
    }

    arch.serial.writeString("[SK-123] tcp bbr cycle gains non-x86: OK\n");
}
