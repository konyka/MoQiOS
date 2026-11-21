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
const iop = @import("ip_options_policy.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

/// Raw sockets at once. Each queues its datagrams in kmalloc'd entries (RAW_QUEUE_LEN bytes inline, longer ones in a buffer of
/// their own), as many as its SO_RCVBUF holds (udp_rmem_policy.rawAdmits), at most QUEUE_MAX.
pub const MAX_SOCKETS = 16;
const QUEUE_MAX = 4096;
pub const RAW_QUEUE_LEN = 1500;
/// Largest datagram a raw socket keeps whole: a reassembled IPv4 datagram (total length) or IPv6 payload.
pub const RAW_BIG_LEN = 65535;
/// A queued datagram longer than RAW_QUEUE_LEN (only reassembly makes one) gets a kmalloc buffer of its own; how many a socket keeps
/// is bounded by its SO_RCVBUF (udp_rmem_policy.rawAdmits). Without memory for it, it is kept cut to RAW_QUEUE_LEN bytes.
/// Largest ICMP message a send carries (1472-byte UDP payload and ICMP header: the same bound the ping sockets use).
pub const MAX_MESSAGE = 1480;
/// Largest datagram an IP_HDRINCL send writes whole (header included): one Ethernet MTU.
pub const MAX_HDRINCL = 20 + MAX_MESSAGE;
/// The frame buffer of a send: ethernet, IPv4 and ICMP headers in front of the message.
const FRAME_BUF_LEN = 14 + 20 + MAX_MESSAGE;

const Entry = struct {
    dgram: [RAW_QUEUE_LEN]u8 = @splat(0),
    /// The datagram's whole length; past RAW_QUEUE_LEN the bytes are in `big`.
    len: u16 = 0,
    big: ?[*]u8 = null,
    /// The sender: an IPv4 address in the first 4 bytes, or an IPv6 one.
    src: [16]u8 = @splat(0),
    /// What the datagram arrived with, for recvmsg's IP_PKTINFO / IP_TTL / IP_TOS (an IPv4 socket) or IPV6_PKTINFO /
    /// IPV6_HOPLIMIT / IPV6_TCLASS (an IPv6 one).
    meta: @import("ip_cmsg_policy.zig").RecvInfo = .{},
    meta6: @import("ip_cmsg_policy.zig").RecvInfo6 = .{},
    /// The next datagram of the same socket (oldest first).
    next: ?*Entry = null,
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
    /// The receive queue (sk_receive_queue), oldest first: `count` entries costing `rmem` (sk_rmem_alloc).
    head: ?*Entry = null,
    tail: ?*Entry = null,
    count: u32 = 0,
    rmem: u32 = 0,
    /// The pending error (sk_err) an ICMP error left, reported once by SO_ERROR, the next recv or send; and the IP_RECVERR queue.
    err: i32 = 0,
    errq: @import("errqueue_policy.zig").Queue = .{},
    /// np->rxpmtu: the last IPV6_DONTFRAG refusal of an IPV6_RECVPATHMTU socket, for one recvmsg.
    rxpmtu: @import("udp.zig").RxPmtu = .{},
    /// IP_OPTIONS (inet->inet_opt) as ip_options_policy.compileForSend left them; `ipopts_set` once any IP_OPTIONS call stored a
    /// value, even an empty one (raw_send_hdrinc refuses an IP_HDRINCL send while inet_opt exists).
    ipopts: iop.SendOpts = .{},
    ipopts_set: bool = false,
};

var sockets: [MAX_SOCKETS]Socket = @splat(.{});
var raw_lock: IrqSpinlock = .{};

/// Store `bytes` in queue entry `e` (raw_lock held): inline when it fits, else in a free big buffer, else cut to RAW_QUEUE_LEN.
fn store(e: *Entry, bytes: []const u8) void {
    store2(e, bytes, &.{});
}

/// store for a datagram held in two parts, `head` then `tail` (a header rewritten apart from the frame, then the payload).
fn store2(e: *Entry, head: []const u8, tail: []const u8) void {
    const n = @min(head.len + tail.len, RAW_BIG_LEN);
    e.big = null;
    const dst: []u8 = blk: {
        if (n > RAW_QUEUE_LEN) {
            if (@import("../mm/slab.zig").kmalloc(n)) |raw| {
                const p: [*]u8 = @ptrCast(raw);
                e.big = p;
                break :blk p[0..n];
            }
        }
        break :blk e.dgram[0..@min(n, RAW_QUEUE_LEN)];
    };
    const h = @min(head.len, dst.len);
    @memcpy(dst[0..h], head[0..h]);
    @memcpy(dst[h..], tail[0 .. dst.len - h]);
    e.len = @intCast(dst.len);
}

/// A new entry at the tail of `s`'s queue (raw_lock held), or null when SO_RCVBUF is reached (__sock_queue_rcv_skb), the queue holds
/// QUEUE_MAX datagrams or no memory is to be had. The caller stores the datagram and charges it with `charge`.
fn newEntry(s: *Socket) ?*Entry {
    if (!@import("udp_rmem_policy.zig").rawAdmits(s.rmem, s.opts.rcvbuf) or s.count >= QUEUE_MAX) return null;
    const raw = @import("../mm/slab.zig").kmalloc(@sizeOf(Entry)) orelse return null;
    const e: *Entry = @ptrCast(@alignCast(raw));
    e.* = .{};
    if (s.tail) |t| t.next = e else s.head = e;
    s.tail = e;
    s.count += 1;
    return e;
}

/// Count a stored entry's cost against its socket (raw_lock held).
fn charge(s: *Socket, e: *const Entry) void {
    s.rmem +|= @import("udp_rmem_policy.zig").rawTruesize(e.len);
}

/// Take the oldest entry off `s`'s queue and free it (raw_lock held).
fn popEntry(s: *Socket) void {
    const e = s.head orelse return;
    s.head = e.next;
    if (s.tail == e) s.tail = null;
    s.count -= 1;
    s.rmem -|= @import("udp_rmem_policy.zig").rawTruesize(e.len);
    dropEntry(e);
    @import("../mm/slab.zig").kfree(e);
}

fn bytesOf(e: *const Entry) []const u8 {
    if (e.big) |p| return p[0..e.len];
    return e.dgram[0..e.len];
}

/// Give back an entry's big buffer (raw_lock held): it was read, or its socket is going away.
fn dropEntry(e: *Entry) void {
    if (e.big) |p| @import("../mm/slab.zig").kfree(p);
    e.big = null;
}

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
    const s = &sockets[idx];
    while (s.head != null) popEntry(s);
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
/// setsockopt(IP_OPTIONS) on raw socket `idx`; false for a slot not in use.
pub fn setIpOptions(idx: u32, so: iop.SendOpts) bool {
    if (idx >= MAX_SOCKETS) return false;
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (!sockets[idx].used) return false;
    sockets[idx].ipopts = so;
    sockets[idx].ipopts_set = true;
    return true;
}

/// The IP_OPTIONS of raw socket `idx` (len 0: none), and whether any were ever set.
pub fn getIpOptions(idx: u32) ?struct { so: iop.SendOpts, set: bool } {
    if (idx >= MAX_SOCKETS) return null;
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (!sockets[idx].used) return null;
    return .{ .so = sockets[idx].ipopts, .set = sockets[idx].ipopts_set };
}

pub fn hasData(idx: u32) bool {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return false;
    return sockets[idx].count != 0;
}

pub const RecvResult = union(enum) {
    ok: struct { n: usize, src: [16]u8, trunc: usize, meta: @import("ip_cmsg_policy.zig").RecvInfo = .{}, meta6: @import("ip_cmsg_policy.zig").RecvInfo6 = .{} },
    eagain,
};

/// Copy the oldest queued datagram into `out`: `n` bytes of it, and `trunc` — the datagram's whole length as MSG_TRUNC reports it.
/// A read takes it off the queue; `peek` (MSG_PEEK) leaves it there for the next receive.
pub fn recv(idx: u32, out: []u8, peek: bool) RecvResult {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return .eagain;
    const s = &sockets[idx];
    const e = s.head orelse return .eagain;
    const bytes = bytesOf(e);
    const copy_len = @min(bytes.len, out.len);
    @memcpy(out[0..copy_len], bytes[0..copy_len]);
    const result: RecvResult = .{ .ok = .{ .n = copy_len, .src = e.src, .trunc = e.len, .meta = e.meta, .meta6 = e.meta6 } };
    if (!peek) popEntry(s);
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
    // A pending error or a queued one is POLLERR (datagram_poll: sk_err or a non-empty error queue).
    const err_bit: u32 = if (s.err != 0 or s.errq.n != 0) 0x008 else 0;
    return policy.pollBits(s.count != 0, s.shut_rd, s.shut_wr) | err_bit;
}

/// raw_err (Linux net/ipv4/raw.c, via raw_icmp_error) for every IPv4 raw socket of the quoted datagram's protocol whose bound address
/// and peer match it: one with IP_RECVERR queues the error (payload from the quoted transport header, the quoted IP header too for
/// IP_HDRINCL) and takes it as its pending error; one without takes only a hard error, and only when connected. Source quench and
/// redirect are no error for a raw socket.
pub fn notifyIcmpError(protocol: u8, quoted_src: [4]u8, quoted_dst: [4]u8, icmp_type: u8, icmp_code: u8, base: @import("udp.zig").IcmpError, quoted_ip: []const u8, quoted_l4: []const u8) void {
    const errq = @import("errqueue_policy.zig");
    var notify: [MAX_SOCKETS]u32 = undefined;
    var n: usize = 0;
    {
        const saved = raw_lock.acquire();
        defer raw_lock.release(saved);
        for (&sockets, 0..) |*s, i| {
            if (!s.used or s.v6 or s.protocol != protocol) continue;
            // raw_v4_match on the quoted datagram: it was sent from the socket's bound address to its peer.
            if (!policy.matches(s.bound, s.peer, quoted_dst, quoted_src)) continue;
            const recverr = s.opts.ip.recverr;
            if (!recverr and !s.connected) continue;
            const conv = @import("icmp_unreach_policy.zig").rawErrorFor(icmp_type, icmp_code, s.opts.ip.pmtudisc == 0) orelse continue;
            var e = base;
            e.errno = conv.errno;
            e.hard = conv.hard;
            if (recverr) {
                var ent: errq.Entry = .{ .errno = e.errno, .icmp_type = e.icmp_type, .icmp_code = e.icmp_code, .info = e.info, .dst_port = 0 };
                @memcpy(ent.offender[0..4], &e.offender);
                @memcpy(ent.dst[0..4], &quoted_dst);
                const body = if (s.opts.ip.hdrincl) quoted_ip else quoted_l4;
                const k = @min(body.len, errq.PAYLOAD_MAX);
                ent.len = @intCast(k);
                @memcpy(ent.payload[0..k], body[0..k]);
                _ = s.errq.push(ent);
            }
            if (!(recverr or e.hard)) continue;
            s.err = e.errno;
            notify[n] = @intCast(i);
            n += 1;
        }
    }
    for (notify[0..n]) |idx| @import("epoll.zig").epollNotify(.raw_socket, idx, @import("epoll.zig").EPOLLERR);
}

/// raw6_icmp_error → rawv6_err: as notifyIcmpError, for the IPv6 raw sockets of next header `nexthdr` that match the quoted packet
/// (raw_v6_match). `quoted_ip` starts at the quoted IPv6 header, `quoted_l4` after its extension headers.
pub fn notifyIcmpError6(nexthdr: u8, quoted_src: [16]u8, quoted_dst: [16]u8, icmp_type: u8, icmp_code: u8, info: u32, offender: [16]u8, quoted_ip: []const u8, quoted_l4: []const u8) void {
    const errq = @import("errqueue_policy.zig");
    var notify: [MAX_SOCKETS]u32 = undefined;
    var n: usize = 0;
    {
        const saved = raw_lock.acquire();
        defer raw_lock.release(saved);
        for (&sockets, 0..) |*s, i| {
            if (!s.used or !s.v6 or s.protocol != nexthdr) continue;
            if (!policy.matches6(s.bound6, s.peer6, quoted_dst, quoted_src)) continue;
            const recverr = s.opts.ip.recverr6;
            if (!recverr and !s.connected) continue;
            const conv = @import("icmp_unreach_policy.zig").rawErrorFor6(icmp_type, icmp_code, s.opts.ip.pmtudisc6 == 2);
            if (recverr) {
                var ent: errq.Entry = .{ .errno = conv.errno, .icmp_type = icmp_type, .icmp_code = icmp_code, .info = info, .offender = offender, .dst = quoted_dst, .dst_port = 0, .v6 = true };
                const body = if (s.opts.ip.hdrincl) quoted_ip else quoted_l4;
                const k = @min(body.len, errq.PAYLOAD_MAX);
                ent.len = @intCast(k);
                @memcpy(ent.payload[0..k], body[0..k]);
                _ = s.errq.push(ent);
            }
            if (!(recverr or conv.hard)) continue;
            s.err = conv.errno;
            notify[n] = @intCast(i);
            n += 1;
        }
    }
    for (notify[0..n]) |idx| @import("epoll.zig").epollNotify(.raw_socket, idx, @import("epoll.zig").EPOLLERR);
}

/// The pending error, taken (sock_error: a recv or send reports it once) or only looked at (SO_ERROR's getsockopt peeks, then clears).
pub fn takeError(idx: u32, clear: bool) i32 {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return 0;
    const e = sockets[idx].err;
    if (clear) sockets[idx].err = 0;
    return e;
}

/// ipv6_local_rxpmtu for a raw socket.
pub fn setRxPmtu(idx: u32, n: @import("udp.zig").RxPmtu) void {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx < MAX_SOCKETS and sockets[idx].used) sockets[idx].rxpmtu = n;
}

/// ipv6_recv_rxpmtu for a raw socket: take the pending notice, or null.
pub fn takeRxPmtu(idx: u32) ?@import("udp.zig").RxPmtu {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used or !sockets[idx].rxpmtu.valid) return null;
    const n = sockets[idx].rxpmtu;
    sockets[idx].rxpmtu = .{};
    return n;
}

/// ipv6_local_error / ip_local_error: queue a locally raised error (EMSGSIZE) for an IP_RECVERR / IPV6_RECVERR socket.
pub fn queueLocalError(idx: u32, e: @import("errqueue_policy.zig").Entry) void {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx < MAX_SOCKETS and sockets[idx].used) _ = sockets[idx].errq.push(e);
}

/// Make `e` the socket's pending error (do_recvmmsg's sk_err after a batch that failed part-way).
pub fn setError(idx: u32, e: i32) void {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx < MAX_SOCKETS and sockets[idx].used) sockets[idx].err = e;
}

/// SO_ERROR's clear after the read: only the error it reported, not one that arrived since.
pub fn clearErrorIfEqual(idx: u32, e: i32) void {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx < MAX_SOCKETS and sockets[idx].used and sockets[idx].err == e) sockets[idx].err = 0;
}

/// recvmsg(MSG_ERRQUEUE): the oldest queued error; the pending error becomes the next one's (sock_dequeue_err_skb).
pub fn takeQueuedError(idx: u32) ?@import("errqueue_policy.zig").Entry {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return null;
    const r = sockets[idx].errq.pop() orelse return null;
    sockets[idx].err = r.next_err;
    return r.entry;
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
/// a datagram no protocol handles is then not answered with protocol unreachable. `ifindex` is the interface it arrived on.
pub fn deliver(protocol: u8, dgram: []const u8, src: [4]u8, dst: [4]u8, ifindex: u8) bool {
    return deliverInfo(protocol, dgram, src, dst, .{ .ifindex = ifindex, .dst = dst, .ttl = if (dgram.len > 8) dgram[8] else 0, .tos = if (dgram.len > 1) dgram[1] else 0 });
}

/// deliver with what the datagram arrived with (interface, destination, TTL, TOS and its compiled IP options, for IP_RECVOPTS and
/// IP_RETOPTS); `dgram` carries the options as compiled too (raw_rcv hands over the skb after ip_rcv_options).
pub fn deliverInfo(protocol: u8, dgram: []const u8, src: [4]u8, dst: [4]u8, meta: @import("ip_cmsg_policy.zig").RecvInfo) bool {
    return deliverHdr(protocol, dgram, &.{}, src, dst, meta);
}

/// deliverInfo for a datagram whose IP header `hdr` (options included) is held apart from `payload`.
pub fn deliverHdr(protocol: u8, hdr: []const u8, payload: []const u8, src: [4]u8, dst: [4]u8, meta: @import("ip_cmsg_policy.zig").RecvInfo) bool {
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
            if (protocol == policy.IPPROTO_ICMP) if (icmpType(hdr, payload)) |ty| if (policy.icmpFilterBlocks(s.icmp_filter, ty)) continue;
            const e = newEntry(s) orelse continue;
            store2(e, hdr, payload);
            charge(s, e);
            e.src = @splat(0);
            @memcpy(e.src[0..4], &src);
            e.meta = meta;
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

/// The ICMP type of a datagram held as `hdr` then `payload` (policy.icmpTypeOf when it is all in `hdr`).
fn icmpType(hdr: []const u8, payload: []const u8) ?u8 {
    if (payload.len == 0) return policy.icmpTypeOf(hdr);
    if (hdr.len < 20 or payload.len < 8) return null;
    return payload[0];
}

/// One IPv6 packet of next header `protocol` that arrived on this host, `src` → `dst`, `msg` being what follows its IPv6 header
/// (Linux raw6_local_deliver, before the protocol handler): each IPv6 socket of that protocol that matches gets a copy. An ICMPv6
/// socket's ICMP6_FILTER may block the type; a socket with a checksum offset drops a packet whose checksum is wrong (rawv6_rcv).
/// Whether any socket matched (ipv6_raw_deliver's `delivered`). `ifindex`, `hops` and `tclass` are the interface it arrived on and
/// its IPv6 header's hop limit and traffic class.
pub fn deliver6(protocol: u8, msg: []const u8, src: [16]u8, dst: [16]u8, ifindex: u8, hops: u8, tclass: u8) bool {
    return deliver6Flow(protocol, msg, src, dst, ifindex, hops, tclass, 0);
}

/// deliver6 with the packet's flowinfo (traffic class and flow label), for IPV6_FLOWINFO on receive.
pub fn deliver6Flow(protocol: u8, msg: []const u8, src: [16]u8, dst: [16]u8, ifindex: u8, hops: u8, tclass: u8, flowinfo: u32) bool {
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
            const e = newEntry(s) orelse continue;
            store(e, msg);
            charge(s, e);
            e.src = src;
            e.meta6 = .{ .ifindex = ifindex, .dst = dst, .hops = hops, .tclass = tclass, .flowinfo = flowinfo };
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
    if (msg.len > policy.MAX_PAYLOAD6) return -90;
    // The checksum is written into the copy; one longer than a frame (fragmented when it goes) is staged in kmalloc.
    var small: [MAX_MESSAGE6]u8 = undefined;
    const slab = @import("../mm/slab.zig");
    const big = msg.len > small.len;
    const buf: []u8 = if (big) @as([*]u8, @ptrCast(slab.kmalloc(msg.len) orelse return -105))[0..msg.len] else small[0..msg.len];
    defer if (big) slab.kfree(buf.ptr);
    @memcpy(buf[0..msg.len], msg);
    const rc = @import("icmpv6.zig").sendProto6Ov(bound, dst, protocol, csum_off, buf[0..msg.len], ip, hops_ov, tclass_ov);
    // A frame to this host is delivered before the send returns (as loopback_xmit does), so the copy and the kernel's reply are
    // already queued for the socket.
    if (rc == 0) _ = lo.drain();
    return rc;
}

/// raw_sendmsg: `msg` is the payload of protocol `protocol` (for ICMP the message, header and data). The kernel supplies the IP
/// header; a frame that has to wait for ARP is queued on the neighbour and the send succeeds, exactly like Linux. A datagram past the
/// path MTU is fragmented (ip_append_data) unless IP_MTU_DISCOVER refuses it (policy.oversizeErrno4). 0, or -EMSGSIZE, -ENOBUFS
/// when the device drops it.
pub fn send(bound: [4]u8, dst: [4]u8, protocol: u8, msg: []const u8, ip: ipo.IpOpts) i64 {
    return sendOpts(bound, dst, protocol, msg, ip, null);
}

/// send with IPv4 options (ipc.opt: an IP_RETOPTS control message's, else the socket's IP_OPTIONS): they follow the 20-byte header,
/// built for this datagram (ip_options_build), and a source route sends to its first hop.
pub fn sendOpts(bound: [4]u8, dst_in: [4]u8, protocol: u8, msg: []const u8, ip: ipo.IpOpts, ipopts: ?iop.SendOpts) i64 {
    const dst = if (ipopts) |so| (if (so.o.srr != null) so.faddr else dst_in) else dst_in;
    const optlen: usize = if (ipopts) |so| so.len else 0;
    const mtu = ipv4.getSendMtu(dst);
    if (msg.len + optlen > policy.MAX_PAYLOAD4) return -90;
    const orc = policy.oversizeErrno4(msg.len + optlen, mtu, ip.pmtudisc);
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
        // ip_append_data → ip_fragment: the datagram leaves in pieces, without DF (it is only set on a datagram within the MTU) and
        // with an id from the shared generator (ip_select_ident: a datagram that may be fragmented always gets one).
        var hdr: [20]u8 = undefined;
        ipv4.buildHeader(&hdr, src, dst, protocol, 0);
        if (big) ipv4.setIdent(&hdr, ipid.global(dst, src, protocol), false) else ipv4.setIdent(&hdr, ipid.unowned(dst, src, protocol, ip.pmtudisc), ipo.datagramDf(ip.pmtudisc));
        if (ipo.ipv4NeedsPatch(ip)) ipo.patchIpv4(&hdr, ip, ipv4.checksum);
        var built: [40]u8 = @splat(0);
        if (ipopts) |so| iop.build(so, src, dst_in, iop.msSinceMidnight(@import("../proc/time_syscall.zig").wallClockNanos()), &built);
        const ok = @import("ip_frag.zig").send4(hdr, built[0..optlen], msg, mtu, dst_mac, our_mac, via_lo, wait_hop);
        return if (ok) 0 else -105;
    }
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
