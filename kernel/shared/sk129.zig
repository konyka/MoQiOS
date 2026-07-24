//! SK-129 — HyStart++ ACK-train round boundaries (non-x86).
//!
//! Per-ACK RTT noise can flip CSS early. Decide only when a flight round ends
//! (cumulative ACK covers round_end), using that round's min RTT.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-129] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-129] tcp hystart ack-train rounds non-x86: OK\n");
        return;
    }

    if (tcp.probeHystartRoundDone(100, 0) or tcp.probeHystartRoundDone(99, 100)) {
        fail("round open");
        return;
    }
    if (!tcp.probeHystartRoundDone(100, 100) or !tcp.probeHystartRoundDone(101, 100)) {
        fail("round done");
        return;
    }

    if (tcp.probeHystartRoundMin(0, 0) != 0) {
        fail("min zero");
        return;
    }
    if (tcp.probeHystartRoundMin(0, 40) != 40) {
        fail("min first");
        return;
    }
    if (tcp.probeHystartRoundMin(40, 30) != 30) {
        fail("min lower");
        return;
    }
    if (tcp.probeHystartRoundMin(30, 50) != 30) {
        fail("min keep");
        return;
    }

    arch.serial.writeString("[SK-129] tcp hystart ack-train rounds non-x86: OK\n");
}
