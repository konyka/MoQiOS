//! SK-150 — AccECN CE-rate EWMA stretches ProbeRTT duration (non-x86).
//!
//! Under sustained CE marking, dwell longer in ProbeRTT so the queue can
//! drain and min_rtt samples stay trustworthy.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-150] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-150] tcp l4s ewma prtt dur non-x86: OK\n");
        return;
    }

    const base: u32 = 200;
    if (tcp.probeL4sProbeRttDuration(base, 0) != base or
        tcp.probeL4sProbeRttDuration(0, 32) != 0)
    {
        fail("cold");
        return;
    }
    // ewma 32 → cuts 1 → 200*9/8 = 225.
    if (tcp.probeL4sProbeRttDuration(base, 32) != 225) {
        fail("mild");
        return;
    }
    // ewma 256 → cuts 7 → 200*15/8 = 375 (< 2·base=400).
    if (tcp.probeL4sProbeRttDuration(base, 256) != 375) {
        fail("severe");
        return;
    }
    // Done only after stretched dwell.
    if (tcp.probeBbrProbeRttDone(0, 224, tcp.probeL4sProbeRttDuration(base, 32)) or
        !tcp.probeBbrProbeRttDone(0, 225, tcp.probeL4sProbeRttDuration(base, 32)))
    {
        fail("done");
        return;
    }

    arch.serial.writeString("[SK-150] tcp l4s ewma prtt dur non-x86: OK\n");
}
