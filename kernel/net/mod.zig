const netif = @import("netif.zig");
const eth = @import("eth.zig");
const arp = @import("arp.zig");
const ipv4 = @import("ipv4.zig");
const icmp = @import("icmp.zig");
const udp = @import("udp.zig");
const ipv6 = @import("ipv6.zig");
const icmpv6 = @import("icmpv6.zig");
const ndp = @import("ndp.zig");
pub const tcp = @import("tcp.zig");
pub const epoll = @import("epoll.zig");
pub const unix_socket = @import("unix_socket.zig");
pub const socket_opt = @import("socket_opt.zig");

pub fn init() void {
    netif.ensureInit();
    arp.init();
    ndp.init();
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
        eth.ETHERTYPE_IPV6 => {
            if (len < 54) return; // 14 (eth) + 40 (ipv6 fixed header)
            const info6 = ipv6.parseHeader(data + 14) orelse return;
            const payload_start6: u32 = 14 + @as(u32, info6.payload_offset);
            if (payload_start6 + @as(u32, info6.payload_len) > len) return;

            switch (info6.next_header) {
                ipv6.PROTO_ICMPV6 => {
                    icmpv6.handlePacket(info6.src_ip, info6.dst_ip, data + payload_start6, info6.payload_len);
                },
                ipv6.PROTO_TCP => {
                    // TODO: tcp over ipv6 integration
                },
                ipv6.PROTO_UDP => {
                    udp.handlePacketV6(info6.src_ip, info6.dst_ip, data + payload_start6, info6.payload_len);
                },
                else => {},
            }
        },
        else => {},
    }
}
