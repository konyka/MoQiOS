//! IP_RECVERR error queue of a datagram socket (Linux net/ipv4/ip_sockglue.c ip_icmp_error / ip_recv_error, net/core/skbuff.c
//! sock_queue_err_skb / sock_dequeue_err_skb, net/ipv4/udp.c __udp4_lib_err). With IP_RECVERR an ICMP error about a datagram the
//! socket sent is queued with the quoted payload, connected or not, soft or hard, and sets sk_err; recvmsg(MSG_ERRQUEUE) takes the
//! oldest: the payload, msg_name the original destination, an IP_RECVERR control message (struct sock_extended_err + the sender
//! of the ICMP as a sockaddr_in), MSG_ERRQUEUE in msg_flags. Host-testable.

const std = @import("std");

pub const IP_RECVERR: u64 = 11;
/// The IPv6 option (SOL_IPV6 25) and the origin its entries carry (an ICMPv6 error).
pub const IPV6_RECVERR: u64 = 25;
pub const SO_EE_ORIGIN_ICMP6: u8 = 3;
pub const MSG_ERRQUEUE: u32 = 0x2000;
pub const SO_EE_ORIGIN_ICMP: u8 = 2;
/// Entries a socket keeps at most (Linux bounds the queue only by sk_rcvbuf, see `admits`; this keeps a raised SO_RCVBUF from letting
/// one socket take all memory).
pub const DEPTH: usize = 1024;
/// Quoted bytes kept per entry: icmp_send quotes as much of the datagram as fits in 576 bytes (548 after the IP and ICMP headers),
/// icmp6_send as much as fits in the 1280-byte minimum MTU (1232); what recvmsg(MSG_ERRQUEUE) returns is that less the quoted IP
/// and transport headers (520 bytes of a UDP payload over IPv4, 1184 over IPv6).
pub const PAYLOAD_MAX: usize = 1232;

pub const Entry = struct {
    errno: i32 = 0,
    icmp_type: u8 = 0,
    icmp_code: u8 = 0,
    info: u32 = 0,
    /// Who sent the ICMP error (the offender in the control message) and where the quoted datagram went (msg_name): the first 4
    /// bytes for IPv4, all 16 for IPv6 (`v6`).
    offender: [16]u8 = @splat(0),
    dst: [16]u8 = @splat(0),
    v6: bool = false,
    /// A local error (ip_local_error): origin LOCAL, no offender address.
    local: bool = false,
    dst_port: u16 = 0,
    len: u16 = 0,
    payload: [PAYLOAD_MAX]u8 = @splat(0),
};

/// What a queued error costs the socket's receive buffer (skb->truesize of the cloned ICMP skb, measured with SO_MEMINFO on Linux:
/// 960 for a short quote, 1280 for a full IPv4 one, 2304 for a long IPv6 one).
pub fn truesize(e: *const Entry) u32 {
    const quoted: usize = e.len + (if (e.v6) @as(usize, 48) else 28);
    if (quoted <= 400) return 960;
    if (quoted <= 576) return 1280;
    return 2304;
}

/// sock_queue_err_skb: a new error is refused when it would take the queue past SO_RCVBUF (measured: 8 short errors and 6 full IPv4
/// quotes under SO_RCVBUF 4096, which reads 8192), unless the queue is empty.
pub fn admits(rmem: u32, size: u32, rcvbuf: u32) bool {
    return rmem == 0 or @as(u64, rmem) + size <= rcvbuf;
}

/// A socket's IP_RECVERR queue, oldest first: entries allocated one by one with `alloc` (kmalloc in the kernel), freed by `free`.
pub const Queue = struct {
    head: ?*Node = null,
    tail: ?*Node = null,
    n: u32 = 0,
    rmem: u32 = 0,

    pub const Node = struct { entry: Entry, next: ?*Node = null };
    pub const Alloc = struct {
        alloc: *const fn () ?*Node,
        free: *const fn (*Node) void,
    };

    /// sock_queue_err_skb: append (refused, as a full sk_rcvbuf refuses it, when `rcvbuf` has no room or memory runs out).
    pub fn pushWith(q: *Queue, e: Entry, rcvbuf: u32, a: Alloc) bool {
        const size = truesize(&e);
        if (q.n >= DEPTH or !admits(q.rmem, size, rcvbuf)) return false;
        const node = a.alloc() orelse return false;
        node.* = .{ .entry = e };
        if (q.tail) |t| t.next = node else q.head = node;
        q.tail = node;
        q.n += 1;
        q.rmem += size;
        return true;
    }

    /// sock_dequeue_err_skb: the oldest entry, and the errno sk_err takes after it (the next entry's, or 0).
    pub fn popWith(q: *Queue, a: Alloc) ?struct { entry: Entry, next_err: i32 } {
        const node = q.head orelse return null;
        const e = node.entry;
        q.head = node.next;
        if (q.tail == node) q.tail = null;
        q.n -= 1;
        q.rmem -|= truesize(&e);
        a.free(node);
        return .{ .entry = e, .next_err = if (q.head) |h| h.entry.errno else 0 };
    }

    pub fn clearWith(q: *Queue, a: Alloc) void {
        while (q.head != null) _ = q.popWith(a);
        q.* = .{};
    }
};

pub const SO_EE_ORIGIN_LOCAL: u8 = 1;

/// A UDP datagram of `payload` bytes against a path MTU of `mtu`: null when it can be sent (it fits, or it is fragmented: IP_PMTUDISC_WANT,
/// DONT and OMIT let ip_fragment cut it), else the local error __ip_append_data raises, EMSGSIZE with ee_info = the MTU, for a socket
/// that refuses to fragment (IP_PMTUDISC_DO, PROBE and INTERFACE) or a payload over 65507 bytes
/// (ee_info 0xffff - 20 there). `queue` is whether ip_local_error reaches the error queue: only under DO / PROBE with IP_RECVERR.
pub fn oversize(payload: usize, mtu: u16, pmtudisc: u8, recverr: bool) ?struct { info: u32, queue: bool } {
    if (payload > 65507) return .{ .info = 0xffff - 20, .queue = recverr and (pmtudisc == 2 or pmtudisc == 3) };
    if (20 + 8 + payload <= mtu) return null;
    if (pmtudisc == 0 or pmtudisc == 1 or pmtudisc == 5) return null;
    return .{ .info = mtu, .queue = recverr and (pmtudisc == 2 or pmtudisc == 3) };
}

/// oversize for IPv6 (__ip6_append_data): 40 + 8 header bytes; ee_info is the MTU too.
/// As for IPv4, a datagram over the MTU is fragmented (ip6_fragment, a Fragment header) unless the socket refuses (DO, PROBE,
/// INTERFACE); a payload over 65527 bytes never fits the 16-bit payload length.
pub const Oversize = struct { info: u32, queue: bool };

pub fn oversize6(payload: usize, mtu: u16, pmtudisc: u8, recverr: bool) ?Oversize {
    return oversize6Df(payload, mtu, pmtudisc, recverr, false);
}

/// oversize6 with IPV6_DONTFRAG (`dontfrag`): a datagram over the MTU is refused whatever IPV6_MTU_DISCOVER says (__ip6_append_data
/// checks v6_cork->dontfrag first, then goes to the same ipv6_local_error: queued whenever IPV6_RECVERR is on).
pub fn oversize6Df(payload: usize, mtu: u16, pmtudisc: u8, recverr: bool, dontfrag: bool) ?Oversize {
    if (payload > 65527) return .{ .info = mtu, .queue = recverr and (pmtudisc == 2 or pmtudisc == 3) };
    if (40 + 8 + payload <= mtu) return null;
    if (dontfrag) return .{ .info = mtu, .queue = recverr };
    if (pmtudisc == 0 or pmtudisc == 1 or pmtudisc == 5) return null;
    return .{ .info = mtu, .queue = recverr and (pmtudisc == 2 or pmtudisc == 3) };
}

/// The IPv6 entry ipv6_local_error makes: origin LOCAL, the destination (a sockaddr_in6) and port as msg_name, no payload.
pub fn localEntry6(errno: i32, info: u32, dst: [16]u8, port: u16) Entry {
    return .{ .errno = errno, .info = info, .dst = dst, .dst_port = port, .local = true, .v6 = true };
}

/// The error-queue entry ip_local_error makes: origin LOCAL, the destination and port as msg_name, no payload.
pub fn localEntry(errno: i32, info: u32, dst: [4]u8, port: u16) Entry {
    var e: Entry = .{ .errno = errno, .info = info, .dst_port = port, .local = true };
    @memcpy(e.dst[0..4], &dst);
    return e;
}

/// __udp4_lib_err: whether the error is queued (IP_RECVERR) and whether it becomes sk_err. Without IP_RECVERR only a hard error on a
/// connected socket does; with it every error is queued and sets sk_err.
pub fn route(recverr: bool, hard: bool, connected: bool) struct { queue: bool, set_err: bool } {
    if (recverr) return .{ .queue = true, .set_err = true };
    return .{ .queue = false, .set_err = hard and connected };
}

/// struct sock_extended_err (16 bytes) followed by the offender's address: IP_RECVERR's payload is 32 bytes (a sockaddr_in),
/// IPV6_RECVERR's 44 (a sockaddr_in6: family, port 0, flowinfo 0, the address, scope 0). Returns the bytes and their length.
pub fn encodeExtErr(e: Entry) struct { bytes: [44]u8, len: usize } {
    var out: [44]u8 = @splat(0);
    std.mem.writeInt(u32, out[0..4], @intCast(e.errno), .little);
    out[4] = if (e.local) SO_EE_ORIGIN_LOCAL else if (e.v6) SO_EE_ORIGIN_ICMP6 else SO_EE_ORIGIN_ICMP;
    out[5] = e.icmp_type;
    out[6] = e.icmp_code;
    std.mem.writeInt(u32, out[8..12], e.info, .little);
    if (e.v6) {
        // ipv6_recv_error fills the offender only for an ICMPv6 origin.
        if (!e.local) {
            out[16] = 10; // AF_INET6
            @memcpy(out[24..40], &e.offender);
        }
        return .{ .bytes = out, .len = 44 };
    }
    // ip_recv_error fills the offender only for an ICMP origin (ipv4_datagram_support_cmsg); a local error leaves it zero.
    if (!e.local) {
        out[16] = 2; // AF_INET
        @memcpy(out[20..24], e.offender[0..4]);
    }
    return .{ .bytes = out, .len = 32 };
}

const TestAlloc = struct {
    fn alloc() ?*Queue.Node {
        return std.testing.allocator.create(Queue.Node) catch null;
    }
    fn free(n: *Queue.Node) void {
        std.testing.allocator.destroy(n);
    }
    const a: Queue.Alloc = .{ .alloc = alloc, .free = free };
};

test "the queue keeps order and sk_err follows its head" {
    var q: Queue = .{};
    defer q.clearWith(TestAlloc.a);
    try std.testing.expect(q.pushWith(.{ .errno = 111 }, 212992, TestAlloc.a));
    try std.testing.expect(q.pushWith(.{ .errno = 113 }, 212992, TestAlloc.a));
    const x = q.popWith(TestAlloc.a).?;
    try std.testing.expectEqual(@as(i32, 111), x.entry.errno);
    try std.testing.expectEqual(@as(i32, 113), x.next_err);
    try std.testing.expectEqual(@as(i32, 0), q.popWith(TestAlloc.a).?.next_err);
    try std.testing.expect(q.popWith(TestAlloc.a) == null);
}

test "SO_RCVBUF bounds the queue: 221 short errors, 166 full IPv4 quotes in the default 212992 bytes (Linux counts 960 and 1280)" {
    var q: Queue = .{};
    defer q.clearWith(TestAlloc.a);
    var n: usize = 0;
    while (q.pushWith(.{ .len = 1 }, 212992, TestAlloc.a)) n += 1;
    try std.testing.expectEqual(@as(usize, 221), n);
    q.clearWith(TestAlloc.a);
    n = 0;
    while (q.pushWith(.{ .len = 520 }, 212992, TestAlloc.a)) n += 1;
    try std.testing.expectEqual(@as(usize, 166), n);
    try std.testing.expectEqual(@as(u32, 2304), truesize(&.{ .len = 1184, .v6 = true }));
    q.clearWith(TestAlloc.a);
    n = 0;
    while (q.pushWith(.{ .len = 1 }, 8192, TestAlloc.a)) n += 1;
    try std.testing.expectEqual(@as(usize, 8), n);
    q.clearWith(TestAlloc.a);
    n = 0;
    while (q.pushWith(.{ .len = 520 }, 8192, TestAlloc.a)) n += 1;
    try std.testing.expectEqual(@as(usize, 6), n);
}

test "an oversized datagram is a local EMSGSIZE, queued only under DO/PROBE with IP_RECVERR" {
    try std.testing.expect(oversize(1472, 1500, 1, true) == null);
    const o = oversize(1473, 1500, 2, true).?;
    try std.testing.expectEqual(@as(u32, 1500), o.info);
    try std.testing.expect(o.queue);
    // WANT (1) fragments now (hello452): no local error at all; PROBE (3) refuses and queues with IP_RECVERR.
    try std.testing.expect(oversize(1600, 1500, 1, true) == null);
    try std.testing.expect(oversize(1600, 1500, 3, true).?.queue);
    try std.testing.expect(!oversize(1600, 1500, 2, false).?.queue);
    const b = encodeExtErr(localEntry(90, 1500, .{ 127, 0, 0, 1 }, 47491));
    try std.testing.expectEqual(@as(u8, SO_EE_ORIGIN_LOCAL), b.bytes[4]);
    try std.testing.expectEqual(@as(u32, 1500), std.mem.readInt(u32, b.bytes[8..12], .little));
    try std.testing.expectEqual(@as(u8, 0), b.bytes[16]);
}

test "routing and the extended error layout" {
    try std.testing.expect(route(true, false, false).queue);
    try std.testing.expect(!route(false, true, false).set_err);
    try std.testing.expect(route(false, true, true).set_err);
    var off: [16]u8 = @splat(0);
    off[0] = 127;
    off[3] = 1;
    const b = encodeExtErr(.{ .errno = 111, .icmp_type = 3, .icmp_code = 3, .offender = off });
    try std.testing.expectEqual(@as(usize, 32), b.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x6f, 0, 0, 0, 2, 3, 3, 0 }, b.bytes[0..8]);
    try std.testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0, 127, 0, 0, 1 }, b.bytes[16..24]);
    var one6: [16]u8 = @splat(0);
    one6[15] = 1;
    const b6 = encodeExtErr(.{ .errno = 111, .icmp_type = 1, .icmp_code = 4, .offender = one6, .v6 = true });
    try std.testing.expectEqual(@as(usize, 44), b6.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x6f, 0, 0, 0, 3, 1, 4, 0 }, b6.bytes[0..8]);
    try std.testing.expectEqual(@as(u8, 10), b6.bytes[16]);
    try std.testing.expectEqual(@as(u8, 1), b6.bytes[39]);
}
