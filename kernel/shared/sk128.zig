//! SK-128 — RACK retransmission timer (non-x86).
//!
//! SK-127 only repairs on ACK/SACK. When ACKs go quiet, scan on the retransmit
//! timer and repair RACK-lost holes before RTO, paced to once per RTT.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-128] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-128] tcp rack retransmit timer non-x86: OK\n");
        return;
    }

    if (tcp.probeRackTimerShouldFire(false, 50, 200, 0) or
        tcp.probeRackTimerShouldFire(true, 50, 200, 1) or
        tcp.probeRackTimerShouldFire(true, 200, 200, 0) or
        tcp.probeRackTimerShouldFire(true, 50, 0, 0))
    {
        fail("should not fire");
        return;
    }
    if (!tcp.probeRackTimerShouldFire(true, 50, 200, 0)) {
        fail("should fire");
        return;
    }

    if (!tcp.probeRackTimerReady(0, 1000, 100)) {
        fail("first ready");
        return;
    }
    if (tcp.probeRackTimerReady(1000, 1099, 100)) {
        fail("pace hold");
        return;
    }
    if (!tcp.probeRackTimerReady(1000, 1100, 100)) {
        fail("pace ok");
        return;
    }

    arch.serial.writeString("[SK-128] tcp rack retransmit timer non-x86: OK\n");
}
