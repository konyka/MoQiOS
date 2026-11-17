//! Raw ICMP sockets: IPv4 (socket(AF_INET, SOCK_RAW, IPPROTO_ICMP), Linux net/ipv4/raw.c) and IPv6 (socket(AF_INET6, SOCK_RAW,
//! IPPROTO_ICMPV6), net/ipv6/raw.c). Every ICMP datagram this host receives is copied, IP header included, to each IPv4 socket whose
//! bound address and connected peer match (raw_icmp_policy.matches); every ICMPv6 message, without its IPv6 header, to each IPv6
//! socket that matches and whose ICMP6_FILTER lets the type through. A send gets its IP header (and for ICMPv6 its checksum) from the
//! kernel. The sockets share one table; a socket lives until its last descriptor reference is gone, which is
//! what lets a fork keep it. The raw Ethernet frame ioctl-style socket this replaced (read/write on the NIC) is gone.
const policy = @import("raw_icmp_policy.zig");
const ipv4 = @import("ipv4.zig");
const netif = @import("netif.zig");
const nic = @import("nic.zig");
const lo = @import("lo.zig");
const arp = @import("arp.zig");
const eth = @import("eth.zig");
const route4 = @import("route4_policy.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

/// Raw ICMP sockets at once (each queues up to QUEUE_DEPTH datagrams of RAW_QUEUE_LEN bytes: about 200 KiB in all).
pub const MAX_SOCKETS = 16;
const QUEUE_DEPTH = 8;
pub const RAW_QUEUE_LEN = 1500;
/// Largest ICMP message a send carries (1472-byte UDP payload and ICMP header: the same bound the ping sockets use).
pub const MAX_MESSAGE = 1480;
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
    bound6: [16]u8 = @splat(0),
    peer6: [16]u8 = @splat(0),
    /// connect() named a peer (an IPv6 socket may be connected to ::).
    connected: bool = false,
    filter: [policy.FILTER_LEN]u8 = @splat(0),
    shut_rd: bool = false,
    shut_wr: bool = false,
    queue: [QUEUE_DEPTH]Entry = @splat(.{}),
};

var sockets: [MAX_SOCKETS]Socket = @splat(.{});
var raw_lock: IrqSpinlock = .{};

/// A new socket (an IPv6 one when `v6`) on the first free slot, or null (ENOBUFS). Nothing is shared with a UDP socket.
pub fn open(v6: bool) ?u32 {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    for (&sockets, 0..) |*s, i| {
        if (s.used) continue;
        s.* = .{ .used = true, .refs = 1, .v6 = v6 };
        return @intCast(i);
    }
    return null;
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

/// Whether a datagram is queued for the socket (poll, and the wait in a blocking recv).
pub fn hasData(idx: u32) bool {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return false;
    for (sockets[idx].queue) |e| {
        if (e.len != 0) return true;
    }
    return false;
}

pub const RecvResult = union(enum) {
    ok: struct { n: usize, src: [16]u8, trunc: usize },
    eagain,
};

/// Take the oldest queued datagram into `out`: `n` bytes of it, and `trunc` — the datagram's whole length as MSG_TRUNC reports it.
pub fn recv(idx: u32, out: []u8) RecvResult {
    const saved = raw_lock.acquire();
    defer raw_lock.release(saved);
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return .eagain;
    const s = &sockets[idx];
    for (&s.queue) |*e| {
        if (e.len == 0) continue;
        const copy_len = @min(@as(usize, e.len), out.len);
        @memcpy(out[0..copy_len], e.dgram[0..copy_len]);
        const result: RecvResult = .{ .ok = .{ .n = copy_len, .src = e.src, .trunc = e.len } };
        e.len = 0;
        return result;
    }
    return .eagain;
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
    var has = false;
    for (s.queue) |e| {
        if (e.len != 0) has = true;
    }
    return policy.pollBits(has, s.shut_rd, s.shut_wr);
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

/// One received ICMP datagram that arrived on this host: `dgram` starts at the IP header of `src` → `dst` (Linux raw_v4_input hands
/// raw sockets the skb, IP header included). Each matching socket gets its own copy; a full queue drops the datagram.
pub fn deliver(dgram: []const u8, src: [4]u8, dst: [4]u8) void {
    var notify: [MAX_SOCKETS]u32 = undefined;
    var n_notify: usize = 0;
    {
        const saved = raw_lock.acquire();
        defer raw_lock.release(saved);
        for (&sockets, 0..) |*s, i| {
            if (!s.used) continue;
            if (s.v6) continue;
            if (!policy.matches(s.bound, s.peer, src, dst)) continue;
            for (&s.queue) |*e| {
                if (e.len != 0) continue;
                const copy_len = @min(dgram.len, RAW_QUEUE_LEN);
                @memcpy(e.dgram[0..copy_len], dgram[0..copy_len]);
                e.len = @intCast(copy_len);
                e.src = @splat(0);
                @memcpy(e.src[0..4], &src);
                notify[n_notify] = @intCast(i);
                n_notify += 1;
                break;
            }
        }
    }
    for (notify[0..n_notify]) |idx| {
        // The index is the socket's identity here: a slot freed since holds a different socket, which gets a needless wake at worst.
        @import("epoll.zig").epollNotify(.raw_socket, idx, @import("epoll.zig").EPOLLIN);
    }
}

/// One checksummed ICMPv6 message that arrived on this host, `src` → `dst` (Linux icmpv6_rcv → raw6_local_deliver, before the
/// kernel's own handling): each IPv6 socket that matches and whose ICMP6_FILTER passes the type gets a copy without the IPv6 header.
pub fn deliver6(msg: []const u8, src: [16]u8, dst: [16]u8) void {
    if (msg.len == 0) return;
    var notify: [MAX_SOCKETS]u32 = undefined;
    var n_notify: usize = 0;
    {
        const saved = raw_lock.acquire();
        defer raw_lock.release(saved);
        for (&sockets, 0..) |*s, i| {
            if (!s.used or !s.v6) continue;
            if (!policy.matches6(s.bound6, s.peer6, src, dst)) continue;
            if (policy.filterBlocks(s.filter, msg[0])) continue;
            for (&s.queue) |*e| {
                if (e.len != 0) continue;
                const copy_len = @min(msg.len, RAW_QUEUE_LEN);
                @memcpy(e.dgram[0..copy_len], msg[0..copy_len]);
                e.len = @intCast(copy_len);
                e.src = src;
                notify[n_notify] = @intCast(i);
                n_notify += 1;
                break;
            }
        }
    }
    for (notify[0..n_notify]) |idx| {
        @import("epoll.zig").epollNotify(.raw_socket, idx, @import("epoll.zig").EPOLLIN);
    }
}

/// Largest ICMPv6 message an IPv6 raw send carries (a 1500-byte frame less the IPv6 header).
pub const MAX_MESSAGE6 = 1460;

/// rawv6_sendmsg: `msg` (the ICMPv6 message) from `bound` to `dst`; the kernel fills the checksum (icmpv6.sendFrom6). 0 or -errno.
pub fn send6(bound: [16]u8, dst: [16]u8, msg: []const u8) i64 {
    if (msg.len > MAX_MESSAGE6) return -90;
    var buf: [MAX_MESSAGE6]u8 = undefined;
    @memcpy(buf[0..msg.len], msg);
    const rc = @import("icmpv6.zig").sendFrom6(bound, dst, buf[0..msg.len]);
    // A frame to this host is delivered before the send returns (as loopback_xmit does), so the copy and the kernel's reply are
    // already queued for the socket.
    if (rc == 0) _ = lo.drain();
    return rc;
}

/// raw_sendmsg: `msg` is the ICMP message (header and data). The kernel supplies the IP header; a frame that has to wait for ARP
/// is queued on the neighbour and the send succeeds, exactly like Linux. 0, or -EMSGSIZE past the path MTU, -ENOBUFS when the
/// device drops it.
pub fn send(bound: [4]u8, dst: [4]u8, msg: []const u8) i64 {
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
    ipv4.buildHeader(pkt[14..].ptr, src, dst, ipv4.PROTO_ICMP, @intCast(msg.len));
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
    _ = route4;
}
