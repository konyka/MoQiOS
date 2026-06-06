const bo = @import("../lib/byte_order.zig");

pub const PROTO_ICMP: u8 = 1;
pub const PROTO_TCP: u8 = 6;
pub const PROTO_UDP: u8 = 17;

pub const Ipv4Info = struct {
    src_ip: [4]u8,
    dst_ip: [4]u8,
    protocol: u8,
    payload_offset: u16,
    payload_len: u16,
};

pub fn buildHeader(buf: [*]u8, src_ip: [4]u8, dst_ip: [4]u8, protocol: u8, payload_len: u16) void {
    const total_len: u16 = 20 + payload_len;

    buf[0] = 0x45;
    buf[1] = 0x00;
    bo.writeU16BeAt(buf, 2, total_len);
    buf[4] = 0x00;
    buf[5] = 0x00;
    buf[6] = 0x40;
    buf[7] = 0x00;
    buf[8] = 0x40;
    buf[9] = protocol;
    buf[10] = 0x00;
    buf[11] = 0x00;
    @memcpy(buf[12..16], &src_ip);
    @memcpy(buf[16..20], &dst_ip);

    const csum = checksum(buf, 20);
    bo.writeU16BeAt(buf, 10, csum);
}

/// Internet checksum (RFC 1071) — optimized with u64 accumulator and 4-byte stride.
pub fn checksum(buf: [*]const u8, len: u16) u16 {
    var acc: u64 = 0;
    const l: usize = len;
    var i: usize = 0;

    // Process 4 bytes (two 16-bit words) per iteration
    while (i + 4 <= l) : (i += 4) {
        acc += (@as(u64, buf[i]) << 24) | (@as(u64, buf[i + 1]) << 16) |
            (@as(u64, buf[i + 2]) << 8) | @as(u64, buf[i + 3]);
    }
    // Remaining 16-bit word
    if (i + 2 <= l) {
        acc += (@as(u64, buf[i]) << 8) | @as(u64, buf[i + 1]);
        i += 2;
    }
    // Odd trailing byte
    if (i < l) {
        acc += @as(u64, buf[i]) << 8;
    }

    // Fold 64→32→16
    var sum: u32 = @truncate(acc);
    sum +|= @as(u32, @truncate(acc >> 32));
    sum = (sum & 0xFFFF) + (sum >> 16);
    sum = (sum & 0xFFFF) + (sum >> 16);
    return @truncate(~sum);
}

pub fn parseHeader(data: [*]const u8) ?Ipv4Info {
    const version = (data[0] >> 4) & 0xF;
    if (version != 4) return null;

    const ihl = @as(u16, data[0] & 0xF) * 4;
    if (ihl < 20) return null;

    const total_len = bo.readU16BeAt(data, 2);
    const payload_len = total_len - ihl;

    return .{
        .src_ip = .{ data[12], data[13], data[14], data[15] },
        .dst_ip = .{ data[16], data[17], data[18], data[19] },
        .protocol = data[9],
        .payload_offset = ihl,
        .payload_len = payload_len,
    };
}
