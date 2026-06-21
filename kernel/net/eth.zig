const bo = @import("../lib/byte_order.zig");

pub const ETHERTYPE_IPV4: u16 = 0x0800;
pub const ETHERTYPE_ARP: u16 = 0x0806;
pub const ETHERTYPE_IPV6: u16 = 0x86DD;

pub fn buildFrame(buf: [*]u8, dst_mac: [6]u8, src_mac: [6]u8, ethertype: u16, payload_len: u16) u16 {
    @memcpy(buf[0..6], &dst_mac);
    @memcpy(buf[6..12], &src_mac);
    bo.writeU16BeAt(buf, 12, ethertype);
    return 14 + payload_len;
}

pub fn parseEthertype(data: [*]const u8) u16 {
    return bo.readU16BeAt(data, 12);
}
