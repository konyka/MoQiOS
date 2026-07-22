//! SK-80 — NDP reachable→stale aging (NUD) on non-x86.
//!
//! SK-79 retransmits incomplete NS. Confirmed neighbors stayed `reachable`
//! forever. This probe locks REACHABLE_TIME aging to `stale` while lookup
//! still returns the MAC (RFC 4861: stale is usable).

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const ndp = @import("../net/ndp.zig");

const IP: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x80,
};
const MAC = [6]u8{ 0x02, 0, 0, 0x80, 0x00, 0x01 };

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-80] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-80] ndp reachable stale aging non-x86: OK\n");
        return;
    }

    ndp.init();
    ndp.update(IP, MAC);
    if (ndp.probeState(IP) != .reachable) {
        fail("reachable");
        return;
    }

    var batch: [1][16]u8 = undefined;
    // Sub-threshold: still reachable, no solicits.
    if (ndp.timerTick(ndp.REACHABLE_TIME_MS - 1, &batch) != 0) {
        fail("unexpected solicit");
        return;
    }
    if (ndp.probeState(IP) != .reachable) {
        fail("aged early");
        return;
    }

    // Cross REACHABLE_TIME → stale; MAC still usable.
    _ = ndp.timerTick(1, &batch);
    if (ndp.probeState(IP) != .stale) {
        fail("not stale");
        return;
    }
    const m = ndp.lookup(IP) orelse {
        fail("stale lookup");
        return;
    };
    if (m[0] != MAC[0] or m[5] != MAC[5]) {
        fail("stale mac");
        return;
    }

    // NA/refresh returns to reachable and resets the age clock.
    ndp.update(IP, MAC);
    if (ndp.probeState(IP) != .reachable) {
        fail("refresh");
        return;
    }
    _ = ndp.timerTick(ndp.REACHABLE_TIME_MS - 1, &batch);
    if (ndp.probeState(IP) != .reachable) {
        fail("age not reset");
        return;
    }

    arch.serial.writeString("[SK-80] ndp reachable stale aging non-x86: OK\n");
}
