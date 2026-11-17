const netif = @import("netif.zig");
const lo = @import("lo.zig");
const eth = @import("eth.zig");
const arp = @import("arp.zig");
const ipv4 = @import("ipv4.zig");
const icmp = @import("icmp.zig");
const udp = @import("udp.zig");
const ipv6 = @import("ipv6.zig");
const icmpv6 = @import("icmpv6.zig");
const ndp = @import("ndp.zig");
pub const tcp = @import("tcp.zig");
pub const tcp_recv_policy = @import("tcp_recv_policy.zig");
pub const tcp_port_policy = @import("tcp_port_policy.zig");
pub const epoll = @import("epoll.zig");
pub const unix_socket = @import("unix_socket.zig");
pub const socket_opt = @import("socket_opt.zig");

pub fn init() void {
    netif.ensureInit();
    lo.init();
    arp.init();
    ndp.init();
    ipv6.initPmtu();
    ipv4.initPmtu();
    tcp.initTcbs();
    // SK-88: solicit routers so RA can populate default route / prefixes.
    icmpv6.startRouterSolicit();
}

pub fn handleRxPacket(data: [*]const u8, len: u32) void {
    handleRxPacketOn(data, len, @intCast(@import("bind_addr_policy.zig").NIC_IFINDEX));
}

/// handleRxPacket for a frame that arrived on interface `ifindex` (1 lo, 2 the NIC); UDP group delivery depends on it.
pub fn handleRxPacketOn(data: [*]const u8, len: u32, ifindex: u8) void {
    if (len < 14) return;

    const ethertype = eth.parseEthertype(data);

    switch (ethertype) {
        eth.ETHERTYPE_ARP => {
            arp.handlePacket(data, len);
        },
        eth.ETHERTYPE_IPV4 => {
            if (len < 34) return;
            const info = ipv4.parseHeader(data + 14, len - 14) orelse return;
            const payload_start: u32 = 14 + @as(u32, info.payload_offset);
            if (payload_start + @as(u32, info.payload_len) > len) return;

            // Linux raw_local_deliver hands each raw socket of the datagram's protocol a copy (IP header included) before the protocol
            // handler runs.
            const raw_took = @import("raw_icmp.zig").deliver(info.protocol, data[14 .. payload_start + info.payload_len], info.src_ip, info.dst_ip);
            const rp = @import("raw_icmp_policy.zig");
            switch (info.protocol) {
                ipv4.PROTO_ICMP => {
                    icmp.handlePacket(info.src_ip, info.dst_ip, data + payload_start, info.payload_len);
                },
                ipv4.PROTO_TCP => {
                    tcp.handlePacket(info.src_ip, info.dst_ip, data + payload_start, info.payload_len, info.ecn_ce);
                },
                ipv4.PROTO_UDP => {
                    udp.handlePacketOn(info.src_ip, info.dst_ip, data + payload_start, info.payload_len, ifindex);
                },
                // ip_protocol_deliver_rcu: a protocol with no handler that no raw socket took gets a protocol unreachable.
                else => if (rp.protoUnreachable(info.protocol, raw_took)) icmp.sendProtoUnreachable(data[14 .. payload_start + info.payload_len], info.src_ip, info.dst_ip),
            }
        },
        eth.ETHERTYPE_IPV6 => {
            if (len < 54) return; // 14 (eth) + 40 (ipv6 fixed header)
            const info6 = ipv6.parseHeader(data + 14) orelse return;
            const payload_start6: u32 = 14 + @as(u32, info6.payload_offset);
            if (payload_start6 + @as(u32, info6.payload_len) > len) return;

            // raw6_local_deliver: each IPv6 raw socket of the next header gets the packet, without its IPv6 header, before the
            // protocol handler (ip6_protocol_deliver_rcu).
            const raw_took6 = @import("raw_icmp.zig").deliver6(info6.next_header, data[payload_start6 .. payload_start6 + info6.payload_len], info6.src_ip, info6.dst_ip);
            const rp6 = @import("raw_icmp_policy.zig");
            switch (info6.next_header) {
                ipv6.PROTO_ICMPV6 => {
                    icmpv6.handlePacket(info6.src_ip, info6.dst_ip, data + payload_start6, info6.payload_len);
                },
                ipv6.PROTO_TCP => {
                    tcp.handlePacketV6(info6.src_ip, info6.dst_ip, data + payload_start6, info6.payload_len, info6.ecn_ce);
                },
                ipv6.PROTO_UDP => {
                    udp.handlePacketV6On(info6.src_ip, info6.dst_ip, data + payload_start6, info6.payload_len, ifindex);
                },
                // ip6_protocol_deliver_rcu: a next header with no handler that no raw socket took gets a parameter problem.
                else => if (rp6.paramProblem6(info6.next_header, raw_took6)) icmpv6.sendParamProblem(data[14 .. payload_start6 + info6.payload_len], info6.src_ip, info6.dst_ip),
            }
        },
        else => {},
    }
}
