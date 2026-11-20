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
/// Entries a socket keeps (Linux bounds the queue by sk_rcvbuf; this one is fixed).
pub const DEPTH: usize = 4;
/// Quoted payload kept per entry: an ICMP error quotes at least 8 bytes after the UDP header, and this stack only builds short ones.
pub const PAYLOAD_MAX: usize = 64;

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
    len: u8 = 0,
    payload: [PAYLOAD_MAX]u8 = @splat(0),
};

pub const Queue = struct {
    items: [DEPTH]Entry = @splat(.{}),
    n: u8 = 0,

    /// sock_queue_err_skb: append (a full queue drops the new entry, as a full sk_rcvbuf does).
    pub fn push(q: *Queue, e: Entry) bool {
        if (q.n == DEPTH) return false;
        q.items[q.n] = e;
        q.n += 1;
        return true;
    }

    /// sock_dequeue_err_skb: the oldest entry, and the errno sk_err takes after it (the next entry's, or 0).
    pub fn pop(q: *Queue) ?struct { entry: Entry, next_err: i32 } {
        if (q.n == 0) return null;
        const e = q.items[0];
        var i: usize = 1;
        while (i < q.n) : (i += 1) q.items[i - 1] = q.items[i];
        q.n -= 1;
        return .{ .entry = e, .next_err = if (q.n > 0) q.items[0].errno else 0 };
    }

    pub fn clear(q: *Queue) void {
        q.n = 0;
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

test "the queue keeps order and sk_err follows its head" {
    var q: Queue = .{};
    try std.testing.expect(q.push(.{ .errno = 111 }));
    try std.testing.expect(q.push(.{ .errno = 113 }));
    const a = q.pop().?;
    try std.testing.expectEqual(@as(i32, 111), a.entry.errno);
    try std.testing.expectEqual(@as(i32, 113), a.next_err);
    try std.testing.expectEqual(@as(i32, 0), q.pop().?.next_err);
    try std.testing.expect(q.pop() == null);
    for (0..DEPTH) |_| try std.testing.expect(q.push(.{}));
    try std.testing.expect(!q.push(.{}));
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
