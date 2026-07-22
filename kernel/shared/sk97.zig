//! SK-97 — ICMPv6 Packet Too Big → Path MTU cache (non-x86).
//!
//! Oversized IPv6 datagrams could still be sent at link MTU after a router
//! reported a smaller MTU. PTB now updates a Path MTU cache; UDP/TCP IPv6 TX
//! refuse packets larger than the learned MTU (clamped to ≥1280).

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const ipv6 = @import("../net/ipv6.zig");
const icmpv6 = @import("../net/icmpv6.zig");
const bo = @import("../lib/byte_order.zig");

const DST: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x97,
};
const OUR_LL: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x01,
};
const RTR: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x97,
};

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-97] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-97] ipv6 path mtu ptb non-x86: OK\n");
        return;
    }

    // PTB = 8-byte ICMP + 40-byte invoking IPv6 header.
    var ptb: [48]u8 = @splat(0);
    ptb[0] = 2;
    bo.writeU32BeAt(&ptb, 4, 1280);
    ptb[8] = 0x60; // IPv6
    bo.writeU16BeAt(&ptb, 8 + 4, 100); // payload len
    ptb[8 + 6] = ipv6.PROTO_UDP;
    @memcpy(ptb[8 + 8 .. 8 + 24], &OUR_LL);
    @memcpy(ptb[8 + 24 .. 8 + 40], &DST);

    const parsed = icmpv6.parsePacketTooBig(&ptb, 48) orelse {
        fail("parse");
        return;
    };
    if (parsed.mtu != 1280 or !ipv6.addrEq(parsed.dst, DST)) {
        fail("fields");
        return;
    }

    ipv6.initPmtu();
    if (ipv6.getPathMtu(DST) != ipv6.LINK_MTU) {
        fail("default mtu");
        return;
    }

    // Apply via RX path.
    var pkt = ptb;
    pkt[2] = 0;
    pkt[3] = 0;
    const csum = icmpv6.checksum(RTR, OUR_LL, &pkt, 48);
    bo.writeU16BeAt(&pkt, 2, csum);
    icmpv6.handlePacket(RTR, OUR_LL, &pkt, 48);

    if (ipv6.probePathMtuCount() != 1 or ipv6.getPathMtu(DST) != 1280) {
        fail("learned");
        return;
    }

    // Clamp below minimum up to 1280.
    ipv6.updatePathMtu(DST, 500);
    if (ipv6.getPathMtu(DST) != ipv6.MIN_MTU) {
        fail("clamp min");
        return;
    }

    // Never raise via a higher PTB report.
    ipv6.updatePathMtu(DST, 1400);
    if (ipv6.getPathMtu(DST) != ipv6.MIN_MTU) {
        fail("no raise");
        return;
    }

    // TX gate: IPv6+UDP+payload must fit in learned PMTU (same check as sendToV6).
    const oversize_total: u16 = ipv6.HEADER_LEN + 8 + 1300;
    const fit_total: u16 = ipv6.HEADER_LEN + 8 + 100;
    if (oversize_total <= ipv6.getPathMtu(DST) or fit_total > ipv6.getPathMtu(DST)) {
        fail("tx gate");
        return;
    }

    // Lifetime expiry restores LINK_MTU.
    ipv6.pathMtuTimerTick(ipv6.PMTU_LIFETIME_SEC * 1000);
    if (ipv6.probePathMtuCount() != 0 or ipv6.getPathMtu(DST) != ipv6.LINK_MTU) {
        fail("expire");
        return;
    }

    arch.serial.writeString("[SK-97] ipv6 path mtu ptb non-x86: OK\n");
}
