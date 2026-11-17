const nic = @import("nic.zig");
const netif = @import("netif.zig");
const eth = @import("eth.zig");
const ipv4 = @import("ipv4.zig");
const arp = @import("arp.zig");
const bo = @import("../lib/byte_order.zig");
const echo_policy = @import("icmp_echo_policy.zig");
const lo = @import("lo.zig");

/// Build an ICMP echo reply frame into `out` (which must hold at least 256
/// bytes) from an echo `req` of `req_len` bytes. Pure: no ARP/NIC side
/// effects, so it is arch-clean and testable in isolation.
/// `reply_src_ip`/`reply_src_mac` are ours; `reply_dst_*` are the requester's.
/// Returns the total ethernet frame length.
pub fn buildEchoReply(
    out: [*]u8,
    req: [*]const u8,
    req_len: u32,
    reply_src_ip: [4]u8,
    reply_dst_ip: [4]u8,
    reply_src_mac: [6]u8,
    reply_dst_mac: [6]u8,
) u16 {
    return buildEchoReplyMtu(out[0..256], req, req_len, netif.MAX_MTU, reply_src_ip, reply_dst_ip, reply_src_mac, reply_dst_mac);
}

/// RFC 792: echo the whole request, bounded by the interface `mtu` (one
/// unfragmented datagram) and by `out.len`.
pub fn buildEchoReplyMtu(
    out: []u8,
    req: [*]const u8,
    req_len: u32,
    mtu: u32,
    reply_src_ip: [4]u8,
    reply_dst_ip: [4]u8,
    reply_src_mac: [6]u8,
    reply_dst_mac: [6]u8,
) u16 {
    // ICMP message: copy the request (type, code, checksum, id, seq, data).
    const icmp_total = echo_policy.replyIcmpLen(req_len, mtu, @intCast(out.len));
    const o = out.ptr;
    @memcpy(o[34..][0..icmp_total], req[0..icmp_total]);

    // Type=0 (echo reply), code=0, clear + recompute checksum.
    o[34] = 0;
    o[35] = 0;
    o[36] = 0;
    o[37] = 0;
    const csum = ipv4.checksum(o + 34, icmp_total);
    bo.writeU16BeAt(o, 36, csum);

    // IPv4 header at offset 14, ethernet frame at offset 0.
    ipv4.buildHeader(o + 14, reply_src_ip, reply_dst_ip, ipv4.PROTO_ICMP, icmp_total);
    return eth.buildFrame(o, reply_dst_mac, reply_src_mac, eth.ETHERTYPE_IPV4, 20 + icmp_total);
}

/// Parsed ICMP Destination Unreachable / Fragmentation Needed (SK-101).
pub const FragNeededMsg = struct {
    next_hop_mtu: u16 = 0,
    dst: [4]u8 = .{ 0, 0, 0, 0 },
};

/// Pure parser for type=3/code=4 (RFC 792 + RFC 1191 Next-Hop MTU).
pub fn parseFragNeeded(data: [*]const u8, len: u32) ?FragNeededMsg {
    if (len < 8 + 20) return null;
    if (data[0] != 3 or data[1] != 4) return null;
    const inv = ipv4.parseHeader(data + 8, null) orelse return null;
    return .{
        .next_hop_mtu = bo.readU16BeAt(data, 6),
        .dst = inv.dst_ip,
    };
}

/// Send the ICMP message `msg` (header and data, checksum already set) from a ping socket bound to `bound` (0.0.0.0 when unbound) to
/// `dst`: routed like a UDP datagram (lo for this host's addresses, else the next hop's MAC; while that is unknown the frame waits
/// for ARP in arp.queueFrame and the send succeeds, as Linux queues it on the neighbour). Returns 0, or -EMSGSIZE past the path
/// MTU, -ENOBUFS when the device drops it.
pub fn sendFrom(bound: [4]u8, dst: [4]u8, msg: []const u8) i64 {
    if (msg.len + ipv4.HEADER_LEN > ipv4.getSendMtu(dst)) return -90;
    const our_mac = netif.getMac();
    const via_lo = netif.isLocal4(dst);
    var wait_hop: ?[4]u8 = null;
    const dst_mac = if (via_lo) our_mac else resolve: {
        const hop = netif.nextHop4(dst);
        break :resolve arp.resolve(hop) orelse blk: {
            wait_hop = hop;
            break :blk [6]u8{ 0, 0, 0, 0, 0, 0 };
        };
    };
    const src = @import("tcp_port_policy.zig").sourceAddr(bound, dst, netif.getOurIp());
    var pkt: [1518]u8 = @splat(0);
    @memcpy(pkt[34..][0..msg.len], msg);
    ipv4.buildHeader(pkt[14..].ptr, src, dst, ipv4.PROTO_ICMP, @intCast(msg.len));
    const frame_len = eth.buildFrame(&pkt, dst_mac, our_mac, eth.ETHERTYPE_IPV4, @intCast(20 + msg.len));
    if (wait_hop) |hop| {
        arp.queueFrame(hop, &pkt, frame_len);
        return 0;
    }
    // A loopback frame is delivered at once, so a ping socket's reply is queued by the time its send returns.
    const ok = if (via_lo) lo.sendNow(&pkt, frame_len) or lo.dropIsLoss(frame_len) else nic.sendPacket(&pkt, frame_len);
    return if (ok) 0 else -105;
}

pub fn handlePacket(src_ip: [4]u8, dst_ip: [4]u8, data: [*]const u8, len: u32) void {
    if (len < 8) return;
    // An echo reply is for the ping socket whose ident is its id (Linux icmp_rcv → ping_rcv); a bad checksum drops it.
    const pp = @import("ping_policy.zig");
    if (pp.replyIdent(data[0..len])) |ident| {
        if (len > 0xffff or ipv4.checksum(data, @intCast(len)) != 0) return;
        @import("udp.zig").deliverPing(ident, src_ip, dst_ip, data[0..len]);
        return;
    }

    const icmp_type = data[0];
    const icmp_code = data[1];

    if (icmp_type == 8 and icmp_code == 0) {
        // Echo request → send echo reply
        const our_mac = netif.getMac();

        // The reply goes back the way any datagram to the requester would: over lo to a 127/8 requester, else to the MAC of the
        // next hop, which is the gateway for an off-link requester (Linux icmp_reply routes it like any other output).
        const via_lo = netif.isLocal4(src_ip);
        const dst_mac = if (via_lo) our_mac else resolve: {
            const hop = netif.nextHop4(src_ip);
            break :resolve arp.resolve(hop) orelse {
                arp.sendArpRequest(hop);
                return;
            };
        };

        var pkt: [echo_policy.FRAME_BUF_LEN]u8 = undefined;
        const frame_len = buildEchoReplyMtu(&pkt, data, len, netif.getMtu(), dst_ip, src_ip, our_mac, dst_mac);
        if (via_lo) _ = lo.sendPacket(&pkt, frame_len) else _ = nic.sendPacket(&pkt, frame_len);
    } else if (icmp_type == 3 and icmp_code == 3) {
        // Port unreachable for a UDP datagram we sent: tell the connected socket.
        const unreach = @import("icmp_unreach_policy.zig");
        const q = unreach.parseQuote(data[0..len]) orelse return;
        @import("udp.zig").notifyUnreachable(q.src_port, q.dst_port);
    } else if (icmp_type == 3 and icmp_code == 4) {
        // SK-101: Fragmentation Needed → Path MTU.
        const msg = parseFragNeeded(data, len) orelse return;
        var reported: u32 = msg.next_hop_mtu;
        if (reported == 0) {
            // Pre-RFC1191: fall back toward the invoking datagram size.
            const inv = ipv4.parseHeader(data + 8, null) orelse return;
            reported = @as(u32, inv.payload_offset) + inv.payload_len;
            if (reported == 0) reported = ipv4.MIN_MTU;
        }
        ipv4.updatePathMtu(msg.dst, reported);
    }
}
