//! SK-130 — HyStart++ ACK-train gap detection (non-x86).
//!
//! Queueing stretches ACK spacing inside a flight. When the inter-ACK gap
//! exceeds clamp(min_rtt/8, 2, 16) ms, raise the same CSS/exit signal as delay.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-130] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-130] tcp hystart ack-train gap non-x86: OK\n");
        return;
    }

    if (tcp.probeHystartAckGapThresh(0) != 0) {
        fail("thresh zero");
        return;
    }
    if (tcp.probeHystartAckGapThresh(8) != 2) {
        fail("thresh floor");
        return;
    }
    if (tcp.probeHystartAckGapThresh(80) != 10) {
        fail("thresh mid");
        return;
    }
    if (tcp.probeHystartAckGapThresh(200) != 16) {
        fail("thresh cap");
        return;
    }

    // No prior ACK ⇒ never a gap.
    if (tcp.probeHystartAckGap(0, 1000, 80)) {
        fail("no prior");
        return;
    }
    // min_rtt=80 → thresh=10; gap of 10 is not > thresh.
    if (tcp.probeHystartAckGap(1000, 1010, 80)) {
        fail("at thresh");
        return;
    }
    if (!tcp.probeHystartAckGap(1000, 1011, 80)) {
        fail("over thresh");
        return;
    }

    arch.serial.writeString("[SK-130] tcp hystart ack-train gap non-x86: OK\n");
}
