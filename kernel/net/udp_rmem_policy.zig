//! What a queued UDP datagram costs its socket's receive buffer (Linux __udp_enqueue_schedule_skb: sk_rmem_alloc + skb->truesize
//! against sk_rcvbuf). Measured on Linux 6.x over lo with MTU 1500 (SO_MEMINFO): a datagram in one frame costs 960 bytes up to a few
//! hundred bytes of payload and 2304 for a full frame; a reassembled one costs about 2304 per 1480-byte fragment. A datagram that
//! would take the socket past SO_RCVBUF is dropped, unless the queue is empty (then it is taken whatever its size).
const std = @import("std");

/// One frame's skb: small (a 1024-byte data area) or full (a 2048-byte one), plus the sk_buff itself.
pub const SMALL_TRUESIZE: u32 = 960;
pub const FRAME_TRUESIZE: u32 = 2304;
/// Payload up to which a datagram fits the small data area (the rest of 1024 bytes is headroom and skb_shared_info).
pub const SMALL_MAX: usize = 320;
/// Bytes of the datagram (UDP header included) one fragment carries at MTU 1500.
pub const FRAG_BYTES: usize = 1480;

/// The truesize charged for a queued UDP payload of `len` bytes.
pub fn truesize(len: usize) u32 {
    if (len <= SMALL_MAX) return SMALL_TRUESIZE;
    if (len + 8 <= FRAG_BYTES) return FRAME_TRUESIZE;
    const frags = (len + 8 + FRAG_BYTES - 1) / FRAG_BYTES;
    const last = len + 8 - (frags - 1) * FRAG_BYTES;
    return @intCast((frags - 1) * FRAME_TRUESIZE + (if (last <= SMALL_MAX) SMALL_TRUESIZE else FRAME_TRUESIZE));
}

/// Whether a datagram costing `size` may join a queue holding `rmem` under `rcvbuf`.
pub fn admits(rmem: u32, size: u32, rcvbuf: u32) bool {
    if (@as(u64, rmem) + size <= rcvbuf) return true;
    return rmem == 0;
}

/// __sock_queue_rcv_skb (raw sockets): a datagram is taken while the queue holds less than SO_RCVBUF, whatever its own size.
pub fn rawAdmits(rmem: u32, rcvbuf: u32) bool {
    return rmem < rcvbuf;
}

/// What a raw socket's queued IPv4 datagram of `len` bytes (IP header included) or IPv6 packet costs: the skbs of the frames that
/// carried it, as for a UDP datagram of that many bytes less the 20-byte IP and 8-byte UDP headers (a 1500-byte datagram is one
/// full frame).
pub fn rawTruesize(len: usize) u32 {
    return truesize(len -| 28);
}

test "a raw socket with the default buffer queues three 60000-byte datagrams (measured on Linux)" {
    var rmem: u32 = 0;
    var n: usize = 0;
    for (0..20) |_| if (rawAdmits(rmem, 212992)) {
        rmem += rawTruesize(60020);
        n += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), n);
}

test "a raw socket's default buffer holds 222 small datagrams, 93 full frames, 15 under SO_RCVBUF 16384 (measured on Linux)" {
    for ([_][3]u32{ .{ 21, 212992, 222 }, .{ 1020, 212992, 93 }, .{ 1500, 212992, 93 }, .{ 1020, 32768, 15 } }) |c| {
        var rmem: u32 = 0;
        var n: u32 = 0;
        while (rawAdmits(rmem, c[1])) : (n += 1) rmem += rawTruesize(c[0]);
        try std.testing.expectEqual(c[2], n);
    }
}

test "the default 212992-byte buffer queues two 60000-byte datagrams; 524288 five; an empty queue takes one whatever its size" {
    const t = truesize(60000);
    try std.testing.expectEqual(@as(u32, 41 * FRAME_TRUESIZE), t);
    var rmem: u32 = 0;
    var n: usize = 0;
    for (0..20) |_| if (admits(rmem, t, 212992)) {
        rmem += t;
        n += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), n);
    rmem = 0;
    n = 0;
    for (0..20) |_| if (admits(rmem, t, 524288)) {
        rmem += t;
        n += 1;
    };
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expect(admits(0, t, 4608));
    try std.testing.expect(!admits(1, t, 4608));
    try std.testing.expectEqual(SMALL_TRUESIZE, truesize(100));
    try std.testing.expectEqual(FRAME_TRUESIZE, truesize(1472));
    try std.testing.expectEqual(@as(u32, 2 * FRAME_TRUESIZE + SMALL_TRUESIZE), truesize(3000));
}
