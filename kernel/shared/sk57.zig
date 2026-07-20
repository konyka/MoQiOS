//! SK-57 — ICMPv6 checksum + Neighbor Advertisement builder (`net/icmpv6.zig`) on non-x86.
//!
//! icmpv6.zig imports only nic/netif/eth/ipv6/ndp/byte_order — all arch-clean
//! after SK-56 — and has no timers, so it compiles on riscv64/aarch64. Its NA
//! reply was buried in sendNeighborAdvertisement (ndp.lookup + netif + nic side
//! effects); following SK-55, the frame construction is factored into a pure
//! `icmpv6.buildNeighborAdvertisement` (caller supplies MACs) and the checksum
//! is now `pub`. SK-57 verifies both on non-x86:
//!   - the ICMPv6 pseudo-header checksum self-check (fill csum → re-verify 0),
//!   - the full NA frame: ethertype, MAC swap, IPv6 header (next=ICMPv6,
//!     src=target, dst=requester), NA type/flags, target address, Target-LL
//!     option = our MAC, and a valid ICMPv6 checksum over the message.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const icmpv6 = @import("../net/icmpv6.zig");
const ipv6 = @import("../net/ipv6.zig");
const eth = @import("../net/eth.zig");

const OUR_LL: [16]u8 = .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01 };
const PEER_LL: [16]u8 = .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02 };
const OUR_MAC: [6]u8 = .{ 0x52, 0x54, 0x00, 0xAA, 0xBB, 0xCC };
const PEER_MAC: [6]u8 = .{ 0x52, 0x54, 0x00, 0x11, 0x22, 0x33 };

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-57] icmpv6 checksum/NA builder non-x86: OK\n");
        return;
    }

    // ICMPv6 checksum self-check on a small echo-reply message.
    var msg: [12]u8 = .{ 129, 0, 0, 0, 0xBE, 0xEF, 0x00, 0x01, 'p', 'o', 'n', 'g' };
    const c = icmpv6.checksum(OUR_LL, PEER_LL, &msg, msg.len);
    msg[2] = @truncate(c >> 8);
    msg[3] = @truncate(c);
    if (icmpv6.checksum(OUR_LL, PEER_LL, &msg, msg.len) != 0) {
        arch.serial.writeString("[SK-57] FAILED: checksum self-check\n");
        return;
    }

    // Build a solicited Neighbor Advertisement: target is OUR_LL, to PEER.
    var frame: [128]u8 = @splat(0);
    const frame_len = icmpv6.buildNeighborAdvertisement(&frame, PEER_LL, OUR_LL, OUR_MAC, PEER_MAC, true);
    const icmp_off: usize = 54; // 14 eth + 40 ipv6
    if (frame_len != icmp_off + 32) {
        arch.serial.writeString("[SK-57] FAILED: frame length\n");
        return;
    }

    // L2: ethertype IPv6, dst = peer, src = us.
    if (eth.parseEthertype(&frame) != eth.ETHERTYPE_IPV6) {
        arch.serial.writeString("[SK-57] FAILED: ethertype\n");
        return;
    }
    for (PEER_MAC, 0..) |b, i| {
        if (frame[i] != b) {
            arch.serial.writeString("[SK-57] FAILED: dst mac\n");
            return;
        }
    }
    for (OUR_MAC, 0..) |b, i| {
        if (frame[6 + i] != b) {
            arch.serial.writeString("[SK-57] FAILED: src mac\n");
            return;
        }
    }

    // L3: IPv6 header — next header ICMPv6, src=target(OUR_LL), dst=requester(PEER).
    const info = ipv6.parseHeader(frame[14..].ptr) orelse {
        arch.serial.writeString("[SK-57] FAILED: ipv6 parse\n");
        return;
    };
    if (info.next_header != ipv6.PROTO_ICMPV6 or info.payload_len != 32) {
        arch.serial.writeString("[SK-57] FAILED: ipv6 fields\n");
        return;
    }
    if (!ipv6.addrEq(info.src_ip, OUR_LL) or !ipv6.addrEq(info.dst_ip, PEER_LL)) {
        arch.serial.writeString("[SK-57] FAILED: ipv6 addrs\n");
        return;
    }

    // L4: NA type + flags (S|O), target address, Target-LL option = our MAC.
    if (frame[icmp_off] != 136 or frame[icmp_off + 1] != 0) {
        arch.serial.writeString("[SK-57] FAILED: NA type/code\n");
        return;
    }
    if (frame[icmp_off + 4] != 0x60) { // O(0x20) | S(0x40)
        arch.serial.writeString("[SK-57] FAILED: NA flags\n");
        return;
    }
    for (OUR_LL, 0..) |b, i| {
        if (frame[icmp_off + 8 + i] != b) {
            arch.serial.writeString("[SK-57] FAILED: NA target\n");
            return;
        }
    }
    if (frame[icmp_off + 24] != 2 or frame[icmp_off + 25] != 1) {
        arch.serial.writeString("[SK-57] FAILED: target-ll option header\n");
        return;
    }
    for (OUR_MAC, 0..) |b, i| {
        if (frame[icmp_off + 26 + i] != b) {
            arch.serial.writeString("[SK-57] FAILED: target-ll mac\n");
            return;
        }
    }

    // ICMPv6 checksum over the built NA message must be valid (folds to 0).
    if (icmpv6.checksum(OUR_LL, PEER_LL, frame[icmp_off..].ptr, 32) != 0) {
        arch.serial.writeString("[SK-57] FAILED: NA checksum\n");
        return;
    }

    arch.serial.writeString("[SK-57] icmpv6 checksum/NA builder non-x86: OK\n");
}
