pub const ETHERTYPE_IPV4: u16 = 0x0800;
pub const ETHERTYPE_ARP: u16 = 0x0806;

pub fn buildFrame(buf: [*]u8, dst_mac: [6]u8, src_mac: [6]u8, ethertype: u16, payload_len: u16) u16 {
    @memcpy(buf[0..6], &dst_mac);
    @memcpy(buf[6..12], &src_mac);
    buf[12] = @intCast((ethertype >> 8) & 0xFF);
    buf[13] = @intCast(ethertype & 0xFF);
    return 14 + payload_len;
}

pub fn parseEthertype(data: [*]const u8) u16 {
    return (@as(u16, data[12]) << 8) | @as(u16, data[13]);
}
