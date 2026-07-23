//! SK-98 — TCP IPv6 MSS tracks Path MTU (non-x86).
//!
//! SK-97 learned PMTU but TCP still segmented up to a fixed 1460/1200 cap.
//! IPv6 SMSS is now Path MTU − 60 so flush/send respect the reduced path.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const ipv6 = @import("../net/ipv6.zig");
const tcp = @import("../net/tcp.zig");

const DST: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x98,
};

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-98] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-98] tcp ipv6 mss pmtu non-x86: OK\n");
        return;
    }

    ipv6.initPmtu();

    // Default LINK_MTU 1500 → SMSS 1440 (not the IPv4 1460).
    if (tcp.probeIpv6Mss(DST) != 1440) {
        fail("default mss");
        return;
    }

    ipv6.updatePathMtu(DST, 1400);
    // 1400 − 40 − 20 = 1340.
    if (tcp.probeIpv6Mss(DST) != 1340) {
        fail("pmtu mss");
        return;
    }

    // Lower further.
    ipv6.updatePathMtu(DST, 1280);
    if (tcp.probeIpv6Mss(DST) != 1220) {
        fail("lower");
        return;
    }

    // PTB that would raise is ignored; MSS stays.
    ipv6.updatePathMtu(DST, 1400);
    if (tcp.probeIpv6Mss(DST) != 1220) {
        fail("hold");
        return;
    }

    // SK-103: expiry raises through plateaus before clearing to link MTU.
    ipv6.probeDrainPathMtu(16);
    if (tcp.probeIpv6Mss(DST) != 1440) {
        fail("expire");
        return;
    }

    arch.serial.writeString("[SK-98] tcp ipv6 mss pmtu non-x86: OK\n");
}
