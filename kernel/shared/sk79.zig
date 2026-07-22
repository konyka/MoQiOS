//! SK-79 — NDP incomplete Neighbor Solicitation retransmit on non-x86.
//!
//! SK-72 sends one NS on cache miss. Without a RetransTimer, a lost NS leaves
//! the neighbor stuck incomplete forever. This probe locks: markIncomplete →
//! wait RetransTimer → re-solicit up to MAX_MULTICAST_SOLICIT → drop.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const ndp = @import("../net/ndp.zig");
const ipv6 = @import("../net/ipv6.zig");

const TARGET: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x79,
};
const MAC = [6]u8{ 0x02, 0, 0, 0x79, 0x00, 0x01 };

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-79] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-79] ndp ns retransmit non-x86: OK\n");
        return;
    }

    ndp.init();
    ndp.markIncomplete(TARGET);
    if (!ndp.probeIsIncomplete(TARGET) or ndp.probeSolicitCount(TARGET) != 1) {
        fail("mark incomplete");
        return;
    }

    // Sub-threshold tick: no retransmit.
    var batch: [4][16]u8 = undefined;
    if (ndp.timerTick(ndp.RETRANS_MS - 1, &batch) != 0) {
        fail("early retransmit");
        return;
    }
    if (ndp.probeSolicitCount(TARGET) != 1) {
        fail("count early");
        return;
    }

    // Crossing RetransTimer → 2nd NS requested.
    if (ndp.timerTick(1, &batch) != 1 or !ipv6.addrEq(batch[0], TARGET)) {
        fail("retransmit 2");
        return;
    }
    if (ndp.probeSolicitCount(TARGET) != 2) {
        fail("count 2");
        return;
    }

    // Remount incomplete must not reset in-flight counters.
    ndp.markIncomplete(TARGET);
    if (ndp.probeSolicitCount(TARGET) != 2) {
        fail("reset on remount");
        return;
    }

    // 3rd NS.
    if (ndp.timerTick(ndp.RETRANS_MS, &batch) != 1) {
        fail("retransmit 3");
        return;
    }
    if (ndp.probeSolicitCount(TARGET) != 3) {
        fail("count 3");
        return;
    }

    // Exhausted → entry dropped, no further solicit.
    if (ndp.timerTick(ndp.RETRANS_MS, &batch) != 0) {
        fail("extra solicit");
        return;
    }
    if (ndp.probeIsIncomplete(TARGET) or ndp.probeSolicitCount(TARGET) != 0xFF) {
        fail("not dropped");
        return;
    }

    // Resolved neighbor clears retransmit state.
    ndp.markIncomplete(TARGET);
    ndp.update(TARGET, MAC);
    if (ndp.probeIsIncomplete(TARGET) or ndp.lookup(TARGET) == null) {
        fail("resolve");
        return;
    }
    if (ndp.timerTick(ndp.RETRANS_MS, &batch) != 0) {
        fail("tick after resolve");
        return;
    }

    arch.serial.writeString("[SK-79] ndp ns retransmit non-x86: OK\n");
}
