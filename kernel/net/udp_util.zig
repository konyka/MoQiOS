//! Pure UDP helpers (IPv6 checksum + header field parse).
//!
//! IPv4 UDP may leave checksum 0; IPv6 requires a non-zero checksum over the
//! IPv6 pseudo-header + UDP segment (RFC 8200 §8.1 / RFC 768).

const ipv4 = @import("ipv4.zig");
const ipv6 = @import("ipv6.zig");
const bo = @import("../lib/byte_order.zig");

pub const HEADER_LEN: u16 = 8;

/// Parsed UDP header fields (payload length excludes the 8-byte header).
pub const UdpHdr = struct {
    src_port: u16,
    dst_port: u16,
    /// Total UDP length including header, as advertised in the length field.
    udp_len: u16,
    payload_len: u16,
};

/// Parse a UDP header. Returns null when `len` is shorter than 8 bytes.
pub fn parseHeader(data: [*]const u8, len: u32) ?UdpHdr {
    if (len < HEADER_LEN) return null;
    const src_port = bo.readU16BeAt(data, 0);
    const dst_port = bo.readU16BeAt(data, 2);
    const udp_len = bo.readU16BeAt(data, 4);
    const payload_len: u16 = if (udp_len > HEADER_LEN) udp_len - HEADER_LEN else 0;
    return .{
        .src_port = src_port,
        .dst_port = dst_port,
        .udp_len = udp_len,
        .payload_len = payload_len,
    };
}

/// IPv4 UDP checksum over the pseudo-header + UDP segment (RFC 768).
/// Bytes 6..7 of `data` (on-wire checksum) are treated as zero so this works
/// for both building and verifying.
pub fn checksumV4(
    src: [4]u8,
    dst: [4]u8,
    data: [*]const u8,
    len: u16,
) u16 {
    var pseudo: [12]u8 = undefined;
    @memcpy(pseudo[0..4], &src);
    @memcpy(pseudo[4..8], &dst);
    pseudo[8] = 0; // zero
    pseudo[9] = 17; // UDP protocol
    bo.writeU16BeAt(&pseudo, 10, len);

    var acc: u64 = @as(u64, ~ipv4.checksum(&pseudo, 12) & 0xFFFF);

    var i: usize = 0;
    while (i + 2 <= len) : (i += 2) {
        if (i == 6) continue; // skip checksum field
        acc += (@as(u64, data[i]) << 8) | @as(u64, data[i + 1]);
    }
    if (i < len) {
        acc += @as(u64, data[i]) << 8;
    }

    var sum: u32 = @truncate(acc);
    sum +%= @as(u32, @truncate(acc >> 32));
    sum = (sum & 0xFFFF) + (sum >> 16);
    sum = (sum & 0xFFFF) + (sum >> 16);
    const folded: u16 = @truncate(~sum);
    // RFC 768: a computed 0 is transmitted as 0xFFFF.
    return if (folded == 0) 0xFFFF else folded;
}

/// IPv6 UDP checksum over the pseudo-header + UDP segment.
/// Bytes 6..7 of `data` (on-wire checksum) are treated as zero so this works
/// for both building and verifying.
pub fn checksumV6(
    src: [16]u8,
    dst: [16]u8,
    data: [*]const u8,
    len: u16,
) u16 {
    var acc: u64 = ipv6.pseudoHeaderChecksum(src, dst, ipv6.PROTO_UDP, len);

    var i: usize = 0;
    while (i + 2 <= len) : (i += 2) {
        if (i == 6) continue; // skip checksum field
        acc += (@as(u64, data[i]) << 8) | @as(u64, data[i + 1]);
    }
    if (i < len) {
        acc += @as(u64, data[i]) << 8;
    }

    var sum: u32 = @truncate(acc);
    sum +%= @as(u32, @truncate(acc >> 32));
    sum = (sum & 0xFFFF) + (sum >> 16);
    sum = (sum & 0xFFFF) + (sum >> 16);
    const folded: u16 = @truncate(~sum);
    // RFC 768: a computed 0 is transmitted as 0xFFFF for IPv6 UDP.
    return if (folded == 0) 0xFFFF else folded;
}
