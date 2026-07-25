//! SK-149 — AccECN CE-rate EWMA shortens ProbeRTT interval (non-x86).
//!
//! Under sustained CE marking, ProbeRTT fires more often so min_rtt / BDP
//! stay fresh without waiting for the fixed 10s classic cadence.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-149] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-149] tcp l4s ewma probertt non-x86: OK\n");
        return;
    }

    const base: u32 = 10_000;
    if (tcp.probeL4sProbeRttInterval(base, 0) != base or
        tcp.probeL4sProbeRttInterval(0, 32) != 0)
    {
        fail("cold");
        return;
    }
    // ewma 32 → keep 7/8 → 8750.
    if (tcp.probeL4sProbeRttInterval(base, 32) != 8750) {
        fail("mild");
        return;
    }
    // ewma 256 → keep 1/8 → 1250, floor max(2000,1000)=2000.
    if (tcp.probeL4sProbeRttInterval(base, 256) != 2000) {
        fail("severe floor");
        return;
    }
    // Due sooner under shortened interval.
    if (!tcp.probeBbrProbeRttDue(0, 1, tcp.probeL4sProbeRttInterval(base, 256)) or
        tcp.probeBbrProbeRttDue(0, 1, 0))
    {
        fail("due");
        return;
    }

    arch.serial.writeString("[SK-149] tcp l4s ewma probertt non-x86: OK\n");
}
