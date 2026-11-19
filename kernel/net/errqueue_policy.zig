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
    out[4] = if (e.v6) SO_EE_ORIGIN_ICMP6 else SO_EE_ORIGIN_ICMP;
    out[5] = e.icmp_type;
    out[6] = e.icmp_code;
    std.mem.writeInt(u32, out[8..12], e.info, .little);
    if (e.v6) {
        out[16] = 10; // AF_INET6
        @memcpy(out[24..40], &e.offender);
        return .{ .bytes = out, .len = 44 };
    }
    out[16] = 2; // AF_INET
    @memcpy(out[20..24], e.offender[0..4]);
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
