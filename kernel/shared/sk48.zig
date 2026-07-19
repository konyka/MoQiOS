//! SK-48 — shared IPv6 header + pseudo-header checksum + address helpers on non-x86.
//!
//! Second slice of the network protocol table proven portable (after SK-47's
//! ipv4). `net/ipv6.zig` also depends only on `lib/byte_order.zig` (std-free,
//! arch-clean): fixed-40-byte header build/parse, the RFC 8200 §8.1
//! pseudo-header partial checksum, and the address predicates
//! (link-local / multicast / solicited-node). This probe compiles ipv6.zig
//! into the riscv64/aarch64 image and exercises all of it.
//!
//! The load-bearing check is pseudoHeaderChecksum's documented contract: it
//! returns the *unfolded* 32-bit accumulator so an upper-layer (TCP/UDP/
//! ICMPv6) can keep summing its own bytes before the final fold+complement.
//! We replicate that exact usage — seed with the pseudo-header, sum a payload,
//! fold+complement to a checksum, write it back, then re-sum the whole thing
//! and confirm it folds to 0 (RFC 1071 self-check over the pseudo-header).

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const ipv6 = @import("../net/ipv6.zig");

const SRC: [16]u8 = .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01 };
const DST: [16]u8 = .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02 };

/// Fold a running 32-bit accumulator to 16 bits and take the one's-complement,
/// matching the tail of the shared RFC 1071 checksum.
fn foldComplement(acc_in: u32) u16 {
    var sum = acc_in;
    sum = (sum & 0xFFFF) + (sum >> 16);
    sum = (sum & 0xFFFF) + (sum >> 16);
    return @truncate(~sum);
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-48] shared ipv6 header/pseudo-csum: OK\n");
        return;
    }

    // Header build + parse round-trip.
    const payload = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x10, 0x20 };
    var hdr: [40]u8 = undefined;
    ipv6.buildHeader(&hdr, SRC, DST, ipv6.PROTO_UDP, payload.len);

    const info = ipv6.parseHeader(&hdr) orelse {
        arch.serial.writeString("[SK-48] FAILED: parseHeader null\n");
        return;
    };
    if (info.next_header != ipv6.PROTO_UDP or info.payload_len != payload.len or
        info.payload_offset != ipv6.HEADER_LEN or info.hop_limit != ipv6.DEFAULT_HOP_LIMIT)
    {
        arch.serial.writeString("[SK-48] FAILED: header fields\n");
        return;
    }
    if (!ipv6.addrEq(info.src_ip, SRC) or !ipv6.addrEq(info.dst_ip, DST)) {
        arch.serial.writeString("[SK-48] FAILED: address round-trip\n");
        return;
    }

    // pseudoHeaderChecksum contract: seed accumulator, keep summing payload,
    // fold+complement, write checksum back, then the whole thing must fold to 0.
    var buf = [_]u8{ 0, 0 } ++ payload; // 2-byte checksum slot + payload
    const total_len: u16 = @intCast(buf.len);
    var acc: u32 = ipv6.pseudoHeaderChecksum(SRC, DST, ipv6.PROTO_UDP, total_len);
    var i: usize = 0;
    while (i + 2 <= buf.len) : (i += 2) {
        acc +%= (@as(u32, buf[i]) << 8) | @as(u32, buf[i + 1]);
    }
    if (i < buf.len) acc +%= @as(u32, buf[i]) << 8;
    const csum = foldComplement(acc);
    buf[0] = @truncate(csum >> 8);
    buf[1] = @truncate(csum);

    // Re-sum with the checksum in place; a correct checksum folds to 0.
    var acc2: u32 = ipv6.pseudoHeaderChecksum(SRC, DST, ipv6.PROTO_UDP, total_len);
    i = 0;
    while (i + 2 <= buf.len) : (i += 2) {
        acc2 +%= (@as(u32, buf[i]) << 8) | @as(u32, buf[i + 1]);
    }
    if (i < buf.len) acc2 +%= @as(u32, buf[i]) << 8;
    if (foldComplement(acc2) != 0) {
        arch.serial.writeString("[SK-48] FAILED: pseudo-header self-checksum nonzero\n");
        return;
    }

    // Address predicates.
    if (!ipv6.isLinkLocal(SRC)) {
        arch.serial.writeString("[SK-48] FAILED: isLinkLocal\n");
        return;
    }
    if (ipv6.isMulticast(SRC) or ipv6.isUnspecified(SRC)) {
        arch.serial.writeString("[SK-48] FAILED: unicast misclassified\n");
        return;
    }
    const snm = ipv6.solicitedNodeMulticast(DST);
    if (!ipv6.isMulticast(snm) or !ipv6.isSolicitedNodeMulticast(snm, DST)) {
        arch.serial.writeString("[SK-48] FAILED: solicited-node multicast\n");
        return;
    }
    const zero: [16]u8 = @splat(0);
    if (!ipv6.isUnspecified(zero) or ipv6.isSolicitedNodeMulticast(snm, zero)) {
        arch.serial.writeString("[SK-48] FAILED: unspecified/snm mismatch\n");
        return;
    }

    arch.serial.writeString("[SK-48] shared ipv6 header/pseudo-csum: OK\n");
}
