const nic = @import("nic.zig");
const netif = @import("netif.zig");
const eth = @import("eth.zig");
const ipv4 = @import("ipv4.zig");
const ipid = @import("ipid.zig");
const ipo = @import("ip_opt_policy.zig");
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
    return buildEchoReplyMtu(out[0..256], req, req_len, netif.MAX_MTU, reply_src_ip, reply_dst_ip, reply_src_mac, reply_dst_mac, 0);
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
    tos: u8,
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
    // The reply keeps the request's TOS (icmp_reply: ipc.tos = ip_hdr(skb)->tos); setIdent refreshes the header checksum.
    o[14 + 1] = tos;
    // An echo reply goes out without DF and with a hashed id (icmp_reply has no socket that numbers it).
    ipv4.setIdent(o + 14, ipid.global(reply_dst_ip, reply_src_ip, ipv4.PROTO_ICMP), false);
    return eth.buildFrame(o, reply_dst_mac, reply_src_mac, eth.ETHERTYPE_IPV4, 20 + icmp_total);
}

/// icmp_reply to a reassembled echo request longer than the MTU, or to one with IP options: the whole request is echoed back (type 0,
/// checksum redone), behind `opts`, in fragments when it does not fit one frame (ip_push_pending_frames → ip_fragment), from `src`
/// to `dst`.
fn sendBigEchoReply(req: []const u8, src: [4]u8, dst: [4]u8, our_mac: [6]u8, dst_mac: [6]u8, via_lo: bool, tos: u8, mtu: u16, opts: []const u8) void {
    const slab = @import("../mm/slab.zig");
    const raw = slab.kmalloc(req.len) orelse return;
    defer slab.kfree(raw);
    const msg = @as([*]u8, @ptrCast(raw))[0..req.len];
    @memcpy(msg, req);
    msg[0] = 0;
    msg[1] = 0;
    msg[2] = 0;
    msg[3] = 0;
    bo.writeU16BeAt(msg.ptr, 2, ipv4.checksum(msg.ptr, @intCast(msg.len)));
    var hdr: [20]u8 = undefined;
    ipv4.buildHeader(&hdr, src, dst, ipv4.PROTO_ICMP, 0);
    hdr[1] = tos;
    ipv4.setIdent(&hdr, ipid.global(dst, src, ipv4.PROTO_ICMP), false);
    _ = @import("ip_frag.zig").send4(hdr, opts, msg, mtu, dst_mac, our_mac, via_lo, null);
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
/// for ARP in arp.queueFrame and the send succeeds, as Linux queues it on the neighbour). A message past the path MTU is fragmented
/// unless `mode` refuses it (raw_icmp_policy.oversizeErrno4). Returns 0, or -EMSGSIZE, -ENOBUFS when the device drops it.
pub fn sendFrom(bound: [4]u8, dst: [4]u8, msg: []const u8, mode: u8) i64 {
    return sendFromOv(bound, dst, msg, mode, ipo.DEFAULT_TTL, 0);
}

/// sendFrom with the IP header's TTL and TOS given (a ping socket's IP_TTL / IP_TOS, or the IP_TTL / IP_TOS control messages of
/// that one request: ip_make_skb takes cork->ttl and cork->tos).
pub fn sendFromOv(bound: [4]u8, dst: [4]u8, msg: []const u8, mode: u8, ttl: u8, tos: u8) i64 {
    return sendFromOpts(bound, dst, msg, mode, ttl, tos, null);
}

/// sendFromOv with IPv4 options (ipc.opt: an IP_RETOPTS control message's, else the ping socket's IP_OPTIONS), built after the
/// header for this request; a source route sends to its first hop.
pub fn sendFromOpts(bound: [4]u8, dst_in: [4]u8, msg: []const u8, mode: u8, ttl: u8, tos: u8, ipopts: ?@import("ip_options_policy.zig").SendOpts) i64 {
    const iop = @import("ip_options_policy.zig");
    const dst = if (ipopts) |so| (if (so.o.srr != null) so.faddr else dst_in) else dst_in;
    const optlen: usize = if (ipopts) |so| so.len else 0;
    const mtu = ipv4.getSendMtu(dst);
    const orc = @import("raw_icmp_policy.zig").oversizeErrno4(msg.len + optlen, mtu, mode);
    if (orc != 0) return orc;
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
    const big = msg.len + optlen + ipv4.HEADER_LEN > mtu;
    if (big or ipopts != null) {
        // ip_append_data → ip_fragment: pieces without DF, numbered from the shared generator; within the MTU one frame with the
        // options after the header.
        var hdr: [20]u8 = undefined;
        ipv4.buildHeader(&hdr, src, dst, ipv4.PROTO_ICMP, 0);
        hdr[1] = tos;
        hdr[8] = ttl;
        if (big) ipv4.setIdent(&hdr, ipid.global(dst, src, ipv4.PROTO_ICMP), false) else ipv4.setIdent(&hdr, ipid.unowned(dst, src, ipv4.PROTO_ICMP, mode), ipo.datagramDf(mode));
        var built: [40]u8 = @splat(0);
        if (ipopts) |so| iop.build(so, src, dst_in, iop.msSinceMidnight(@import("../proc/time_syscall.zig").wallClockNanos()), &built);
        return if (@import("ip_frag.zig").send4(hdr, built[0..optlen], msg, mtu, dst_mac, our_mac, via_lo, wait_hop)) 0 else -105;
    }
    var pkt: [1518]u8 = @splat(0);
    @memcpy(pkt[34..][0..msg.len], msg);
    ipv4.buildHeader(pkt[14..].ptr, src, dst, ipv4.PROTO_ICMP, @intCast(msg.len));
    pkt[14 + 1] = tos;
    pkt[14 + 8] = ttl;
    ipv4.setIdent(pkt[14..].ptr, ipid.unowned(dst, src, ipv4.PROTO_ICMP, mode), ipo.datagramDf(mode));
    const frame_len = eth.buildFrame(&pkt, dst_mac, our_mac, eth.ETHERTYPE_IPV4, @intCast(20 + msg.len));
    if (wait_hop) |hop| {
        arp.queueFrame(hop, &pkt, frame_len);
        return 0;
    }
    // A loopback frame is delivered at once, so a ping socket's reply is queued by the time its send returns.
    const ok = if (via_lo) lo.sendNow(&pkt, frame_len) or lo.dropIsLoss(frame_len) else nic.sendPacket(&pkt, frame_len);
    return if (ok) 0 else -105;
}

/// ICMP protocol unreachable (type 3 code 2) for a datagram `dgram` (IP header first) from `src_ip` to `dst_ip` whose protocol this
/// host does not handle and no raw socket took (ip_protocol_deliver_rcu). It quotes the IP header and the first 8 bytes of payload,
/// as the port unreachable does; like it, only a loopback datagram is answered (icmp_unreach_policy.shouldReply).
pub fn sendProtoUnreachable(dgram: []const u8, src_ip: [4]u8, dst_ip: [4]u8) void {
    const unreach = @import("icmp_unreach_policy.zig");
    if (!unreach.shouldReply(netif.isLocal4(src_ip) and netif.isLocal4(dst_ip), false, false)) return;
    if (dgram.len < 20) return;
    const ihl: u16 = @as(u16, dgram[0] & 0x0f) * 4;
    if (ihl < 20 or ihl > dgram.len) return;
    const quote: usize = unreach.quoteLen(ihl, @intCast(dgram.len));
    var pkt: [14 + 20 + 8 + 60 + 8]u8 = @splat(0);
    if (quote > pkt.len - 42) return;
    @memcpy(pkt[42..][0..quote], dgram[0..quote]);
    pkt[34] = unreach.TYPE_DEST_UNREACH;
    pkt[35] = 2;
    const icmp_len: u16 = @intCast(8 + quote);
    bo.writeU16BeAt(&pkt, 36, ipv4.checksum(pkt[34..].ptr, icmp_len));
    ipv4.buildHeader(pkt[14..].ptr, dst_ip, src_ip, ipv4.PROTO_ICMP, icmp_len);
    ipv4.setIdent(pkt[14..].ptr, ipid.global(src_ip, dst_ip, ipv4.PROTO_ICMP), false);
    const mac = netif.getMac();
    const frame_len = eth.buildFrame(&pkt, mac, mac, eth.ETHERTYPE_IPV4, 20 + icmp_len);
    _ = lo.sendPacket(&pkt, frame_len);
}

pub fn handlePacket(src_ip: [4]u8, dst_ip: [4]u8, data: [*]const u8, len: u32) void {
    handlePacketMeta(src_ip, dst_ip, data, len, .{ .dst = dst_ip });
}

/// handlePacket for a message that arrived with `meta` (interface, header destination, TTL, TOS): an echo reply's goes to the ping
/// socket for recvmsg's control messages, an echo request's TOS to the reply.
pub fn handlePacketMeta(src_ip: [4]u8, dst_ip: [4]u8, data: [*]const u8, len: u32, meta: @import("ip_cmsg_policy.zig").RecvInfo) void {
    if (len < 8) return;
    // An echo reply is for the ping socket whose ident is its id (Linux icmp_rcv → ping_rcv); a bad checksum drops it.
    const pp = @import("ping_policy.zig");
    if (pp.replyIdent(data[0..len])) |ident| {
        if (len > 0xffff or ipv4.checksum(data, @intCast(len)) != 0) return;
        var m = meta;
        m.spec_dst = .{ 0, 0, 0, 0 };
        @import("udp.zig").deliverPing(ident, src_ip, dst_ip, data[0..len], m);
        return;
    }

    const icmp_type = data[0];
    const icmp_code = data[1];
    const unreach = @import("icmp_unreach_policy.zig");

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

        const mtu = netif.getMtu();
        // icmp_reply: a request with options is answered with them echoed (ip_options_echo; none that cannot be echoed means no
        // reply), built again for the reply's header (ip_options_build): a record route or timestamp with room gets this host.
        if (meta.optlen != 0) {
            if (meta.ret_bad) return;
            const iop = @import("ip_options_policy.zig");
            var built: [40]u8 = @splat(0);
            var bl: usize = 0;
            if (meta.retlen != 0) {
                const so = iop.compileForSend(meta.retopts[0..meta.retlen], true) orelse return;
                iop.build(so, dst_ip, src_ip, iop.msSinceMidnight(@import("../proc/time_syscall.zig").wallClockNanos()), &built);
                bl = so.len;
            }
            if (len <= 0xFFFF - ipv4.HEADER_LEN - bl) sendBigEchoReply(data[0..len], dst_ip, src_ip, our_mac, dst_mac, via_lo, meta.tos, mtu, built[0..bl]);
            return;
        }
        if (len + ipv4.HEADER_LEN > mtu and len <= 0xFFFF - ipv4.HEADER_LEN) {
            sendBigEchoReply(data[0..len], dst_ip, src_ip, our_mac, dst_mac, via_lo, meta.tos, mtu, &.{});
            return;
        }
        var pkt: [echo_policy.FRAME_BUF_LEN]u8 = undefined;
        const frame_len = buildEchoReplyMtu(&pkt, data, len, mtu, dst_ip, src_ip, our_mac, dst_mac, meta.tos);
        if (via_lo) _ = lo.sendPacket(&pkt, frame_len) else _ = nic.sendPacket(&pkt, frame_len);
    } else if (unreach.isError(icmp_type)) {
        // An error about a datagram this host sent (icmp_unreach): a bad checksum drops it (icmp_rcv).
        if (len > 0xffff or ipv4.checksum(data, @intCast(len)) != 0) return;
        if (icmp_type == 3 and icmp_code == 4) {
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
        // raw_icmp_error: every raw socket of the quoted datagram's protocol that sent it hears of the error, whatever the protocol.
        if (len >= 8 + 20 and (data[8] & 0x0F) >= 5 and @as(usize, data[8] & 0x0F) * 4 + 8 <= len) {
            const qihl: usize = @as(usize, data[8] & 0x0F) * 4;
            @import("raw_icmp.zig").notifyIcmpError(data[8 + 9], data[8 + 12 ..][0..4].*, data[8 + 16 ..][0..4].*, icmp_type, icmp_code, .{
                .errno = 0,
                .hard = false,
                .icmp_type = icmp_type,
                .icmp_code = icmp_code,
                .info = if (icmp_type == 3 and icmp_code == 4) bo.readU16BeAt(data, 6) else 0,
                .offender = src_ip,
                .local_port = 0,
                .peer_port = 0,
                .peer_ip = data[8 + 16 ..][0..4].*,
                .payload = &.{},
            }, data[8..len], data[8 + qihl .. len]);
        }
        // An error quoting a TCP segment goes to its connection (tcp_v4_err).
        if (unreach.parseTcpQuote(data[0..len])) |tq| {
            var off: [16]u8 = @splat(0);
            @memcpy(off[0..4], &src_ip);
            const ihl: usize = @as(usize, data[8] & 0x0F) * 4;
            @import("tcp.zig").icmpError(tq, unreach.tcpErrno(icmp_type, icmp_code), unreach.tcpReqAborts(icmp_type, icmp_code), .{
                .icmp_type = icmp_type,
                .icmp_code = icmp_code,
                .info = if (icmp_type == 3 and icmp_code == 4) bo.readU16BeAt(data, 6) else 0,
                .offender = off,
                .l4 = data[8 + ihl ..][0..8].*,
            });
        }
        // A hard error goes to the connected UDP socket that sent the quoted datagram (udp_err), or to the connected ping socket
        // whose echo request it quotes (ping_err).
        const q = unreach.parseErrorQuote(data[0..len]) orelse return;
        switch (q.kind) {
            // udp_err: soft errors too, for a socket with IP_RECVERR (it queues them); the error queue keeps the quoted payload.
            .udp => {
                const e = unreach.errorFor(icmp_type, icmp_code) orelse return;
                const ihl: usize = @as(usize, data[8] & 0x0F) * 4;
                const quoted = data[0..len][8 + ihl + 8 ..];
                @import("udp.zig").notifyIcmpError(.{
                    .errno = e.errno,
                    .hard = e.hard,
                    .icmp_type = icmp_type,
                    .icmp_code = icmp_code,
                    .info = if (icmp_type == 3 and icmp_code == 4) bo.readU16BeAt(data, 6) else 0,
                    .offender = src_ip,
                    .local_port = q.src_port,
                    .peer_port = q.dst_port,
                    .peer_ip = data[8 + 16 ..][0..4].*,
                    .payload = quoted,
                });
            },
            // ping_err: the quoted echo request is queued for a socket with IP_RECVERR, soft errors included.
            .echo => {
                const e = unreach.pingErrorFor(icmp_type, icmp_code);
                const ihl: usize = @as(usize, data[8] & 0x0F) * 4;
                @import("udp.zig").notifyPingIcmpError(q.src_port, .{
                    .errno = e.errno,
                    .hard = e.hard,
                    .icmp_type = icmp_type,
                    .icmp_code = icmp_code,
                    .info = if (icmp_type == 3 and icmp_code == 4) bo.readU16BeAt(data, 6) else 0,
                    .offender = src_ip,
                    .local_port = q.src_port,
                    .peer_port = 0,
                    .peer_ip = data[8 + 16 ..][0..4].*,
                    .payload = data[0..len][8 + ihl ..],
                }, true);
            },
        }
    }
}
