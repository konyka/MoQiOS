//! SK-103 — Path MTU raise probing after expiry (non-x86).
//!
//! Learned Path MTU only shrank, then snapped back to the link MTU after
//! lifetime. Expiry now walks RFC 1191/4821 plateaus toward the interface
//! MTU before clearing, so throughput can recover gradually if the path grows.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const netif = @import("../net/netif.zig");
const ipv6 = @import("../net/ipv6.zig");
const ipv4 = @import("../net/ipv4.zig");

const DST6: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0xa3,
};
const DST4: [4]u8 = .{ 10, 0, 0, 103 };

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-103] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-103] pmtu raise probe non-x86: OK\n");
        return;
    }

    netif.resetMtu();
    ipv6.initPmtu();
    ipv4.initPmtu();

    // Plateau helper.
    if (ipv6.nextRaiseMtu(1280, 1500) != 1400 or
        ipv6.nextRaiseMtu(1400, 1500) != 1492 or
        ipv6.nextRaiseMtu(1492, 1500) != 1500 or
        ipv6.nextRaiseMtu(1500, 1500) != 1500)
    {
        fail("v6 plateaus");
        return;
    }
    if (ipv4.nextRaiseMtu(576, 1500) != 1006 or
        ipv4.nextRaiseMtu(1006, 1500) != 1280 or
        ipv4.nextRaiseMtu(1280, 1500) != 1400)
    {
        fail("v4 plateaus");
        return;
    }

    // IPv6: learn 1280, first expiry raises to 1400 (not clear).
    ipv6.updatePathMtu(DST6, 1280);
    ipv6.pathMtuTimerTick(ipv6.PMTU_LIFETIME_SEC * 1000);
    if (ipv6.probePathMtuCount() != 1 or ipv6.getPathMtu(DST6) != 1400) {
        fail("v6 raise1");
        return;
    }
    ipv6.pathMtuTimerTick(ipv6.PMTU_RAISE_LIFETIME_SEC * 1000);
    if (ipv6.getPathMtu(DST6) != 1492) {
        fail("v6 raise2");
        return;
    }
    ipv6.pathMtuTimerTick(ipv6.PMTU_RAISE_LIFETIME_SEC * 1000);
    if (ipv6.getPathMtu(DST6) != 1500) {
        fail("v6 raise3");
        return;
    }
    // At ceiling: next expiry clears.
    ipv6.pathMtuTimerTick(ipv6.PMTU_RAISE_LIFETIME_SEC * 1000);
    if (ipv6.probePathMtuCount() != 0 or ipv6.getPathMtu(DST6) != netif.getMtu()) {
        fail("v6 clear");
        return;
    }

    // IPv4: learn 576 → 1006 on first expiry.
    ipv4.updatePathMtu(DST4, 576);
    ipv4.pathMtuTimerTick(ipv4.PMTU_LIFETIME_SEC * 1000);
    if (ipv4.probePathMtuCount() != 1 or ipv4.getPathMtu(DST4) != 1006) {
        fail("v4 raise1");
        return;
    }

    // PTB/Frag Needed during raise still lowers (and restarts long lifetime).
    ipv4.updatePathMtu(DST4, 576);
    if (ipv4.getPathMtu(DST4) != 576) {
        fail("v4 relower");
        return;
    }

    ipv4.probeDrainPathMtu(16);
    ipv6.probeDrainPathMtu(16);
    if (ipv4.probePathMtuCount() != 0 or ipv6.probePathMtuCount() != 0) {
        fail("drain");
        return;
    }

    arch.serial.writeString("[SK-103] pmtu raise probe non-x86: OK\n");
}
