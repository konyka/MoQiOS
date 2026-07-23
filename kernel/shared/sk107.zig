//! SK-107 — Auto-arm PMTU raise probe after PTB cooldown (non-x86).
//!
//! After Packet Too Big / Frag Needed, raise probing waited for the full
//! Path MTU lifetime. A short cooldown now auto-arms `getSendMtu` so recovery
//! can start in tens of seconds without a blind raise.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const netif = @import("../net/netif.zig");
const ipv6 = @import("../net/ipv6.zig");
const ipv4 = @import("../net/ipv4.zig");

const DST6: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0xa7,
};
const DST4: [4]u8 = .{ 10, 0, 0, 107 };

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-107] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-107] pmtu rearm after cooldown non-x86: OK\n");
        return;
    }

    netif.resetMtu();
    ipv6.initPmtu();
    ipv4.initPmtu();

    ipv6.updatePathMtu(DST6, 1280);
    if (ipv6.getSendMtu(DST6) != 1280) {
        fail("no early arm");
        return;
    }

    // One second before cooldown ends: still capped.
    ipv6.pathMtuTimerTick((ipv6.PMTU_PROBE_COOLDOWN_SEC - 1) * 1000);
    if (ipv6.getPathMtu(DST6) != 1280 or ipv6.getSendMtu(DST6) != 1280) {
        fail("before cooldown");
        return;
    }

    // Cooldown completes → auto-arm next plateau.
    ipv6.pathMtuTimerTick(1000);
    if (ipv6.getPathMtu(DST6) != 1280 or ipv6.getSendMtu(DST6) != 1400) {
        fail("auto arm");
        return;
    }

    // PTB resets cooldown and disarms.
    ipv6.updatePathMtu(DST6, 1280);
    if (ipv6.getSendMtu(DST6) != 1280) {
        fail("ptb disarm");
        return;
    }

    // IPv4: same cooldown shape.
    ipv4.updatePathMtu(DST4, 576);
    ipv4.pathMtuTimerTick((ipv4.PMTU_PROBE_COOLDOWN_SEC - 1) * 1000);
    if (ipv4.getSendMtu(DST4) != 576) {
        fail("v4 before");
        return;
    }
    ipv4.pathMtuTimerTick(1000);
    if (ipv4.getPathMtu(DST4) != 576 or ipv4.getSendMtu(DST4) != 1006) {
        fail("v4 auto arm");
        return;
    }

    ipv4.probeDrainPathMtu(32);
    ipv6.probeDrainPathMtu(32);
    arch.serial.writeString("[SK-107] pmtu rearm after cooldown non-x86: OK\n");
}
