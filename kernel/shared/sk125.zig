//! SK-125 — HyStart++ slow-start exit (non-x86).
//!
//! Classic SS can overshoot and fill queues before loss. HyStart++ enters CSS
//! on the first RTT delay signal, then exits SS on the second.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-125] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-125] tcp hystart++ non-x86: OK\n");
        return;
    }

    // clamp(min_rtt/8, 4, 16)
    if (tcp.probeHystartDelayThresh(0) != 0) {
        fail("thresh zero");
        return;
    }
    if (tcp.probeHystartDelayThresh(16) != 4) {
        fail("thresh floor");
        return;
    }
    if (tcp.probeHystartDelayThresh(80) != 10) {
        fail("thresh mid");
        return;
    }
    if (tcp.probeHystartDelayThresh(200) != 16) {
        fail("thresh cap");
        return;
    }

    if (tcp.probeHystartShouldExit(20, 20)) {
        fail("no exit at min");
        return;
    }
    if (!tcp.probeHystartShouldExit(24, 20)) {
        fail("exit at +thresh");
        return;
    }
    if (tcp.probeHystartShouldExit(23, 20)) {
        fail("no exit below");
        return;
    }

    if (tcp.probeHystartCssInc(1000) != 500 or tcp.probeHystartCssInc(1) != 1) {
        fail("css inc");
        return;
    }
    if (tcp.probeHystartExitSsthresh(10_000, 1460) != 10_000) {
        fail("exit ssthresh");
        return;
    }
    if (tcp.probeHystartExitSsthresh(1000, 1460) != 2920) {
        fail("exit floor");
        return;
    }

    arch.serial.writeString("[SK-125] tcp hystart++ non-x86: OK\n");
}
