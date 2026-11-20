// kernel/net/icmpv6.zig — ICMPv6 (RFC 4443) + minimal NDP message handling.
//
// Implements:
//   - Echo Request → Echo Reply
//   - Neighbor Solicitation → Neighbor Advertisement
//   - Cache learning from received NS/NA messages.
//
// All ICMPv6 messages must include the IPv6 pseudo-header in their checksum.

const ipo = @import("ip_opt_policy.zig");
const nic = @import("nic.zig");
const netif = @import("netif.zig");
const eth = @import("eth.zig");
const ipv6 = @import("ipv6.zig");
const ipv4 = @import("ipv4.zig");
const ndp = @import("ndp.zig");
const na_policy = @import("ndp_na_policy.zig");
const bo = @import("../lib/byte_order.zig");

// ── ICMPv6 message types (RFC 4443 + RFC 4861) ─────────────────────────────
/// RFC 4443 Packet Too Big (SK-97).
pub const PACKET_TOO_BIG: u8 = 2;
/// RFC 4443 Destination Unreachable (code 4 = port unreachable).
pub const DEST_UNREACHABLE: u8 = 1;
pub const ECHO_REQUEST: u8 = 128;
pub const ECHO_REPLY: u8 = 129;
pub const ROUTER_SOLICITATION: u8 = 133;
pub const ROUTER_ADVERTISEMENT: u8 = 134;
pub const NEIGHBOR_SOLICITATION: u8 = 135;
pub const NEIGHBOR_ADVERTISEMENT: u8 = 136;
pub const REDIRECT: u8 = 137;

/// Every Neighbor Discovery message is sent with hop limit 255 (RFC 4861 §4.1-4.4), so a receiver can tell it was not forwarded;
/// a router or neighbor drops one with any other value (Linux ndisc_rcv, QEMU slirp ndp_input).
pub const NDP_HOP_LIMIT: u8 = 255;

// NDP option types
const OPT_SOURCE_LL_ADDR: u8 = 1;
const OPT_TARGET_LL_ADDR: u8 = 2;
const OPT_PREFIX_INFORMATION: u8 = 3;
/// RFC 4861 §4.6.4 MTU option (SK-102).
const OPT_MTU: u8 = 5;
/// RFC 4191 Route Information Option (SK-94).
const OPT_ROUTE_INFORMATION: u8 = 24;

/// Max Prefix Information options retained from one RA (SK-83).
pub const MAX_RA_PREFIXES: usize = 4;
/// Max Route Information options retained from one RA (SK-94).
pub const MAX_RA_ROUTES: usize = 4;

/// RFC 4861 §4.6.2 Prefix Information option fields.
pub const PrefixInfo = struct {
    prefix: [16]u8 = @splat(0),
    prefix_len: u8 = 0,
    on_link: bool = false,
    autonomous: bool = false,
    valid_lifetime: u32 = 0,
    preferred_lifetime: u32 = 0,
};

/// RFC 4191 Route Information option fields (SK-94).
pub const RouteInfo = struct {
    prefix: [16]u8 = @splat(0),
    prefix_len: u8 = 0,
    /// -1 low, 0 medium, 1 high.
    preference: i8 = 0,
    lifetime_sec: u32 = 0,
};

/// Compute the ICMPv6 checksum over the pseudo-header + ICMPv6 message.
/// `data` points at the start of the ICMPv6 header (with checksum field zeroed).
pub fn checksum(
    src: [16]u8,
    dst: [16]u8,
    data: [*]const u8,
    len: u16,
) u16 {
    var acc: u64 = ipv6.pseudoHeaderChecksum(src, dst, ipv6.PROTO_ICMPV6, len);

    var i: usize = 0;
    while (i + 2 <= len) : (i += 2) {
        acc += (@as(u64, data[i]) << 8) | @as(u64, data[i + 1]);
    }
    if (i < len) {
        acc += @as(u64, data[i]) << 8;
    }

    var sum: u32 = @truncate(acc);
    sum +%= @as(u32, @truncate(acc >> 32));
    sum = (sum & 0xFFFF) + (sum >> 16);
    sum = (sum & 0xFFFF) + (sum >> 16);
    return @truncate(~sum);
}

/// Top-level dispatcher invoked by the IPv6 layer.
pub fn handlePacket(
    src_ip: [16]u8,
    dst_ip: [16]u8,
    data: [*]const u8,
    len: u16,
) void {
    handlePacketMeta(src_ip, dst_ip, data, len, .{ .dst = dst_ip });
}

/// handlePacket for a message that arrived with `meta6` (interface, header destination, hop limit, traffic class): an echo reply's
/// goes to the ping socket for recvmsg's control messages, an echo request's traffic class to the reply.
pub fn handlePacketMeta(src_ip: [16]u8, dst_ip: [16]u8, data: [*]const u8, len: u16, meta6: @import("ip_cmsg_policy.zig").RecvInfo6) void {
    if (len < 8) return;
    // v53.37: Verify ICMPv6 checksum (RFC 4443 §2.3). checksum() returns 0 for valid packets.
    if (checksum(src_ip, dst_ip, data, len) != 0) return;
    // An echo reply is for the IPv6 ping socket whose ident is its id (icmpv6_rcv → ping_rcv).
    if (@import("ping_policy.zig").replyIdent6(data[0..len])) |ident| {
        @import("udp.zig").deliverPing6(ident, src_ip, dst_ip, data[0..len], meta6);
        return;
    }
    const icmp_type = data[0];
    const icmp_code = data[1];

    // An error about a packet this host sent (icmpv6_notify): packet too big first lowers the path MTU (icmpv6_err), an error
    // quoting a TCP segment goes to its connection, and a hard error goes to the connected IPv6 UDP socket that sent the quoted datagram (__udp6_lib_err), or to the connected IPv6 ping
    // socket whose echo request it quotes (ping_err).
    const unreach = @import("icmp_unreach_policy.zig");
    if (unreach.isError6(icmp_type)) {
        if (icmp_type == PACKET_TOO_BIG) handlePacketTooBig(data, len);
        // raw6_icmp_error: every raw socket of the quoted packet's next header (after its extension headers) that sent it. A redirect
        // never gets here (it is type 137, informational).
        if (len >= 8 + 40) {
            const nh0 = data[8 + 6];
            if (unreach.skipExtHdr6(data[8..len], 40, nh0)) |inner| {
                if (8 + inner.off + 8 <= len) @import("raw_icmp.zig").notifyIcmpError6(inner.nh, data[8 + 8 ..][0..16].*, data[8 + 24 ..][0..16].*, icmp_type, icmp_code, bo.readU32BeAt(data, 4), src_ip, data[8..len], data[8 + inner.off .. len]);
            }
        }
        // An error quoting a TCP segment goes to its connection (tcp_v6_err).
        if (unreach.parseTcpQuote6(data[0..len])) |tq| {
            const inner = unreach.skipExtHdr6(data[8..len], 40, data[8 + 6]).?;
            @import("tcp.zig").icmpError6(tq, unreach.tcpErrno6(icmp_type, icmp_code), unreach.tcpReqAborts6(icmp_type, icmp_code), .{
                .icmp_type = icmp_type,
                .icmp_code = icmp_code,
                .info = if (icmp_type == PACKET_TOO_BIG) bo.readU32BeAt(data, 4) else 0,
                .offender = src_ip,
                .l4 = data[8 + inner.off ..][0..8].*,
            });
        }
        const q = unreach.parseErrorQuote6(data[0..len]) orelse return;
        switch (q.kind) {
            // __udp6_lib_err: soft errors too, for a socket with IPV6_RECVERR (it queues them with the quoted payload).
            .udp => {
                const e = unreach.errorFor6(icmp_type, icmp_code) orelse return;
                const inner = unreach.skipExtHdr6(data[8..len], 40, data[8 + 6]) orelse return;
                const quoted = data[0..len][8 + inner.off + 8 ..];
                @import("udp.zig").notifyIcmpError6(.{
                    .errno = e.errno,
                    .hard = e.hard,
                    .icmp_type = icmp_type,
                    .icmp_code = icmp_code,
                    .info = if (icmp_type == PACKET_TOO_BIG) bo.readU32BeAt(data, 4) else 0,
                    .offender = src_ip,
                    .local_port = q.src_port,
                    .peer_port = q.dst_port,
                    .peer_ip = q.dst,
                    .payload = quoted,
                });
            },
            // ping_err: the quoted echo request is queued for a socket with IPV6_RECVERR, soft errors included.
            .echo => {
                const e = unreach.pingErrorFor6(icmp_type, icmp_code);
                const inner = unreach.skipExtHdr6(data[8..len], 40, data[8 + 6]) orelse return;
                @import("udp.zig").notifyPingIcmpError6(q.src_port, .{
                    .errno = e.errno,
                    .hard = e.hard,
                    .icmp_type = icmp_type,
                    .icmp_code = icmp_code,
                    .info = if (icmp_type == PACKET_TOO_BIG) bo.readU32BeAt(data, 4) else 0,
                    .offender = src_ip,
                    .local_port = q.src_port,
                    .peer_port = 0,
                    .peer_ip = q.dst,
                    .payload = data[0..len][8 + inner.off ..],
                }, true);
            },
        }
        return;
    }

    switch (icmp_type) {
        ECHO_REQUEST => sendEchoReply(src_ip, dst_ip, data, len, meta6.tclass),
        ROUTER_ADVERTISEMENT => handleRouterAdvertisement(src_ip, data, len),
        NEIGHBOR_SOLICITATION => handleNeighborSolicitation(src_ip, dst_ip, data, len),
        NEIGHBOR_ADVERTISEMENT => handleNeighborAdvertisement(src_ip, data, len),
        REDIRECT => handleRedirect(src_ip, data, len),
        else => {},
    }
}

/// Parsed Packet Too Big (RFC 4443 §3.2) (SK-97).
pub const PacketTooBigMsg = struct {
    mtu: u32 = 0,
    /// Destination of the invoking IPv6 packet (PMTU cache key).
    dst: [16]u8 = @splat(0),
};

/// Pure PTB parser: needs ICMP header + invoking IPv6 header.
pub fn parsePacketTooBig(data: [*]const u8, len: u16) ?PacketTooBigMsg {
    if (len < 8 + ipv6.HEADER_LEN) return null;
    if (data[0] != PACKET_TOO_BIG or data[1] != 0) return null;
    const inv = ipv6.parseHeader(data + 8) orelse return null;
    return .{
        .mtu = bo.readU32BeAt(data, 4),
        .dst = inv.dst_ip,
    };
}

fn handlePacketTooBig(data: [*]const u8, len: u16) void {
    const msg = parsePacketTooBig(data, len) orelse return;
    if (ipv6.isMulticast(msg.dst) or ipv6.isUnspecified(msg.dst)) return;
    ipv6.updatePathMtu(msg.dst, msg.mtu);
}

/// Parsed Redirect (RFC 4861 §4.5) (SK-95).
pub const RedirectMsg = struct {
    target: [16]u8 = @splat(0),
    destination: [16]u8 = @splat(0),
    target_ll: ?[6]u8 = null,
};

/// Pure Redirect parser. Requires the 40-byte Redirect body.
pub fn parseRedirect(data: [*]const u8, len: u16) ?RedirectMsg {
    if (len < 40) return null;
    if (data[0] != REDIRECT or data[1] != 0) return null;
    var msg: RedirectMsg = .{};
    @memcpy(&msg.target, data[8..24]);
    @memcpy(&msg.destination, data[24..40]);
    var off: u16 = 40;
    while (off + 2 <= len) {
        const opt_type = data[off];
        const opt_units = data[off + 1];
        if (opt_units == 0) break;
        const opt_len: u16 = @as(u16, opt_units) * 8;
        if (off + opt_len > len) break;
        if (opt_type == OPT_TARGET_LL_ADDR and opt_len >= 8) {
            msg.target_ll = .{
                data[off + 2], data[off + 3], data[off + 4],
                data[off + 5], data[off + 6], data[off + 7],
            };
        }
        off += opt_len;
    }
    return msg;
}

fn handleRedirect(src_ip: [16]u8, data: [*]const u8, len: u16) void {
    // RFC 4861 §8.1 host validation (subset).
    if (!ipv6.isLinkLocal(src_ip)) return;
    const msg = parseRedirect(data, len) orelse return;
    if (ipv6.isMulticast(msg.destination)) return;
    const on_link = ipv6.addrEq(msg.target, msg.destination);
    if (!on_link and !ipv6.isLinkLocal(msg.target)) return;
    if (!ndp.isCurrentFirstHop(msg.destination, src_ip)) return;
    ndp.applyRedirect(msg.destination, msg.target);
    if (msg.target_ll) |mac| {
        ndp.update(msg.target, mac);
    }
}

/// Parsed Router Advertisement fields (SK-82/83/94).
pub const RouterAdvert = struct {
    hop_limit: u8 = 0,
    router_lifetime_sec: u16 = 0,
    reachable_ms: u32 = 0,
    retrans_ms: u32 = 0,
    source_ll: ?[6]u8 = null,
    /// RA MTU option value when present (SK-102).
    mtu: ?u32 = null,
    prefixes: [MAX_RA_PREFIXES]PrefixInfo = @splat(.{}),
    prefix_count: u8 = 0,
    routes: [MAX_RA_ROUTES]RouteInfo = @splat(.{}),
    route_count: u8 = 0,
};

/// Pure RA parser (RFC 4861 §4.2). Requires at least the 16-byte RA header.
pub fn parseRouterAdvertisement(data: [*]const u8, len: u16) ?RouterAdvert {
    if (len < 16) return null;
    if (data[0] != ROUTER_ADVERTISEMENT or data[1] != 0) return null;
    var adv: RouterAdvert = .{
        .hop_limit = data[4],
        .router_lifetime_sec = bo.readU16BeAt(data, 6),
        .reachable_ms = bo.readU32BeAt(data, 8),
        .retrans_ms = bo.readU32BeAt(data, 12),
    };
    var off: u16 = 16;
    while (off + 2 <= len) {
        const opt_type = data[off];
        const opt_units = data[off + 1];
        if (opt_units == 0) break;
        const opt_len: u16 = @as(u16, opt_units) * 8;
        if (off + opt_len > len) break;
        if (opt_type == OPT_SOURCE_LL_ADDR and opt_len >= 8) {
            adv.source_ll = .{
                data[off + 2], data[off + 3], data[off + 4],
                data[off + 5], data[off + 6], data[off + 7],
            };
        } else if (opt_type == OPT_MTU and opt_len >= 8) {
            // type(1)+len(1)+reserved(2)+mtu(4)
            adv.mtu = bo.readU32BeAt(data, off + 4);
        } else if (opt_type == OPT_PREFIX_INFORMATION and opt_len >= 32) {
            // type(1)+len(1)+prefix_len(1)+flags(1)+valid(4)+pref(4)+reserved(4)+prefix(16)
            if (adv.prefix_count < MAX_RA_PREFIXES) {
                const flags = data[off + 3];
                var pfx: [16]u8 = undefined;
                @memcpy(&pfx, data[off + 16 .. off + 32]);
                adv.prefixes[adv.prefix_count] = .{
                    .prefix = pfx,
                    .prefix_len = data[off + 2],
                    .on_link = (flags & 0x80) != 0,
                    .autonomous = (flags & 0x40) != 0,
                    .valid_lifetime = bo.readU32BeAt(data, off + 4),
                    .preferred_lifetime = bo.readU32BeAt(data, off + 8),
                };
                adv.prefix_count += 1;
            }
        } else if (opt_type == OPT_ROUTE_INFORMATION and opt_units >= 1 and opt_units <= 3) {
            // type(1)+len(1)+prefix_len(1)+flags(1)+lifetime(4)+prefix(0/8/16)
            const prf_bits: u8 = (data[off + 3] >> 3) & 0x3;
            if (prf_bits != 0b10 and adv.route_count < MAX_RA_ROUTES) {
                const preference: i8 = switch (prf_bits) {
                    0b01 => 1,
                    0b11 => -1,
                    else => 0,
                };
                var pfx: [16]u8 = @splat(0);
                if (opt_units >= 2) @memcpy(pfx[0..8], data[off + 8 .. off + 16]);
                if (opt_units >= 3) @memcpy(pfx[8..16], data[off + 16 .. off + 24]);
                adv.routes[adv.route_count] = .{
                    .prefix = pfx,
                    .prefix_len = data[off + 2],
                    .preference = preference,
                    .lifetime_sec = bo.readU32BeAt(data, off + 4),
                };
                adv.route_count += 1;
            }
        }
        off += opt_len;
    }
    return adv;
}

fn handleRouterAdvertisement(src_ip: [16]u8, data: [*]const u8, len: u16) void {
    const adv = parseRouterAdvertisement(data, len) orelse return;
    if (adv.source_ll) |mac| {
        if (!ipv6.isUnspecified(src_ip)) ndp.update(src_ip, mac);
    }
    ndp.setDefaultRouter(src_ip, adv.router_lifetime_sec);
    // SK-88: a usable RA ends the solicitation burst.
    if (adv.router_lifetime_sec != 0) stopRouterSolicit();
    // SK-102: RA MTU option lowers/raises the interface MTU (≥ IPv6 minimum).
    if (adv.mtu) |m| {
        if (m >= ipv6.MIN_MTU) netif.setMtu(m);
    }
    const our_mac = netif.getMac();
    var i: u8 = 0;
    while (i < adv.prefix_count) : (i += 1) {
        const p = adv.prefixes[i];
        ndp.setPrefix(p.prefix, p.prefix_len, p.on_link, p.autonomous, p.valid_lifetime);
        // SK-84/85: A-flag /64 → tentative SLAAC + DAD NS.
        if (p.autonomous) {
            if (ndp.installSlaac(p.prefix, p.prefix_len, p.valid_lifetime, p.preferred_lifetime, our_mac)) |tentative| {
                sendDadNeighborSolicitation(tentative);
            }
        }
    }
    // SK-94: Route Information → more-specific off-link next hops.
    var ri: u8 = 0;
    while (ri < adv.route_count) : (ri += 1) {
        const r = adv.routes[ri];
        ndp.setRoute(r.prefix, r.prefix_len, r.lifetime_sec, r.preference, src_ip);
    }
}

/// Echo Reply: copy the request body, swap addresses, recompute checksum.
pub fn sendEchoReply(
    requester_ip: [16]u8,
    our_ip_in: [16]u8,
    data: [*]const u8,
    len: u16,
    tclass: u8,
) void {
    if (len < 8) return;

    const our_mac = netif.getMac();
    // A requester on this host (::1 or one of its own addresses) is answered over lo, like any datagram to it; elsewhere the reply
    // needs the requester's MAC.
    const via_lo = netif.isLoopbackV6(requester_ip) or ndp.isOwnAddress(requester_ip, our_mac);
    const dst_mac = if (via_lo) our_mac else ndp.lookup(requester_ip) orelse return;
    const our_ip = our_ip_in; // reply from the address we received it on
    // A reassembled request longer than one frame is echoed whole, in fragments (icmpv6_echo_reply → ip6_append_data).
    const mtu = ipv6.getSendMtu(requester_ip);
    if (@as(usize, len) + ipv6.HEADER_LEN > mtu) return sendBigEchoReply6(requester_ip, our_ip, data[0..len], tclass, mtu, dst_mac, our_mac, via_lo);

    // A whole frame: the request may fill the MTU now that the 1280-byte cut is gone.
    var pkt: [1518]u8 = undefined;
    const eth_len: u16 = 14;
    const ip_off: u16 = eth_len;
    const icmp_off: u16 = eth_len + ipv6.HEADER_LEN;

    // Copy the entire ICMPv6 message (type/code/checksum/body) then patch.
    @memcpy(pkt[icmp_off .. icmp_off + len], data[0..len]);
    pkt[icmp_off + 0] = ECHO_REPLY;
    pkt[icmp_off + 1] = 0; // code
    pkt[icmp_off + 2] = 0; // checksum hi (cleared)
    pkt[icmp_off + 3] = 0; // checksum lo (cleared)

    ipv6.buildHeader(pkt[ip_off..].ptr, our_ip, requester_ip, ipv6.PROTO_ICMPV6, len);
    // The reply keeps the request's traffic class (icmpv6_echo_reply: ipc6.tclass = ipv6_get_dsfield).
    pkt[ip_off] = 0x60 | (tclass >> 4);
    pkt[ip_off + 1] = (pkt[ip_off + 1] & 0x0F) | (tclass << 4);

    const csum = checksum(our_ip, requester_ip, pkt[icmp_off..].ptr, len);
    bo.writeU16BeAt(&pkt, icmp_off + 2, csum);

    const frame_len = eth.buildFrame(&pkt, dst_mac, our_mac, eth.ETHERTYPE_IPV6, ipv6.HEADER_LEN + len);
    if (via_lo) _ = @import("lo.zig").sendPacket(&pkt, frame_len) else _ = nic.sendPacket(&pkt, frame_len);
}

/// sendEchoReply for a request longer than the MTU: the reply is built in a kmalloc buffer and fragmented behind Fragment headers.
fn sendBigEchoReply6(requester_ip: [16]u8, our_ip: [16]u8, req: []const u8, tclass: u8, mtu: u16, dst_mac: [6]u8, our_mac: [6]u8, via_lo: bool) void {
    const slab = @import("../mm/slab.zig");
    const raw = slab.kmalloc(req.len) orelse return;
    defer slab.kfree(raw);
    const msg = @as([*]u8, @ptrCast(raw))[0..req.len];
    @memcpy(msg, req);
    msg[0] = ECHO_REPLY;
    msg[1] = 0;
    msg[2] = 0;
    msg[3] = 0;
    bo.writeU16BeAt(msg.ptr, 2, checksum(our_ip, requester_ip, msg.ptr, @intCast(msg.len)));
    var hdr: [40]u8 = undefined;
    ipv6.buildHeader(&hdr, our_ip, requester_ip, ipv6.PROTO_ICMPV6, 0);
    hdr[0] = 0x60 | (tclass >> 4);
    hdr[1] = (hdr[1] & 0x0F) | (tclass << 4);
    _ = @import("ip_frag.zig").send6(hdr, ipv6.PROTO_ICMPV6, msg, mtu, dst_mac, our_mac, via_lo, null);
}

/// Send the ICMPv6 message `msg` (header and data; the checksum is computed here over the pseudo-header) from an IPv6 ping socket
/// bound to `bound` (:: when unbound) to `dst`: routed like an IPv6 UDP datagram (lo for ::1 and this host's addresses, else the
/// next hop's MAC; while that is being solicited the frame waits in ndp_queue and the send succeeds, as Linux queues it on the
/// neighbour). Returns 0, or -EMSGSIZE past the path MTU, -ENETUNREACH with no route, -ENOBUFS when the device drops it.
pub fn sendFrom6(bound: [16]u8, dst: [16]u8, msg: []u8, ip: ipo.IpOpts) i64 {
    return sendProto6(bound, dst, ipv6.PROTO_ICMPV6, 2, msg, ip);
}

/// sendFrom6 for a message of next header `next_header` (an IPv6 raw socket of that protocol): the kernel writes the RFC 2460 checksum at
/// `csum_off` when there is one (rawv6_push_pending_frames, the two bytes there count as zero), else `msg` goes out as given.
pub fn sendProto6(bound: [16]u8, dst: [16]u8, next_header: u8, csum_off: ?u32, msg: []u8, ip: ipo.IpOpts) i64 {
    return sendProto6Ov(bound, dst, next_header, csum_off, msg, ip, null, null);
}

/// sendProto6 with the hop limit and traffic class of this one packet given (an IPV6_HOPLIMIT / IPV6_TCLASS control message; null
/// keeps the socket's value). They are written into the IPv6 header after the socket's options.
pub fn sendProto6Ov(bound: [16]u8, dst: [16]u8, next_header: u8, csum_off: ?u32, msg: []u8, ip: ipo.IpOpts, hops_ov: ?u8, tclass_ov: ?u8) i64 {
    const mtu = ipv6.getSendMtu(dst);
    const orc = @import("raw_icmp_policy.zig").oversizeErrno6Df(msg.len, mtu, ip.pmtudisc6, ip.dontfrag6);
    if (orc != 0) return orc;
    const our_mac = netif.getMac();
    const via_lo = netif.isLoopbackV6(dst) or ndp.isOwnAddress(dst, our_mac);
    var wait_hop: ?[16]u8 = null;
    const dst_mac = if (via_lo) our_mac else resolve: {
        const nh = ndp.resolveNextHop(dst);
        break :resolve nh.mac orelse blk: {
            const t = nh.solicit orelse return -101; // ENETUNREACH: no route
            sendNeighborSolicitation(t);
            wait_hop = t;
            break :blk [6]u8{ 0, 0, 0, 0, 0, 0 };
        };
    };
    const src = @import("tcp_port_policy.zig").sourceAddr6(bound, dst, if (via_lo) dst else ndp.selectSourceAddress(dst, our_mac));
    if (csum_off) |off| {
        const rp = @import("raw_icmp_policy.zig");
        msg[off] = 0;
        msg[off + 1] = 0;
        const csum = rp.finishSum6(rp.sum6(src, dst, next_header, msg), next_header);
        msg[off] = @truncate(csum >> 8);
        msg[off + 1] = @truncate(csum);
    }
    if (msg.len + ipv6.HEADER_LEN > mtu) {
        // ip6_append_data → ip6_fragment: the packet leaves in pieces behind Fragment headers.
        var hdr: [40]u8 = undefined;
        ipv6.buildHeader(&hdr, src, dst, next_header, 0);
        if (ipo.ipv6NeedsPatch(ip)) ipo.patchIpv6(&hdr, ip);
        if (hops_ov) |h| hdr[7] = h;
        if (tclass_ov) |tc| {
            hdr[0] = (hdr[0] & 0xF0) | (tc >> 4);
            hdr[1] = (hdr[1] & 0x0F) | (tc << 4);
        }
        return if (@import("ip_frag.zig").send6(hdr, next_header, msg, mtu, dst_mac, our_mac, via_lo, wait_hop)) 0 else -105;
    }
    var pkt: [1518]u8 = @splat(0);
    const icmp_off: usize = 14 + ipv6.HEADER_LEN;
    @memcpy(pkt[icmp_off..][0..msg.len], msg);
    ipv6.buildHeader(pkt[14..].ptr, src, dst, next_header, @intCast(msg.len));
    if (ipo.ipv6NeedsPatch(ip)) ipo.patchIpv6(pkt[14..][0..40], ip);
    if (hops_ov) |h| pkt[14 + 7] = h;
    if (tclass_ov) |tc| {
        pkt[14] = (pkt[14] & 0xF0) | (tc >> 4);
        pkt[15] = (pkt[15] & 0x0F) | (tc << 4);
    }
    const frame_len = eth.buildFrame(&pkt, dst_mac, our_mac, eth.ETHERTYPE_IPV6, @intCast(ipv6.HEADER_LEN + msg.len));
    if (wait_hop) |hop| {
        @import("ndp_queue.zig").queueFrame(hop, &pkt, frame_len);
        return 0;
    }
    const lo = @import("lo.zig");
    const ok = if (via_lo) lo.sendPacket(&pkt, frame_len) or lo.dropIsLoss(frame_len) else nic.sendPacket(&pkt, frame_len);
    return if (ok) 0 else -105;
}

/// An IPV6_HDRINCL send: `pkt` (IPv6 header first, at most 1500 bytes) goes out as written, routed by `dst` like sendProto6
/// (rawv6_send_hdrinc fills in nothing). Returns 0, or -ENETUNREACH with no route, -ENOBUFS when the device drops it.
pub fn sendHdrincl6(dst: [16]u8, pkt: []const u8) i64 {
    const our_mac = netif.getMac();
    const via_lo = netif.isLoopbackV6(dst) or ndp.isOwnAddress(dst, our_mac);
    var wait_hop: ?[16]u8 = null;
    const dst_mac = if (via_lo) our_mac else resolve: {
        const hop = ndp.resolveNextHop(dst);
        break :resolve hop.mac orelse blk: {
            const t = hop.solicit orelse return -101;
            sendNeighborSolicitation(t);
            wait_hop = t;
            break :blk [6]u8{ 0, 0, 0, 0, 0, 0 };
        };
    };
    var frame: [1518]u8 = @splat(0);
    if (pkt.len > frame.len - 14) return -90;
    @memcpy(frame[14..][0..pkt.len], pkt);
    const frame_len = eth.buildFrame(&frame, dst_mac, our_mac, eth.ETHERTYPE_IPV6, @intCast(pkt.len));
    if (wait_hop) |hop| {
        @import("ndp_queue.zig").queueFrame(hop, &frame, frame_len);
        return 0;
    }
    const lo = @import("lo.zig");
    const ok = if (via_lo) lo.sendPacket(&frame, frame_len) or lo.dropIsLoss(frame_len) else nic.sendPacket(&frame, frame_len);
    return if (ok) 0 else -105;
}

/// ICMPv6 parameter problem, unrecognized next header (ip6_protocol_deliver_rcu → icmpv6_send): `pkt` is the offending packet,
/// IPv6 header first, `src` → `dst`. Like the port unreachable for UDP, only a ::1 → ::1 packet is answered (over lo).
pub fn sendParamProblem(pkt: []const u8, src: [16]u8, dst: [16]u8) void {
    sendParamProblemAt(pkt, 1, 6, src, dst);
}

/// sendParamProblem with any code and pointer (icmpv6_param_prob: a bad header field, an unknown next header, an unknown option).
pub fn sendParamProblemAt(pkt: []const u8, code: u8, pointer: u32, src: [16]u8, dst: [16]u8) void {
    if (!@import("icmp_unreach_policy.zig").shouldReplyV6(netif.isLoopbackV6(src), netif.isLoopbackV6(dst), false)) return;
    const rp = @import("raw_icmp_policy.zig");
    var msg: [rp.PARAM_PROBLEM_MAX]u8 = undefined;
    const n = rp.paramProblemMsgAt(&msg, pkt, code, pointer);
    var frame: [14 + 40 + rp.PARAM_PROBLEM_MAX]u8 = @splat(0);
    @memcpy(frame[54..][0..n], msg[0..n]);
    bo.writeU16BeAt(&frame, 56, checksum(dst, src, frame[54..].ptr, @intCast(n)));
    ipv6.buildHeader(frame[14..].ptr, dst, src, ipv6.PROTO_ICMPV6, @intCast(n));
    const mac = netif.getMac();
    const frame_len = eth.buildFrame(&frame, mac, mac, eth.ETHERTYPE_IPV6, @intCast(40 + n));
    _ = @import("lo.zig").sendPacket(&frame, frame_len);
}

fn handleNeighborSolicitation(
    src_ip: [16]u8,
    dst_ip: [16]u8,
    data: [*]const u8,
    len: u16,
) void {
    // NS layout: type(1)+code(1)+csum(2)+reserved(4)+target(16)+options
    if (len < 24) return;
    _ = dst_ip;

    var target: [16]u8 = undefined;
    inline for (0..16) |i| target[i] = data[8 + i];

    // SK-85: NS for our tentative address ⇒ DAD conflict (RFC 4862 §5.4.3).
    if (ndp.isTentative(target)) {
        ndp.dadConflict(target);
        return;
    }

    // Learn sender MAC from Source Link-Layer Address option, if present.
    var off: u16 = 24;
    while (off + 2 <= len) {
        const opt_type = data[off];
        const opt_units = data[off + 1];
        if (opt_units == 0) break;
        const opt_len: u16 = @as(u16, opt_units) * 8;
        if (off + opt_len > len) break;
        if (opt_type == OPT_SOURCE_LL_ADDR and opt_len >= 8) {
            const sender_mac: [6]u8 = .{
                data[off + 2], data[off + 3], data[off + 4],
                data[off + 5], data[off + 6], data[off + 7],
            };
            if (!ipv6.isUnspecified(src_ip)) ndp.update(src_ip, sender_mac);
        }
        off += opt_len;
    }

    // Only respond if the target is one of our addresses (not tentative — handled above).
    const our_mac = netif.getMac();
    const our_ll = ndp.generateLinkLocal(our_mac);
    if (!ipv6.addrEq(target, our_ll) and !ndp.hasLocalAddress(target)) return;

    sendNeighborAdvertisement(src_ip, target, true); // v53.37: solicited NA — set S flag (W1 fix, RFC 4861 §7.2.4)
}

fn handleNeighborAdvertisement(src_ip: [16]u8, data: [*]const u8, len: u16) void {
    // NA layout: type(1)+code(1)+csum(2)+flags(4)+target(16)+options
    if (len < 24) return;
    _ = src_ip;

    var target: [16]u8 = undefined;
    inline for (0..16) |i| target[i] = data[8 + i];

    // SK-85: NA claiming our tentative target ⇒ DAD conflict.
    if (ndp.isTentative(target)) {
        ndp.dadConflict(target);
        return;
    }

    var tlla: ?[6]u8 = null;
    var off: u16 = 24;
    while (off + 2 <= len) {
        const opt_type = data[off];
        const opt_units = data[off + 1];
        if (opt_units == 0) break;
        const opt_len: u16 = @as(u16, opt_units) * 8;
        if (off + opt_len > len) break;
        if (opt_type == OPT_TARGET_LL_ADDR and opt_len >= 8) {
            tlla = .{
                data[off + 2], data[off + 3], data[off + 4],
                data[off + 5], data[off + 6], data[off + 7],
            };
            break;
        }
        off += opt_len;
    }

    // RFC 4861 §7.2.5: honour the S/O flags instead of overwriting blindly.
    const na = na_policy.parseFlags(data[4], tlla);
    if (!na.solicited) return;
    const state: na_policy.EntryState = if (ndp.probeState(target)) |s| switch (s) {
        .incomplete => .incomplete,
        .reachable => .reachable,
        .stale => .stale,
        .delay => .delay,
        .probe => .probe,
    } else .none;
    const needs_cached = state != .none and state != .incomplete;
    const cached: ?[6]u8 = if (needs_cached) ndp.lookup(target) else null;
    if (na_policy.decide(state, na, cached)) |mac| ndp.update(target, mac);
}

/// Build a Neighbor Advertisement frame into `out`, claiming `target` is at
/// `our_mac`, destined for `dst_mac`. Pure: caller supplies both MACs, no
/// ndp/netif/nic side effects — arch-clean and testable in isolation.
/// Returns the total ethernet frame length.
pub fn buildNeighborAdvertisement(
    out: [*]u8,
    requester_ip: [16]u8,
    target: [16]u8,
    our_mac: [6]u8,
    dst_mac: [6]u8,
    solicited: bool,
) u16 {
    // ICMPv6 NA = 24 bytes header + 8-byte Target LL Addr option = 32 bytes
    const icmp_len: u16 = 32;
    const total_payload: u16 = ipv6.HEADER_LEN + icmp_len;
    const eth_len: u16 = 14;
    const ip_off: u16 = eth_len;
    const icmp_off: u16 = eth_len + ipv6.HEADER_LEN;

    // ICMPv6 NA fields
    out[icmp_off + 0] = NEIGHBOR_ADVERTISEMENT;
    out[icmp_off + 1] = 0; // code
    out[icmp_off + 2] = 0; // checksum (filled below)
    out[icmp_off + 3] = 0;

    // Flags: R=0, S=solicited, O=1 (override).
    var flags: u8 = 0x20; // O bit
    if (solicited) flags |= 0x40; // S bit
    out[icmp_off + 4] = flags;
    out[icmp_off + 5] = 0;
    out[icmp_off + 6] = 0;
    out[icmp_off + 7] = 0;

    // Target address
    @memcpy(out[icmp_off + 8 .. icmp_off + 24], &target);

    // Target Link-Layer Address option (type=2, len=1 unit=8 bytes)
    out[icmp_off + 24] = OPT_TARGET_LL_ADDR;
    out[icmp_off + 25] = 1;
    @memcpy(out[icmp_off + 26 .. icmp_off + 32], &our_mac);

    ipv6.buildHeader(out + ip_off, target, requester_ip, ipv6.PROTO_ICMPV6, icmp_len);
    out[ip_off + 7] = NDP_HOP_LIMIT;

    const csum = checksum(target, requester_ip, out + icmp_off, icmp_len);
    bo.writeU16BeAt(out, icmp_off + 2, csum);

    return eth.buildFrame(out, dst_mac, our_mac, eth.ETHERTYPE_IPV6, total_payload);
}

/// Send a Neighbor Advertisement to `requester_ip` claiming `target` is at our MAC.
/// `solicited` indicates whether this NA is in response to an NS (sets S flag).
pub fn sendNeighborAdvertisement(
    requester_ip: [16]u8,
    target: [16]u8,
    solicited: bool,
) void {
    const dst_mac = ndp.lookup(requester_ip) orelse return;
    const our_mac = netif.getMac();

    var pkt: [128]u8 = @splat(0);
    const frame_len = buildNeighborAdvertisement(&pkt, requester_ip, target, our_mac, dst_mac, solicited);
    _ = nic.sendPacket(&pkt, frame_len);
}

fn fillNeighborSolicitationBody(out: [*]u8, icmp_off: u16, target: [16]u8, our_mac: [6]u8) void {
    out[icmp_off + 0] = NEIGHBOR_SOLICITATION;
    out[icmp_off + 1] = 0; // code
    out[icmp_off + 2] = 0; // checksum
    out[icmp_off + 3] = 0;
    out[icmp_off + 4] = 0; // reserved
    out[icmp_off + 5] = 0;
    out[icmp_off + 6] = 0;
    out[icmp_off + 7] = 0;
    @memcpy(out[icmp_off + 8 .. icmp_off + 24], &target);
    // Source Link-Layer Address option (type=1, len=1 unit=8 bytes)
    out[icmp_off + 24] = OPT_SOURCE_LL_ADDR;
    out[icmp_off + 25] = 1;
    @memcpy(out[icmp_off + 26 .. icmp_off + 32], &our_mac);
}

fn buildNsFrame(
    out: [*]u8,
    our_ip: [16]u8,
    target: [16]u8,
    our_mac: [6]u8,
    dst_ip: [16]u8,
    dst_mac: [6]u8,
) u16 {
    const icmp_len: u16 = 32;
    const total_payload: u16 = ipv6.HEADER_LEN + icmp_len;
    const icmp_off: u16 = 14 + ipv6.HEADER_LEN;
    fillNeighborSolicitationBody(out, icmp_off, target, our_mac);
    ipv6.buildHeader(out + 14, our_ip, dst_ip, ipv6.PROTO_ICMPV6, icmp_len);
    out[14 + 7] = NDP_HOP_LIMIT;
    const csum = checksum(our_ip, dst_ip, out + icmp_off, icmp_len);
    bo.writeU16BeAt(out, icmp_off + 2, csum);
    return eth.buildFrame(out, dst_mac, our_mac, eth.ETHERTYPE_IPV6, total_payload);
}

/// Build a Neighbor Solicitation for `target` into `out`.
/// Destined to the solicited-node multicast of `target` (L3 + L2).
/// Pure: no ndp/netif/nic side effects. Returns ethernet frame length.
pub fn buildNeighborSolicitation(
    out: [*]u8,
    our_ip: [16]u8,
    target: [16]u8,
    our_mac: [6]u8,
) u16 {
    const dst_ip = ipv6.solicitedNodeMulticast(target);
    return buildNsFrame(out, our_ip, target, our_mac, dst_ip, ipv6.multicastMac(dst_ip));
}

/// Build a unicast Neighbor Solicitation (SK-81 NUD PROBE).
/// L3/L2 destined to the cached neighbor address/MAC.
pub fn buildNeighborSolicitationUnicast(
    out: [*]u8,
    our_ip: [16]u8,
    target: [16]u8,
    our_mac: [6]u8,
    dst_mac: [6]u8,
) u16 {
    return buildNsFrame(out, our_ip, target, our_mac, target, dst_mac);
}

/// Transmit an NS for `target` (ARP-request analogue). Caller usually
/// `markIncomplete` first; this only builds and sends the frame.
pub fn sendNeighborSolicitation(target: [16]u8) void {
    const our_mac = netif.getMac();
    const our_ip = ndp.generateLinkLocal(our_mac);
    var pkt: [128]u8 = @splat(0);
    const frame_len = buildNeighborSolicitation(&pkt, our_ip, target, our_mac);
    _ = nic.sendPacket(&pkt, frame_len);
}

/// Transmit a unicast NS for NUD PROBE (SK-81).
pub fn sendNeighborSolicitationUnicast(target: [16]u8, dst_mac: [6]u8) void {
    const our_mac = netif.getMac();
    const our_ip = ndp.generateLinkLocal(our_mac);
    var pkt: [128]u8 = @splat(0);
    const frame_len = buildNeighborSolicitationUnicast(&pkt, our_ip, target, our_mac, dst_mac);
    _ = nic.sendPacket(&pkt, frame_len);
}

/// Build a Router Solicitation to all-routers (ff02::2) with Source LL (SK-82).
/// Pure: no ndp/netif/nic side effects. Returns ethernet frame length.
pub fn buildRouterSolicitation(
    out: [*]u8,
    our_ip: [16]u8,
    our_mac: [6]u8,
) u16 {
    // ICMPv6 RS = 8-byte header + 8-byte Source LL = 16 bytes
    const icmp_len: u16 = 16;
    const total_payload: u16 = ipv6.HEADER_LEN + icmp_len;
    const icmp_off: u16 = 14 + ipv6.HEADER_LEN;
    const dst_ip = ipv6.allRoutersLinkLocalMulticast();
    const dst_mac = ipv6.multicastMac(dst_ip);

    out[icmp_off + 0] = ROUTER_SOLICITATION;
    out[icmp_off + 1] = 0; // code
    out[icmp_off + 2] = 0; // checksum
    out[icmp_off + 3] = 0;
    out[icmp_off + 4] = 0; // reserved
    out[icmp_off + 5] = 0;
    out[icmp_off + 6] = 0;
    out[icmp_off + 7] = 0;
    out[icmp_off + 8] = OPT_SOURCE_LL_ADDR;
    out[icmp_off + 9] = 1;
    @memcpy(out[icmp_off + 10 .. icmp_off + 16], &our_mac);

    ipv6.buildHeader(out + 14, our_ip, dst_ip, ipv6.PROTO_ICMPV6, icmp_len);
    out[14 + 7] = NDP_HOP_LIMIT;
    const csum = checksum(our_ip, dst_ip, out + icmp_off, icmp_len);
    bo.writeU16BeAt(out, icmp_off + 2, csum);
    return eth.buildFrame(out, dst_mac, our_mac, eth.ETHERTYPE_IPV6, total_payload);
}

/// Transmit a Router Solicitation (SK-82).
pub fn sendRouterSolicitation() void {
    const our_mac = netif.getMac();
    const our_ip = ndp.generateLinkLocal(our_mac);
    var pkt: [128]u8 = @splat(0);
    const frame_len = buildRouterSolicitation(&pkt, our_ip, our_mac);
    _ = nic.sendPacket(&pkt, frame_len);
}

// ── SK-88: automatic Router Solicitation (RFC 4861 §6.3.7) ───────────────
/// MAX_RTR_SOLICITATIONS
pub const MAX_RTR_SOLICITATIONS: u8 = 3;
/// RTR_SOLICITATION_INTERVAL (ms)
pub const RTR_SOLICITATION_INTERVAL_MS: u32 = 4_000;

var rs_active: bool = false;
var rs_sent: u8 = 0;
var rs_ms: u32 = 0;

/// Begin router discovery: send the first RS immediately (SK-88).
pub fn startRouterSolicit() void {
    rs_active = true;
    rs_sent = 0;
    rs_ms = 0;
    sendRouterSolicitation();
    rs_sent = 1;
}

/// Stop router discovery early (e.g. after a usable RA) (SK-88).
pub fn stopRouterSolicit() void {
    rs_active = false;
}

/// Probe helper (SK-88).
pub fn probeRsActive() bool {
    return rs_active;
}

/// Probe helper (SK-88): RS transmissions in the current discovery round.
pub fn probeRsSent() u8 {
    return rs_sent;
}

/// Advance RS retransmit timer (SK-88). Stops when a default router appears
/// or `MAX_RTR_SOLICITATIONS` have been sent.
pub fn routerSolicitTimerTick(ms_elapsed: u32) void {
    if (!rs_active) return;
    if (ndp.getDefaultRouter() != null) {
        rs_active = false;
        return;
    }
    if (rs_sent >= MAX_RTR_SOLICITATIONS) {
        rs_active = false;
        return;
    }
    if (ms_elapsed == 0) return;
    rs_ms +%= ms_elapsed;
    if (rs_ms < RTR_SOLICITATION_INTERVAL_MS) return;
    rs_ms = 0;
    sendRouterSolicitation();
    rs_sent +%= 1;
    if (rs_sent >= MAX_RTR_SOLICITATIONS) rs_active = false;
}

/// Build a DAD Neighbor Solicitation (RFC 4862 §5.4.2): src=::, no SLLA (SK-85).
pub fn buildDadNeighborSolicitation(out: [*]u8, target: [16]u8, our_mac: [6]u8) u16 {
    const icmp_len: u16 = 24; // header only — no Source LL option
    const total_payload: u16 = ipv6.HEADER_LEN + icmp_len;
    const icmp_off: u16 = 14 + ipv6.HEADER_LEN;
    const src_ip = [_]u8{0} ** 16;
    const dst_ip = ipv6.solicitedNodeMulticast(target);
    const dst_mac = ipv6.multicastMac(dst_ip);

    out[icmp_off + 0] = NEIGHBOR_SOLICITATION;
    out[icmp_off + 1] = 0;
    out[icmp_off + 2] = 0;
    out[icmp_off + 3] = 0;
    out[icmp_off + 4] = 0;
    out[icmp_off + 5] = 0;
    out[icmp_off + 6] = 0;
    out[icmp_off + 7] = 0;
    @memcpy(out[icmp_off + 8 .. icmp_off + 24], &target);

    ipv6.buildHeader(out + 14, src_ip, dst_ip, ipv6.PROTO_ICMPV6, icmp_len);
    out[14 + 7] = NDP_HOP_LIMIT;
    const csum = checksum(src_ip, dst_ip, out + icmp_off, icmp_len);
    bo.writeU16BeAt(out, icmp_off + 2, csum);
    return eth.buildFrame(out, dst_mac, our_mac, eth.ETHERTYPE_IPV6, total_payload);
}

/// Transmit a DAD NS for a tentative address (SK-85).
pub fn sendDadNeighborSolicitation(target: [16]u8) void {
    const our_mac = netif.getMac();
    var pkt: [128]u8 = @splat(0);
    const frame_len = buildDadNeighborSolicitation(&pkt, target, our_mac);
    _ = nic.sendPacket(&pkt, frame_len);
}

/// Drive NDP NS retransmits / NUD probes / DAD / RS (SK-79/81/85/88).
pub fn neighborTimerTick(ms_elapsed: u32) void {
    var batch: [ndp.MAX_NEIGHBORS]ndp.Solicit = undefined;
    const n = ndp.timerTick(ms_elapsed, &batch);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (ndp.solicitIsMulticast(batch[i])) {
            sendNeighborSolicitation(batch[i].target);
        } else {
            sendNeighborSolicitationUnicast(batch[i].target, batch[i].dst_mac);
        }
    }
    var dad_batch: [ndp.MAX_LOCAL_ADDRS][16]u8 = undefined;
    const dn = ndp.dadTimerTick(ms_elapsed, &dad_batch);
    var di: u32 = 0;
    while (di < dn) : (di += 1) {
        sendDadNeighborSolicitation(dad_batch[di]);
    }
    routerSolicitTimerTick(ms_elapsed);
    // SK-89: expire default router; rediscover if lifetime hits zero.
    if (ndp.routerLifetimeTimerTick(ms_elapsed)) {
        startRouterSolicit();
    }
    // SK-90: expire on-link / SLAAC prefixes when Valid Lifetime hits zero.
    ndp.prefixLifetimeTimerTick(ms_elapsed);
    // SK-91: Preferred Lifetime → deprecate addresses for new TX.
    ndp.preferredLifetimeTimerTick(ms_elapsed);
    // SK-94: expire Route Information entries.
    ndp.routeLifetimeTimerTick(ms_elapsed);
    // SK-95: expire Destination Cache redirects.
    ndp.destCacheTimerTick(ms_elapsed);
    // SK-97: expire Path MTU entries.
    ipv6.pathMtuTimerTick(ms_elapsed);
    // SK-101: expire IPv4 Path MTU entries.
    ipv4.pathMtuTimerTick(ms_elapsed);
}
