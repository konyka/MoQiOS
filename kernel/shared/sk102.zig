//! SK-102 — Interface MTU + RA MTU option drive SYN MSS (non-x86).
//!
//! SYN MSS / default Path MTU assumed a fixed 1500-byte Ethernet link and
//! ignored RA MTU options. The interface MTU is now configurable; RA option
//! type=5 updates it (≥1280), and TCP SMSS / PMTU defaults follow.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const netif = @import("../net/netif.zig");
const ipv6 = @import("../net/ipv6.zig");
const ipv4 = @import("../net/ipv4.zig");
const icmpv6 = @import("../net/icmpv6.zig");
const tcp = @import("../net/tcp.zig");
const ndp = @import("../net/ndp.zig");
const bo = @import("../lib/byte_order.zig");

const RTR_LL: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0xa2,
};
const OUR_LL: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x01,
};
const DST6: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0xa2,
};
const DST4: [4]u8 = .{ 10, 0, 0, 102 };

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-102] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-102] if mtu ra syn mss non-x86: OK\n");
        return;
    }

    netif.resetMtu();
    ipv6.initPmtu();
    ipv4.initPmtu();
    ndp.init();

    if (netif.getMtu() != netif.DEFAULT_MTU) {
        fail("default mtu");
        return;
    }

    // RA = 16-byte header + 8-byte MTU option (type=5,len=1,mtu=1280).
    var ra: [24]u8 = @splat(0);
    ra[0] = 134;
    ra[4] = 64;
    bo.writeU16BeAt(&ra, 6, 1800);
    ra[16] = 5;
    ra[17] = 1;
    bo.writeU32BeAt(&ra, 20, 1280);

    const parsed = icmpv6.parseRouterAdvertisement(&ra, 24) orelse {
        fail("parse");
        return;
    };
    if (parsed.mtu == null or parsed.mtu.? != 1280) {
        fail("mtu field");
        return;
    }

    var pkt = ra;
    pkt[2] = 0;
    pkt[3] = 0;
    const csum = icmpv6.checksum(RTR_LL, OUR_LL, &pkt, 24);
    bo.writeU16BeAt(&pkt, 2, csum);
    icmpv6.handlePacket(RTR_LL, OUR_LL, &pkt, 24);

    if (netif.getMtu() != 1280) {
        fail("ra apply");
        return;
    }
    // Default Path MTU and SYN MSS follow the interface MTU.
    if (ipv6.getPathMtu(DST6) != 1280 or tcp.probeSynOfferMssV6(DST6) != 1220) {
        fail("v6 mss");
        return;
    }
    if (ipv4.getPathMtu(DST4) != 1280 or tcp.probeIpv4Mss(DST4) != 1240) {
        fail("v4 mss");
        return;
    }

    // Raise interface MTU; MSS grows until a smaller PMTU is learned.
    netif.setMtu(1400);
    ipv6.initPmtu();
    if (tcp.probeSynOfferMssV6(DST6) != 1340) {
        fail("raise mss");
        return;
    }
    ipv6.updatePathMtu(DST6, 1280);
    if (tcp.probeSynOfferMssV6(DST6) != 1220) {
        fail("pmtu clamp");
        return;
    }

    // RA MTU below IPv6 minimum must be ignored.
    netif.setMtu(1400);
    var ra_low = ra;
    bo.writeU32BeAt(&ra_low, 20, 1000);
    ra_low[2] = 0;
    ra_low[3] = 0;
    const csum_low = icmpv6.checksum(RTR_LL, OUR_LL, &ra_low, 24);
    bo.writeU16BeAt(&ra_low, 2, csum_low);
    icmpv6.handlePacket(RTR_LL, OUR_LL, &ra_low, 24);
    if (netif.getMtu() != 1400) {
        fail("ignore low");
        return;
    }

    netif.resetMtu();
    ipv6.initPmtu();
    ipv4.initPmtu();
    arch.serial.writeString("[SK-102] if mtu ra syn mss non-x86: OK\n");
}
