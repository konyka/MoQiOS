//! SK-82 — Router Solicitation builder + RA default-router learning on non-x86.
//!
//! NUD is complete through SK-81, but hosts still have no default router.
//! This probe locks RS → ff02::2 and RA parse → `ndp.setDefaultRouter`.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const ndp = @import("../net/ndp.zig");
const icmpv6 = @import("../net/icmpv6.zig");
const ipv6 = @import("../net/ipv6.zig");
const eth = @import("../net/eth.zig");
const bo = @import("../lib/byte_order.zig");

const OUR_LL: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x01,
};
const OUR_MAC = [6]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
const RTR_LL: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x82,
};
const RTR_MAC = [6]u8{ 0x02, 0, 0, 0x82, 0x00, 0x01 };

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-82] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

fn macEq(a: [6]u8, b: [6]u8) bool {
    for (a, 0..) |x, i| if (x != b[i]) return false;
    return true;
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-82] ndp router solicit advert non-x86: OK\n");
        return;
    }

    const all_rtr = ipv6.allRoutersLinkLocalMulticast();
    const want_rtr = [16]u8{ 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02 };
    if (!ipv6.addrEq(all_rtr, want_rtr)) {
        fail("ff02::2");
        return;
    }

    var frame: [128]u8 = @splat(0);
    const flen = icmpv6.buildRouterSolicitation(&frame, OUR_LL, OUR_MAC);
    if (flen != 54 + 16) {
        fail("rs len");
        return;
    }
    if (eth.parseEthertype(&frame) != eth.ETHERTYPE_IPV6) {
        fail("ethertype");
        return;
    }
    const want_mac = ipv6.multicastMac(all_rtr);
    var eth_dst: [6]u8 = undefined;
    @memcpy(&eth_dst, frame[0..6]);
    if (!macEq(eth_dst, want_mac)) {
        fail("rs dst mac");
        return;
    }
    const info = ipv6.parseHeader(frame[14..].ptr) orelse {
        fail("ipv6");
        return;
    };
    if (!ipv6.addrEq(info.dst_ip, all_rtr) or info.payload_len != 16) {
        fail("rs ipv6");
        return;
    }
    if (frame[54] != 133 or frame[54 + 8] != 1) {
        fail("rs icmp");
        return;
    }
    if (icmpv6.checksum(OUR_LL, all_rtr, frame[54..].ptr, 16) != 0) {
        fail("rs csum");
        return;
    }

    // Synthesize a minimal RA with Source LL and Router Lifetime.
    var ra: [24]u8 = @splat(0);
    ra[0] = 134;
    ra[4] = 64; // hop limit
    bo.writeU16BeAt(&ra, 6, 1800); // lifetime
    ra[16] = 1; // Source LL
    ra[17] = 1;
    @memcpy(ra[18..24], &RTR_MAC);

    const parsed = icmpv6.parseRouterAdvertisement(&ra, 24) orelse {
        fail("parse ra");
        return;
    };
    if (parsed.router_lifetime_sec != 1800 or parsed.hop_limit != 64) {
        fail("ra fields");
        return;
    }
    const sll = parsed.source_ll orelse {
        fail("ra sll");
        return;
    };
    if (!macEq(sll, RTR_MAC)) {
        fail("ra mac");
        return;
    }

    ndp.init();
    // Apply via the RX path (checksummed ICMPv6 message).
    // Rebuild RA with valid checksum for handlePacket.
    var pkt_icmp: [24]u8 = ra;
    pkt_icmp[2] = 0;
    pkt_icmp[3] = 0;
    const csum = icmpv6.checksum(RTR_LL, OUR_LL, &pkt_icmp, 24);
    bo.writeU16BeAt(&pkt_icmp, 2, csum);
    icmpv6.handlePacket(RTR_LL, OUR_LL, &pkt_icmp, 24);

    const dr = ndp.getDefaultRouter() orelse {
        fail("default router");
        return;
    };
    if (!ipv6.addrEq(dr, RTR_LL) or ndp.probeDefaultRouterLifetime() != 1800) {
        fail("router fields");
        return;
    }
    const cached = ndp.lookup(RTR_LL) orelse {
        fail("router neighbor");
        return;
    };
    if (!macEq(cached, RTR_MAC)) {
        fail("router mac cache");
        return;
    }

    // Lifetime 0 clears this default router.
    var ra0: [16]u8 = @splat(0);
    ra0[0] = 134;
    const csum0 = icmpv6.checksum(RTR_LL, OUR_LL, &ra0, 16);
    bo.writeU16BeAt(&ra0, 2, csum0);
    icmpv6.handlePacket(RTR_LL, OUR_LL, &ra0, 16);
    if (ndp.getDefaultRouter() != null) {
        fail("clear router");
        return;
    }

    arch.serial.writeString("[SK-82] ndp router solicit advert non-x86: OK\n");
}
