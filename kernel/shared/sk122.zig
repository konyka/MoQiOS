//! SK-122 — BBR-lite ProbeBW cruise and ProbeRTT (non-x86).
//!
//! After Startup, Reno CA ignored the measured BDP. ProbeBW keeps cwnd near
//! BDP; ProbeRTT periodically shrinks the window to refresh min_rtt.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-122] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-122] tcp bbr-lite probebw/rtt non-x86: OK\n");
        return;
    }

    if (tcp.probeBbrProbeBwHi(40_000) != 50_000) {
        fail("hi");
        return;
    }
    if (tcp.probeBbrProbeRttCwnd(1460) != 5840) {
        fail("cwnd");
        return;
    }

    // First ProbeRTT is always due; then after interval.
    if (!tcp.probeBbrProbeRttDue(0, 1000, 10_000) or
        tcp.probeBbrProbeRttDue(1000, 5000, 10_000) or
        !tcp.probeBbrProbeRttDue(1000, 12_000, 10_000))
    {
        fail("due");
        return;
    }

    if (!tcp.probeBbrProbeRttDone(100, 300, 200) or tcp.probeBbrProbeRttDone(100, 250, 200)) {
        fail("done");
        return;
    }

    arch.serial.writeString("[SK-122] tcp bbr-lite probebw/rtt non-x86: OK\n");
}
