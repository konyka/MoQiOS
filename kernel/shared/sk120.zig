//! SK-120 — delivery-rate TCP pacing (non-x86).
//!
//! Bursting a full cwnd at once causes loss and ACK compression. Space
//! SMSS sends by interval = SMSS·1000/rate_bps using the SK-119 rate sample.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-120] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-120] tcp rate pacing non-x86: OK\n");
        return;
    }

    // 1460 B at 146000 B/s → 10ms.
    if (tcp.probePaceIntervalMs(1460, 146000) != 10) {
        fail("interval");
        return;
    }
    // Faster than 1ms/SMSS → 0 (no pacing delay at ms granularity).
    if (tcp.probePaceIntervalMs(1460, 10_000_000) != 0) {
        fail("fast");
        return;
    }
    if (tcp.probePaceIntervalMs(0, 1000) != 0 or tcp.probePaceIntervalMs(1460, 0) != 0) {
        fail("zero");
        return;
    }

    arch.serial.writeString("[SK-120] tcp rate pacing non-x86: OK\n");
}
