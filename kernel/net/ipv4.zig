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
    buf[2] = @intCast((total_len >> 8) & 0xFF);
    buf[3] = @intCast(total_len & 0xFF);
    buf[4] = 0x00; buf[5] = 0x00;
    buf[6] = 0x40; buf[7] = 0x00;
    buf[8] = 0x40;
    buf[9] = protocol;
    buf[10] = 0x00; buf[11] = 0x00;
    @memcpy(buf[12..16], &src_ip);
    @memcpy(buf[16..20], &dst_ip);

    // Inline checksum computation
    var sum: u32 = 0;
    for (0..10) |i| {
        sum +|= (@as(u32, buf[i * 2]) << 8) | @as(u32, buf[i * 2 + 1]);
    }
    while (sum > 0xFFFF) {
        const carry = sum >> 16;
        sum = (sum & 0xFFFF) + carry;
        if (carry == 0) break;
    }
    const csum: u16 = @truncate(~sum);
    buf[10] = @intCast((csum >> 8) & 0xFF);
    buf[11] = @intCast(csum & 0xFF);
}

pub fn checksum(buf: [*]const u8, len: u16) u16 {
    var sum: u32 = 0;
    const words = len / 2;
    for (0..words) |i| {
        sum +|= (@as(u32, buf[i * 2]) << 8) | @as(u32, buf[i * 2 + 1]);
    }
    if (len % 2 == 1) {
        sum +|= @as(u32, buf[len - 1]) << 8;
    }
    while (sum > 0xFFFF) {
        const carry = sum >> 16;
        sum = (sum & 0xFFFF) + carry;
        if (carry == 0) break;
    }
    return @truncate(~sum);
}

pub fn parseHeader(data: [*]const u8) ?Ipv4Info {
    const version = (data[0] >> 4) & 0xF;
    if (version != 4) return null;

    const ihl = @as(u16, data[0] & 0xF) * 4;
    if (ihl < 20) return null;

    const total_len = (@as(u16, data[2]) << 8) | @as(u16, data[3]);
    const payload_len = total_len - ihl;

    return .{
        .src_ip = .{ data[12], data[13], data[14], data[15] },
        .dst_ip = .{ data[16], data[17], data[18], data[19] },
        .protocol = data[9],
        .payload_offset = ihl,
        .payload_len = payload_len,
    };
}
