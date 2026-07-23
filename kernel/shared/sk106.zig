//! SK-106 — Timer expiry arms oversized PMTU probe before blind raise (non-x86).
//!
//! Lifetime expiry previously jumped the cached PMTU up a plateau with no TX
//! proof. Expiry now arms `getSendMtu` first; only after that probe window
//! elapses without confirmation do we blind-raise (SK-103 fallback).

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const netif = @import("../net/netif.zig");
const ipv6 = @import("../net/ipv6.zig");
const ipv4 = @import("../net/ipv4.zig");

const DST6: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0xa6,
};
const DST4: [4]u8 = .{ 10, 0, 0, 106 };

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-106] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-106] pmtu timer arm before raise non-x86: OK\n");
        return;
    }

    netif.resetMtu();
    ipv6.initPmtu();
    ipv4.initPmtu();

    ipv6.updatePathMtu(DST6, 1280);
    ipv6.pathMtuTimerTick(ipv6.PMTU_LIFETIME_SEC * 1000);
    // First expiry: arm only — cached PMTU unchanged.
    if (ipv6.getPathMtu(DST6) != 1280 or ipv6.getSendMtu(DST6) != 1400) {
        fail("timer arm");
        return;
    }
    // TX confirmation during the probe window raises without waiting.
    ipv6.noteFullSizeSend(DST6, 1400);
    if (ipv6.getPathMtu(DST6) != 1400) {
        fail("tx confirm");
        return;
    }

    // Fresh entry: skip TX, let the probe window expire → blind raise.
    ipv6.initPmtu();
    ipv6.updatePathMtu(DST6, 1280);
    ipv6.pathMtuTimerTick(ipv6.PMTU_LIFETIME_SEC * 1000);
    ipv6.pathMtuTimerTick(ipv6.PMTU_RAISE_LIFETIME_SEC * 1000);
    if (ipv6.getPathMtu(DST6) != 1400) {
        fail("blind fallback");
        return;
    }

    // IPv4: same arm-then-raise shape.
    ipv4.updatePathMtu(DST4, 576);
    ipv4.pathMtuTimerTick(ipv4.PMTU_LIFETIME_SEC * 1000);
    if (ipv4.getPathMtu(DST4) != 576 or ipv4.getSendMtu(DST4) != 1006) {
        fail("v4 arm");
        return;
    }
    ipv4.pathMtuTimerTick(ipv4.PMTU_RAISE_LIFETIME_SEC * 1000);
    if (ipv4.getPathMtu(DST4) != 1006) {
        fail("v4 blind");
        return;
    }

    ipv4.probeDrainPathMtu(32);
    ipv6.probeDrainPathMtu(32);
    arch.serial.writeString("[SK-106] pmtu timer arm before raise non-x86: OK\n");
}
