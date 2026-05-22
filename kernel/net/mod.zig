const netif = @import("netif.zig");
const eth = @import("eth.zig");
const arp = @import("arp.zig");
const ipv4 = @import("ipv4.zig");
const icmp = @import("icmp.zig");
const udp = @import("udp.zig");
pub const tcp = @import("tcp.zig");

pub fn init() void {
    netif.ensureInit();
    arp.init();
    tcp.initTcbs();
}

pub fn handleRxPacket(data: [*]const u8, len: u32) void {
    if (len < 14) return;

    const ethertype = eth.parseEthertype(data);

    switch (ethertype) {
        eth.ETHERTYPE_ARP => {
            arp.handlePacket(data, len);
        },
        eth.ETHERTYPE_IPV4 => {
            if (len < 34) return;
            const info = ipv4.parseHeader(data + 14) orelse return;
            const payload_start: u32 = 14 + @as(u32, info.payload_offset);
            if (payload_start + @as(u32, info.payload_len) > len) return;

            switch (info.protocol) {
                ipv4.PROTO_ICMP => {
                    icmp.handlePacket(info.src_ip, info.dst_ip, data + payload_start, info.payload_len);
                },
                ipv4.PROTO_TCP => {
                    tcp.handlePacket(info.src_ip, info.dst_ip, data + payload_start, info.payload_len);
                },
                ipv4.PROTO_UDP => {
                    udp.handlePacket(info.src_ip, info.dst_ip, data + payload_start, info.payload_len);
                },
                else => {},
            }
        },
        else => {},
    }
}
