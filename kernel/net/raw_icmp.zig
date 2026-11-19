//! Raw sockets: IPv4 and IPv6 of any protocol (socket(AF_INET or AF_INET6, SOCK_RAW, p), Linux net/ipv4/raw.c, net/ipv6/raw.c).
//! Every IPv4 datagram this host receives is copied, IP header included, to each IPv4 socket of its protocol whose bound address
//! and connected peer match (raw_icmp_policy.matches; ICMP_FILTER on an ICMP one); every IPv6 packet, without its IPv6 header, to
//! each IPv6 socket of its next header that matches (ICMP6_FILTER on an ICMPv6 one; a socket with a checksum offset drops a wrong
//! sum). A send gets its IP header (and, at the socket's IPV6_CHECKSUM offset, its checksum) from the kernel, unless IP_HDRINCL. The sockets share one table; a socket lives until its last descriptor reference is gone, which is
//! what lets a fork keep it. The raw Ethernet frame ioctl-style socket this replaced (read/write on the NIC) is gone.
const policy = @import("raw_icmp_policy.zig");
const ipv4 = @import("ipv4.zig");
const ipid = @import("ipid.zig");
const netif = @import("netif.zig");
const nic = @import("nic.zig");
const lo = @import("lo.zig");
const arp = @import("arp.zig");
const eth = @import("eth.zig");
const route4 = @import("route4_policy.zig");
const ipo = @import("ip_opt_policy.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

/// Raw ICMP sockets at once (each queues up to QUEUE_DEPTH datagrams of RAW_QUEUE_LEN bytes: about 200 KiB in all).
pub const MAX_SOCKETS = 16;
const QUEUE_DEPTH = policy.QUEUE_DEPTH;
pub const RAW_QUEUE_LEN = 1500;
/// Largest ICMP message a send carries (1472-byte UDP payload and ICMP header: the same bound the ping sockets use).
pub const MAX_MESSAGE = 1480;
/// Largest datagram an IP_HDRINCL send writes whole (header included): one Ethernet MTU.
pub const MAX_HDRINCL = 20 + MAX_MESSAGE;
/// The frame buffer of a send: ethernet, IPv4 and ICMP headers in front of the message.
const FRAME_BUF_LEN = 14 + 20 + MAX_MESSAGE;

const Entry = struct {
    dgram: [RAW_QUEUE_LEN]u8 = @splat(0),
    len: u16 = 0,
    /// The sender: an IPv4 address in the first 4 bytes, or an IPv6 one.
    src: [16]u8 = @splat(0),
};

const Socket = struct {
    used: bool = false,
    refs: u32 = 0,
    bound: [4]u8 = @splat(0),
    peer: [4]u8 = @splat(0),
    /// An AF_INET6 socket: bound6 / peer6 / filter apply instead of bound / peer.
    v6: bool = false,
    /// The protocol the socket carries (inet_num): what it receives and the protocol (IPv6 next header) of what it sends.
    protocol: u8 = 1,
    /// IPV6_CHECKSUM of an IPv6 socket (raw6_sock checksum/offset): where a send's checksum goes and a received one is checked, or
    /// null for none (policy.initialChecksum6 at creation).
    csum_off: ?u32 = null,
    bound6: [16]u8 = @splat(0),
    peer6: [16]u8 = @splat(0),
    /// connect() named a peer (an IPv6 socket may be connected to ::).
    connected: bool = false,
    filter: [policy.FILTER_LEN]u8 = @splat(0),
    /// ICMP_FILTER of an IPv4 socket (SOL_RAW option 1): bit n blocks ICMP type n.
    icmp_filter: u32 = 0,
    shut_rd: bool = false,
    shut_wr: bool = false,
    /// SOL_SOCKET options (SO_RCVTIMEO, SO_RCVBUF, ...): one copy per socket, so every descriptor naming it sees the same set.
    opts: @import("sockopt_policy.zig").Stored = .{},
    /// A ring, oldest first: `count` datagrams from slot `head` (policy.enqueueSlot, policy.afterRecv).
    queue: [QUEUE_DEPTH]Entry = @splat(.{}),
    head: u8 = 0,
    count: u8 = 0,
};

var sockets: [MAX_SOCKETS]Socket = @splat(.{});
var raw_lock: IrqSpinlock = .{};

/// A new socket of `protocol` (an IPv6 one when `v6`) on the first free slot, or null (ENOBUFS). Nothing is shared with a UDP
/// socket. IPPROTO_RAW starts with IP_HDRINCL / IPV6_HDRINCL set (inet_create, inet6_create: one HDRINCL bit for both).
pub fn open(v6: bool, protocol: u32) ?u32 {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    for (&sockets, 0..) |*s, i| {
        if (s.used) continue;
        s.* = .{ .used = true, .refs = 1, .v6 = v6, .protocol = @truncate(protocol), .csum_off = if (v6) policy.initialChecksum6(protocol) else null };
        if (policy.startsHdrincl(protocol)) s.opts.ip.hdrincl = true;
        return @intCast(i);
    }
    return null;
}

/// The socket's protocol (SO_PROTOCOL, the getsockname port), or 0 for a slot not in use.
pub fn protocolOf(idx: u32) u32 {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return 0;
    return sockets[idx].protocol;
}

/// One more descriptor names the socket (dup, fork).
pub fn retain(idx: u32) void {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return;
    sockets[idx].refs += 1;
}

/// One descriptor let go of the socket; the last one frees the slot and its queue.
pub fn release(idx: u32) void {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return;
    if (sockets[idx].refs > 1) {
        sockets[idx].refs -= 1;
        return;
    }
    sockets[idx] = .{};
}

/// The socket's SOL_SOCKET options, or null for a slot not in use.
pub fn getOpts(idx: u32) ?@import("sockopt_policy.zig").Stored {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return null;
    return sockets[idx].opts;
}

/// Replace the socket's SOL_SOCKET options; false for a slot not in use.
pub fn setOpts(idx: u32, st: @import("sockopt_policy.zig").Stored) bool {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return false;
    sockets[idx].opts = st;
    return true;
}

/// Whether a datagram is queued for the socket (poll, and the wait in a blocking recv).
pub fn hasData(idx: u32) bool {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return false;
    return sockets[idx].count != 0;
}

pub const RecvResult = union(enum) {
    ok: struct { n: usize, src: [16]u8, trunc: usize },
    eagain,
};

/// Copy the oldest queued datagram into `out`: `n` bytes of it, and `trunc` — the datagram's whole length as MSG_TRUNC reports it.
/// A read takes it off the queue; `peek` (MSG_PEEK) leaves it there for the next receive.
pub fn recv(idx: u32, out: []u8, peek: bool) RecvResult {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return .eagain;
    const s = &sockets[idx];
    if (s.count == 0) return .eagain;
    const e = &s.queue[s.head];
    const copy_len = @min(@as(usize, e.len), out.len);
    @memcpy(out[0..copy_len], e.dgram[0..copy_len]);
    const result: RecvResult = .{ .ok = .{ .n = copy_len, .src = e.src, .trunc = e.len } };
    const next = policy.afterRecv(s.head, s.count, peek);
    s.head = next.head;
    s.count = next.count;
    return result;
}

/// raw_bind: the socket takes only datagrams addressed to `addr` from then on.
pub fn bind(idx: u32, addr: [4]u8) bool {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return false;
    sockets[idx].bound = addr;
    return true;
}

/// raw_connect: `peer` given, the socket takes only datagrams from it and sends to it; all zero (AF_UNSPEC), the socket is
/// unconnected again.
pub fn connect(idx: u32, peer: [4]u8) bool {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return false;
    sockets[idx].peer = peer;
    sockets[idx].connected = !@import("std").mem.allEqual(u8, &peer, 0);
    // connect(AF_UNSPEC) also forgets the bound address (__ip4_datagram_disconnect: raw_bind takes no SOCK_BINDADDR_LOCK).
    if (!sockets[idx].connected) sockets[idx].bound = .{ 0, 0, 0, 0 };
    return true;
}

pub fn bind6(idx: u32, addr: [16]u8) bool {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return false;
    sockets[idx].bound6 = addr;
    return true;
}

/// connect on an IPv6 socket: `peer` (:: included) filters what is received and is where send goes; null (AF_UNSPEC) dissolves the
/// association and forgets the bound address (__ip6_datagram_disconnect).
pub fn connect6(idx: u32, peer: ?[16]u8) bool {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return false;
    const s = &sockets[idx];
    s.peer6 = peer orelse @splat(0);
    s.connected = peer != null;
    if (peer == null) s.bound6 = @splat(0);
    return true;
}

pub fn isV6(idx: u32) bool {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    return idx < MAX_SOCKETS and sockets[idx].used and sockets[idx].v6;
}

pub fn boundAddr6(idx: u32) [16]u8 {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return @splat(0);
    return sockets[idx].bound6;
}

pub fn peerAddr6(idx: u32) [16]u8 {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return @splat(0);
    return sockets[idx].peer6;
}

pub fn getFilter(idx: u32) [policy.FILTER_LEN]u8 {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return @splat(0);
    return sockets[idx].filter;
}

pub fn getIcmpFilter(idx: u32) u32 {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return 0;
    return sockets[idx].icmp_filter;
}

/// setsockopt(ICMP_FILTER): the first min(len, 4) bytes of the mask.
pub fn setIcmpFilter(idx: u32, val: []const u8) bool {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return false;
    sockets[idx].icmp_filter = policy.setIcmpFilter(sockets[idx].icmp_filter, val);
    return true;
}

/// setsockopt(ICMP6_FILTER): the first min(len, 32) bytes of the filter.
pub fn setFilter(idx: u32, val: []const u8) bool {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return false;
    policy.setFilter(&sockets[idx].filter, val);
    return true;
}

/// shutdown(how) (inet_shutdown): SHUT_RD ends receiving once the queue is empty (datagrams still queue), SHUT_WR changes nothing a
/// raw send looks at. ENOTCONN for an unconnected socket, whose flags are set all the same.
pub fn shutdown(idx: u32, how: u32) i64 {
    const rc = blk: {
        const saved = raw_lock.acquire();
        defer raw_lock.release(saved);
        if (idx >= MAX_SOCKETS or !sockets[idx].used) return -9;
        const s = &sockets[idx];
        if (how == 0 or how == 2) s.shut_rd = true;
        if (how == 1 or how == 2) s.shut_wr = true;
        break :blk policy.shutdownErrno(s.connected);
    };
    const ep = @import("epoll.zig");
    ep.epollNotify(.raw_socket, idx, pollEvents(idx));
    return rc;
}

pub fn shutRd(idx: u32) bool {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    return idx < MAX_SOCKETS and sockets[idx].used and sockets[idx].shut_rd;
}

/// poll / epoll readiness (policy.pollBits).
pub fn pollEvents(idx: u32) u32 {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return 0x004;
    const s = &sockets[idx];
    return policy.pollBits(s.count != 0, s.shut_rd, s.shut_wr);
}

pub fn boundAddr(idx: u32) [4]u8 {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return .{ 0, 0, 0, 0 };
    return sockets[idx].bound;
}

pub fn peerAddr(idx: u32) [4]u8 {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return .{ 0, 0, 0, 0 };
    return sockets[idx].peer;
}

pub fn isConnected(idx: u32) bool {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    return idx < MAX_SOCKETS and sockets[idx].used and sockets[idx].connected;
}

/// One received IPv4 datagram of `protocol` that arrived on this host: `dgram` starts at the IP header of `src` → `dst` (Linux
/// raw_v4_input hands raw sockets the skb, IP header included). Each matching socket of that protocol gets its own copy; a full queue
/// drops the datagram. Whether any socket matched (raw_v4_input's `delivered`, set before ICMP_FILTER and the queue are looked at):
/// a datagram no protocol handles is then not answered with protocol unreachable.
pub fn deliver(protocol: u8, dgram: []const u8, src: [4]u8, dst: [4]u8) bool {
    var notify: [MAX_SOCKETS]u32 = undefined;
    var n_notify: usize = 0;
    var took = false;
    {
        const saved = raw_lock.acquire();
        defer raw_lock.release(saved);
        for (&sockets, 0..) |*s, i| {
            if (!s.used) continue;
            if (s.v6) continue;
            if (s.protocol != protocol) continue;
            if (!policy.matches(s.bound, s.peer, src, dst)) continue;
            took = true;
            if (protocol == policy.IPPROTO_ICMP) if (policy.icmpTypeOf(dgram)) |ty| if (policy.icmpFilterBlocks(s.icmp_filter, ty)) continue;
            const at = policy.enqueueSlot(s.head, s.count) orelse continue;
            const e = &s.queue[at];
            const copy_len = @min(dgram.len, RAW_QUEUE_LEN);
            @memcpy(e.dgram[0..copy_len], dgram[0..copy_len]);
            e.len = @intCast(copy_len);
            e.src = @splat(0);
            @memcpy(e.src[0..4], &src);
            s.count += 1;
            notify[n_notify] = @intCast(i);
            n_notify += 1;
        }
    }
    for (notify[0..n_notify]) |idx| {
        // The index is the socket's identity here: a slot freed since holds a different socket, which gets a needless wake at worst.
        @import("epoll.zig").epollNotify(.raw_socket, idx, @import("epoll.zig").EPOLLIN);
    }
    return took;
}

/// One IPv6 packet of next header `protocol` that arrived on this host, `src` → `dst`, `msg` being what follows its IPv6 header
/// (Linux raw6_local_deliver, before the protocol handler): each IPv6 socket of that protocol that matches gets a copy. An ICMPv6
/// socket's ICMP6_FILTER may block the type; a socket with a checksum offset drops a packet whose checksum is wrong (rawv6_rcv).
/// Whether any socket matched (ipv6_raw_deliver's `delivered`).
pub fn deliver6(protocol: u8, msg: []const u8, src: [16]u8, dst: [16]u8) bool {
    var notify: [MAX_SOCKETS]u32 = undefined;
    var n_notify: usize = 0;
    var took = false;
    {
        const saved = raw_lock.acquire();
        defer raw_lock.release(saved);
        for (&sockets, 0..) |*s, i| {
            if (!s.used or !s.v6) continue;
            if (s.protocol != protocol) continue;
            if (!policy.matches6(s.bound6, s.peer6, src, dst)) continue;
            took = true;
            if (protocol == policy.IPPROTO_ICMPV6 and (msg.len < 4 or policy.filterBlocks(s.filter, msg[0]))) continue;
            if (s.csum_off != null and policy.sum6(src, dst, s.protocol, msg) != 0) continue;
            const at = policy.enqueueSlot(s.head, s.count) orelse continue;
            const e = &s.queue[at];
            const copy_len = @min(msg.len, RAW_QUEUE_LEN);
            @memcpy(e.dgram[0..copy_len], msg[0..copy_len]);
            e.len = @intCast(copy_len);
            e.src = src;
            s.count += 1;
            notify[n_notify] = @intCast(i);
            n_notify += 1;
        }
    }
    for (notify[0..n_notify]) |idx| {
        @import("epoll.zig").epollNotify(.raw_socket, idx, @import("epoll.zig").EPOLLIN);
    }
    return took;
}

/// The socket's IPV6_CHECKSUM offset, or null when the kernel computes none.
pub fn checksumOffset(idx: u32) ?u32 {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return null;
    return sockets[idx].csum_off;
}

/// setsockopt(IPV6_CHECKSUM) that passed policy.checksumOptErrno.
pub fn setChecksumOffset(idx: u32, off: ?u32) bool {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return false;
    sockets[idx].csum_off = off;
    return true;
}

/// Largest message an IPv6 raw send carries (a 1500-byte frame less the IPv6 header).
pub const MAX_MESSAGE6 = 1460;

/// An IPV6_HDRINCL send (rawv6_send_hdrinc): `pkt` is a whole IPv6 packet, header first, that passed policy.hdrinclErrno6. It goes
/// out as written, routed by `dst` (the sendto address or the connected peer), not by its header (icmpv6.sendHdrincl6).
pub fn sendHdrincl6(dst: [16]u8, pkt: []const u8) i64 {
    var buf: [MAX_MESSAGE6 + 40]u8 = undefined;
    if (pkt.len > buf.len) return -90;
    @memcpy(buf[0..pkt.len], pkt);
    const rc = @import("icmpv6.zig").sendHdrincl6(dst, buf[0..pkt.len]);
    if (rc == 0) _ = lo.drain();
    return rc;
}

/// rawv6_sendmsg: `msg` (what follows the IPv6 header, next header `protocol`) from `bound` to `dst`; the kernel writes the checksum
/// at `csum_off` when there is one (icmpv6.sendProto6Ov). `msg` passed policy.lengthErrno6. `hops_ov` / `tclass_ov` are this
/// packet's IPV6_HOPLIMIT / IPV6_TCLASS control messages (null: the socket's value). 0 or -errno.
pub fn send6(bound: [16]u8, dst: [16]u8, protocol: u8, csum_off: ?u32, msg: []const u8, ip: ipo.IpOpts, hops_ov: ?u8, tclass_ov: ?u8) i64 {
    if (msg.len > MAX_MESSAGE6) return -90;
    var buf: [MAX_MESSAGE6]u8 = undefined;
    @memcpy(buf[0..msg.len], msg);
    const rc = @import("icmpv6.zig").sendProto6Ov(bound, dst, protocol, csum_off, buf[0..msg.len], ip, hops_ov, tclass_ov);
    // A frame to this host is delivered before the send returns (as loopback_xmit does), so the copy and the kernel's reply are
    // already queued for the socket.
    if (rc == 0) _ = lo.drain();
    return rc;
}

/// raw_sendmsg: `msg` is the payload of protocol `protocol` (for ICMP the message, header and data). The kernel supplies the IP
/// header; a frame that has to wait for ARP is queued on the neighbour and the send succeeds, exactly like Linux. 0, or -EMSGSIZE
/// past the path MTU, -ENOBUFS when the device drops it.
pub fn send(bound: [4]u8, dst: [4]u8, protocol: u8, msg: []const u8, ip: ipo.IpOpts) i64 {
    if (msg.len > MAX_MESSAGE) return -90;
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
    var pkt: [FRAME_BUF_LEN]u8 = @splat(0);
    @memcpy(pkt[34..][0..msg.len], msg);
    ipv4.buildHeader(pkt[14..].ptr, src, dst, protocol, @intCast(msg.len));
    ipv4.setIdent(pkt[14..].ptr, ipid.unowned(dst, src, protocol, ip.pmtudisc), ipo.datagramDf(ip.pmtudisc));
    if (ipo.ipv4NeedsPatch(ip)) ipo.patchIpv4(pkt[14..][0..20], ip, ipv4.checksum);
    const frame_len = eth.buildFrame(&pkt, dst_mac, our_mac, eth.ETHERTYPE_IPV4, @intCast(20 + msg.len));
    if (wait_hop) |hop| {
        arp.queueFrame(hop, &pkt, frame_len);
        return 0;
    }
    // A loopback frame is delivered at once (lo.sendNow), so the echo request a raw socket just sent is already queued for it when
    // the send returns, as on Linux.
    const ok = if (via_lo) lo.sendNow(&pkt, frame_len) or lo.dropIsLoss(frame_len) else nic.sendPacket(&pkt, frame_len);
    return if (ok) 0 else -105;
}

/// An IP_HDRINCL send (raw_send_hdrinc): `pkt` is a whole IPv4 datagram that passed policy.hdrinclErrno. It is routed by `dst`
/// (the sendto address or the connected peer), not by the header's destination; the kernel fills in a zero source, the total
/// length and the header checksum (policy.completeHdrincl). Past the path MTU is EMSGSIZE.
pub fn sendHdrincl(bound: [4]u8, dst: [4]u8, pkt: []const u8) i64 {
    if (pkt.len > MAX_HDRINCL or pkt.len > ipv4.getSendMtu(dst)) return -90;
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
    var pkt_buf: [FRAME_BUF_LEN]u8 = @splat(0);
    @memcpy(pkt_buf[14..][0..pkt.len], pkt);
    policy.completeHdrinclId(pkt_buf[14..][0..pkt.len], src, if (policy.needsIdent(pkt)) ipid.globalNonzero(dst, src, pkt[9]) else 0);
    const frame_len = eth.buildFrame(&pkt_buf, dst_mac, our_mac, eth.ETHERTYPE_IPV4, @intCast(pkt.len));
    if (wait_hop) |hop| {
        arp.queueFrame(hop, &pkt_buf, frame_len);
        return 0;
    }
    const ok = if (via_lo) lo.sendNow(&pkt_buf, frame_len) or lo.dropIsLoss(frame_len) else nic.sendPacket(&pkt_buf, frame_len);
    return if (ok) 0 else -105;
}

/// The ICMP message part of a received IPv4 datagram (the IP header is `ihl` bytes long).
pub fn icmpMessage(dgram: []const u8) []const u8 {
    if (dgram.len < 20) return dgram[0..0];
    const ihl: usize = @as(usize, dgram[0] & 0x0f) * 4;
    if (ihl < 20 or ihl > dgram.len) return dgram[0..0];
    return dgram[ihl..];
}

comptime {
    // A send's frame must fit the buffer the header is built in.
    if (FRAME_BUF_LEN != 14 + 20 + MAX_MESSAGE) @compileError("raw ICMP frame buffer");
    if (14 + MAX_HDRINCL > FRAME_BUF_LEN) @compileError("IP_HDRINCL frame buffer");
    _ = route4;
}
