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

fn isLocal4(a: [4]u8) bool {
    return netif.isLocal4(a);
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
            // ip_defrag: a fragment joins its reassembly queue; a completed datagram comes back through here whole.
            if (@import("ip_frag.zig").isFragment(data + 14, len - 14)) {
                @import("ip_frag.zig").receive(data, len, ifindex);
                return;
            }
            const info = ipv4.parseHeader(data + 14, len - 14) orelse return;
            const payload_start: u32 = 14 + @as(u32, info.payload_offset);
            if (payload_start + @as(u32, info.payload_len) > len) return;
            // ip_rcv_options: a header with options is compiled (record route and timestamps get this host's entry); a malformed
            // option drops the datagram, and so does a source route (accept_source_route 0).
            var meta4: @import("ip_cmsg_policy.zig").RecvInfo = .{ .ifindex = ifindex, .dst = info.dst_ip, .ttl = info.ttl, .tos = info.tos };
            if (info.payload_offset > 20) {
                const iop = @import("ip_options_policy.zig");
                const n_opt: usize = info.payload_offset - 20;
                @memcpy(meta4.opts[0..n_opt], data[14 + 20 ..][0..n_opt]);
                // inet_current_timestamp: milliseconds since midnight UTC.
                const now_ms = iop.msSinceMidnight(@import("../proc/time_syscall.zig").wallClockNanos());
                const c = switch (iop.compile(meta4.opts[0..n_opt], info.dst_ip, now_ms, &isLocal4)) {
                    .ok => |o| o,
                    .bad => return,
                };
                if (c.srr != null) return;
                meta4.optlen = @intCast(n_opt);
                if (iop.echo(meta4.opts[0..n_opt], c, info.src_ip, &meta4.retopts)) |rl| meta4.retlen = @intCast(rl) else meta4.ret_bad = true;
            }

            // Linux raw_local_deliver hands each raw socket of the datagram's protocol a copy (IP header included) before the protocol
            // handler runs.
            const raw_took = @import("raw_icmp.zig").deliver(info.protocol, data[14 .. payload_start + info.payload_len], info.src_ip, info.dst_ip, ifindex);
            const rp = @import("raw_icmp_policy.zig");
            switch (info.protocol) {
                ipv4.PROTO_ICMP => {
                    icmp.handlePacketMeta(info.src_ip, info.dst_ip, data + payload_start, info.payload_len, .{ .ifindex = ifindex, .dst = info.dst_ip, .ttl = info.ttl, .tos = info.tos });
                },
                ipv4.PROTO_TCP => {
                    tcp.handlePacket(info.src_ip, info.dst_ip, data + payload_start, info.payload_len, info.ecn_ce);
                },
                ipv4.PROTO_UDP => {
                    udp.handlePacketMetaInfo(info.src_ip, info.dst_ip, data + payload_start, info.payload_len, meta4);
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

            const rp6 = @import("raw_icmp_policy.zig");
            const raw6 = @import("raw_icmp.zig");
            const pkt6 = data[14 .. payload_start6 + info6.payload_len];
            // Hop-by-hop and destination options are stepped over (ipv6_parse_hopopts, ipv6_destopt_rcv); raw sockets of each header
            // passed see the packet from that header on (ip6_protocol_deliver_rcu hands every header to raw6_local_deliver).
            const ext = rp6.walkExt6(info6.next_header, data[payload_start6 .. payload_start6 + info6.payload_len]);
            if (info6.next_header != ext.nh) _ = raw6.deliver6Flow(info6.next_header, data[payload_start6 .. payload_start6 + info6.payload_len], info6.src_ip, info6.dst_ip, ifindex, info6.hop_limit, info6.tclass, info6.flowinfo);
            switch (ext.kind) {
                .deliver => {},
                .drop => return,
                .bad_option => return icmpv6.sendParamProblemAt(pkt6, 2, @intCast(ipv6.HEADER_LEN + ext.off), info6.src_ip, info6.dst_ip),
                .bad_header => return icmpv6.sendParamProblemAt(pkt6, 1, @intCast(ipv6.HEADER_LEN + ext.off), info6.src_ip, info6.dst_ip),
            }
            // ipv6_frag_rcv: a Fragment header after the options joins its reassembly queue (an atomic fragment is delivered with
            // the header taken out); the completed datagram comes back through here.
            if (ext.nh == 44) {
                // raw6_local_deliver sees the Fragment header too: an IPPROTO_FRAGMENT raw socket gets each piece as it arrived.
                const fo: u32 = payload_start6 + @as(u32, @intCast(ext.off));
                _ = raw6.deliver6(44, data[fo .. payload_start6 + info6.payload_len], info6.src_ip, info6.dst_ip, ifindex, info6.hop_limit, info6.tclass);
                @import("ip_frag.zig").receive6(data, len, pkt6, ext.off, ifindex);
                return;
            }
            const up_start: u32 = payload_start6 + @as(u32, @intCast(ext.off));
            const up_len: u16 = info6.payload_len - @as(u16, @intCast(ext.off));
            // raw6_local_deliver: each IPv6 raw socket of the upper-layer header gets it, before the protocol handler.
            const raw_took6 = raw6.deliver6Flow(ext.nh, data[up_start .. up_start + up_len], info6.src_ip, info6.dst_ip, ifindex, info6.hop_limit, info6.tclass, info6.flowinfo);
            switch (ext.nh) {
                ipv6.PROTO_ICMPV6 => {
                    icmpv6.handlePacketMeta(info6.src_ip, info6.dst_ip, data + up_start, up_len, .{ .ifindex = ifindex, .dst = info6.dst_ip, .hops = info6.hop_limit, .tclass = info6.tclass });
                },
                ipv6.PROTO_TCP => {
                    tcp.handlePacketV6(info6.src_ip, info6.dst_ip, data + up_start, up_len, info6.ecn_ce);
                },
                ipv6.PROTO_UDP => {
                    udp.handlePacketV6Meta(info6.src_ip, info6.dst_ip, data + up_start, up_len, ifindex, info6.hop_limit, info6.tclass, info6.flowinfo);
                },
                // ip6_protocol_deliver_rcu: a next header with no handler that no raw socket took gets a parameter problem pointing at
                // the next-header field that named it (the IPv6 header's, or the last extension header's).
                else => if (rp6.paramProblem6(ext.nh, raw_took6)) icmpv6.sendParamProblemAt(pkt6, 1, ext.nh_field, info6.src_ip, info6.dst_ip),
            }
        },
        else => {},
    }
}
