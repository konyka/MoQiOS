//! SK-72 — NDP Neighbor Solicitation builder (`icmpv6.buildNeighborSolicitation`)
//! on non-x86.
//!
//! SK-70's `sendToV6` only `markIncomplete` on a cache miss; without an NS the
//! peer never learns to answer. This probe locks the pure NS frame (solicited-
//! node L3/L2, type 135, Source-LL option) and confirms `multicastMac`.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const icmpv6 = @import("../net/icmpv6.zig");
const ipv6 = @import("../net/ipv6.zig");
const eth = @import("../net/eth.zig");

const OUR_LL: [16]u8 = .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01 };
const TARGET: [16]u8 = .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xab, 0xcd, 0xef };
const OUR_MAC: [6]u8 = .{ 0x52, 0x54, 0x00, 0xAA, 0xBB, 0xCC };

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-72] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-72] ndp neighbor solicitation non-x86: OK\n");
        return;
    }

    const sn = ipv6.solicitedNodeMulticast(TARGET);
    const want_sn = [16]u8{
        0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0xff, 0xab, 0xcd, 0xef,
    };
    if (!ipv6.addrEq(sn, want_sn)) {
        fail("solicited-node");
        return;
    }
    const mcast_mac = ipv6.multicastMac(sn);
    const want_mac = [6]u8{ 0x33, 0x33, 0xff, 0xab, 0xcd, 0xef };
    for (want_mac, 0..) |b, i| {
        if (mcast_mac[i] != b) {
            fail("mcast mac");
            return;
        }
    }

    var frame: [128]u8 = @splat(0);
    const frame_len = icmpv6.buildNeighborSolicitation(&frame, OUR_LL, TARGET, OUR_MAC);
    const icmp_off: usize = 54;
    if (frame_len != icmp_off + 32) {
        fail("frame length");
        return;
    }

    if (eth.parseEthertype(&frame) != eth.ETHERTYPE_IPV6) {
        fail("ethertype");
        return;
    }
    for (want_mac, 0..) |b, i| {
        if (frame[i] != b) {
            fail("dst mac");
            return;
        }
    }
    for (OUR_MAC, 0..) |b, i| {
        if (frame[6 + i] != b) {
            fail("src mac");
            return;
        }
    }

    const info = ipv6.parseHeader(frame[14..].ptr) orelse {
        fail("ipv6 parse");
        return;
    };
    if (info.next_header != ipv6.PROTO_ICMPV6 or info.payload_len != 32) {
        fail("ipv6 fields");
        return;
    }
    if (!ipv6.addrEq(info.src_ip, OUR_LL) or !ipv6.addrEq(info.dst_ip, sn)) {
        fail("ipv6 addrs");
        return;
    }

    if (frame[icmp_off] != 135 or frame[icmp_off + 1] != 0) {
        fail("NS type/code");
        return;
    }
    for (TARGET, 0..) |b, i| {
        if (frame[icmp_off + 8 + i] != b) {
            fail("NS target");
            return;
        }
    }
    if (frame[icmp_off + 24] != 1 or frame[icmp_off + 25] != 1) {
        fail("source-ll option");
        return;
    }
    for (OUR_MAC, 0..) |b, i| {
        if (frame[icmp_off + 26 + i] != b) {
            fail("source-ll mac");
            return;
        }
    }

    if (icmpv6.checksum(OUR_LL, sn, frame[icmp_off..].ptr, 32) != 0) {
        fail("NS checksum");
        return;
    }

    arch.serial.writeString("[SK-72] ndp neighbor solicitation non-x86: OK\n");
}
