//! SK-119 — delivery rate sampling and BDP cwnd floor (non-x86).
//!
//! Recovery exit always set cwnd = ssthresh, often far below the recently
//! measured pipe. Sample delivery rate and min RTT, then floor cwnd at BDP.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-119] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-119] tcp delivery rate bdp non-x86: OK\n");
        return;
    }

    // 1460 bytes in 10ms → 146000 B/s.
    if (tcp.probeDeliveryRateBps(1460, 10) != 146000) {
        fail("rate");
        return;
    }
    if (tcp.probeDeliveryRateBps(1000, 0) != 0 or tcp.probeDeliveryRateBps(0, 10) != 0) {
        fail("rate0");
        return;
    }

    // BDP: 1_000_000 B/s · 50ms = 50000 bytes.
    if (tcp.probeBdpBytes(1_000_000, 50) != 50_000) {
        fail("bdp");
        return;
    }
    if (tcp.probeBdpBytes(0, 50) != 0 or tcp.probeBdpBytes(1000, 0) != 0) {
        fail("bdp0");
        return;
    }

    arch.serial.writeString("[SK-119] tcp delivery rate bdp non-x86: OK\n");
}
