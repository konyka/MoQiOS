//! IPv4 fragment reassembly and fragmentation rules (Linux net/ipv4/ip_fragment.c ip_frag_queue / ip_frag_reasm,
//! net/ipv4/inet_fragment.c inet_frag_queue_insert, net/ipv4/ip_output.c ip_fragment). Host-testable: the queues are plain values.
//!
//! Reassembly: fragments are grouped by (source, destination, id, protocol). Offsets count 8-byte units; a fragment with MF set has
//! its length cut to a multiple of 8. The last fragment (MF clear) fixes the datagram's length: a later fragment reaching past it,
//! or a second last fragment with another end, discards the queue, and so does a fragment that overlaps one already queued unless it
//! lies wholly inside it (a duplicate, which is dropped and the queue kept: RFC 5722 as Linux applies it to IPv4 too). An empty
//! fragment and a datagram longer than 65535 bytes with its header discard the queue. When the first and the last fragment are in and
//! the bytes add up, the datagram is complete. A queue not completed within IP_FRAG_TIME (30 s) is dropped.
//!
//! Fragmentation: a datagram that does not fit the MTU (and may be fragmented: DF clear) leaves as pieces of the MTU less the
//! header, rounded down to 8 bytes, every one but the last with MF; offsets in 8-byte units.

const std = @import("std");

pub const MF: u16 = 0x2000;
pub const DF: u16 = 0x4000;
pub const OFFSET_MASK: u16 = 0x1fff;
/// IP_FRAG_TIME.
pub const TIMEOUT_NS: u64 = 30 * std.time.ns_per_s;
/// The largest IPv4 datagram, header included.
pub const MAX_DATAGRAM: usize = 65535;
/// Payload room of a reassembly queue (the largest payload behind a 20-byte header).
pub const MAX_PAYLOAD: usize = MAX_DATAGRAM - 20;
/// Distinct byte ranges a queue tracks; a datagram cut into more pieces than this is dropped.
pub const MAX_RANGES: usize = 64;
/// Queues kept at once (Linux bounds them by memory, ipfrag_high_thresh); a new datagram when all are busy takes the oldest.
pub const QUEUES: usize = 4;

pub const Key = struct {
    src: [4]u8,
    dst: [4]u8,
    id: u16,
    protocol: u8,

    pub fn eql(a: Key, b: Key) bool {
        return std.mem.eql(u8, &a.src, &b.src) and std.mem.eql(u8, &a.dst, &b.dst) and a.id == b.id and a.protocol == b.protocol;
    }
};

const Range = struct { start: u32, end: u32 };

pub const Queue = struct {
    used: bool = false,
    key: Key = .{ .src = @splat(0), .dst = @splat(0), .id = 0, .protocol = 0 },
    started_ns: u64 = 0,
    /// The datagram's payload length once known (`last_in`), else the furthest end seen.
    len: u32 = 0,
    first_in: bool = false,
    last_in: bool = false,
    /// Bytes held (the sum of the ranges, which never overlap).
    meat: u32 = 0,
    ranges: [MAX_RANGES]Range = undefined,
    n: u8 = 0,
    /// The first fragment's IP header (the reassembled datagram takes it, minus the fragment fields).
    header: [60]u8 = @splat(0),
    header_len: u8 = 0,
    data: [MAX_PAYLOAD]u8 = undefined,
};

/// The fragment fields of an IPv4 header: whether it is a fragment at all, its offset in bytes, and MF.
pub fn fragInfo(flags_offset: u16) struct { is_fragment: bool, offset: u32, more: bool } {
    const off: u32 = @as(u32, flags_offset & OFFSET_MASK) * 8;
    const more = flags_offset & MF != 0;
    return .{ .is_fragment = more or off != 0, .offset = off, .more = more };
}

pub const Verdict = enum {
    /// Queued; more fragments are needed.
    pending,
    /// A duplicate of bytes already held: ignored.
    duplicate,
    /// The queue was inconsistent (overlap, bad length, too many pieces) and is now dropped.
    discarded,
    /// The datagram is whole: `Queue.data[0..Queue.len]` is its payload.
    complete,
};

/// ip_frag_queue for one fragment of `payload` bytes at byte `offset`, `more` its MF flag, onto `q` (already keyed). `header` is the
/// fragment's IP header, kept when it is the first fragment.
pub fn insert(q: *Queue, offset: u32, more: bool, payload: []const u8, header: []const u8) Verdict {
    var end: u32 = offset + @as(u32, @intCast(payload.len));
    if (!more) {
        if (end < q.len or (q.last_in and end != q.len)) return discard(q);
        q.last_in = true;
        q.len = end;
    } else {
        end &= ~@as(u32, 7);
        if (end > q.len) {
            if (q.last_in) return discard(q);
            q.len = end;
        }
    }
    if (end <= offset) return discard(q);
    if (end > MAX_PAYLOAD) return discard(q);
    // inet_frag_queue_insert: an overlap discards the queue, a fragment inside one already held is a duplicate.
    for (q.ranges[0..q.n]) |r| {
        if (end <= r.start or offset >= r.end) continue;
        if (offset >= r.start and end <= r.end) return .duplicate;
        return discard(q);
    }
    if (q.n == MAX_RANGES) return discard(q);
    q.ranges[q.n] = .{ .start = offset, .end = end };
    q.n += 1;
    @memcpy(q.data[offset..end], payload[0 .. end - offset]);
    q.meat += end - offset;
    if (offset == 0) {
        q.first_in = true;
        const hl = @min(header.len, q.header.len);
        @memcpy(q.header[0..hl], header[0..hl]);
        q.header_len = @intCast(hl);
    }
    if (q.first_in and q.last_in and q.meat == q.len) {
        // ip_frag_reasm: the whole datagram, header included, must fit 65535 bytes.
        if (@as(usize, q.len) + q.header_len > MAX_DATAGRAM) return discard(q);
        return .complete;
    }
    return .pending;
}

fn discard(q: *Queue) Verdict {
    q.used = false;
    return .discarded;
}

/// The queue for `key` among `qs`: an existing one, else a free one or the oldest (evicted), started at `now_ns`. Queues older than
/// TIMEOUT_NS are dropped first (ip_expire).
pub fn find(qs: []Queue, key: Key, now_ns: u64) *Queue {
    for (qs) |*q| {
        if (q.used and now_ns -| q.started_ns >= TIMEOUT_NS) q.used = false;
    }
    for (qs) |*q| {
        if (q.used and q.key.eql(key)) return q;
    }
    var pick: *Queue = &qs[0];
    for (qs) |*q| {
        if (!q.used) {
            pick = q;
            break;
        }
        if (q.started_ns < pick.started_ns) pick = q;
    }
    // Field by field: a whole-struct store would build the 64 KiB value on the (kernel) stack first.
    pick.used = true;
    pick.key = key;
    pick.started_ns = now_ns;
    pick.len = 0;
    pick.first_in = false;
    pick.last_in = false;
    pick.meat = 0;
    pick.n = 0;
    pick.header_len = 0;
    return pick;
}

/// ip_fragment's piece size for an MTU and header length: the room left, rounded down to 8 bytes.
pub fn pieceLen(mtu: u16, ihl: u16) u32 {
    return (@as(u32, mtu) - ihl) & ~@as(u32, 7);
}

/// Whether a datagram of `total` bytes (header included) is cut for `mtu`.
pub fn needsFragment(total: usize, mtu: u16) bool {
    return total > mtu;
}

test "fragInfo reads MF and the offset in 8-byte units" {
    try std.testing.expect(!fragInfo(0).is_fragment);
    try std.testing.expect(!fragInfo(DF).is_fragment);
    const a = fragInfo(MF);
    try std.testing.expect(a.is_fragment and a.more and a.offset == 0);
    const b = fragInfo(185);
    try std.testing.expect(b.is_fragment and !b.more and b.offset == 1480);
}

test "three in-order pieces reassemble; out of order too" {
    var qs: [QUEUES]Queue = @splat(.{});
    const key: Key = .{ .src = .{ 127, 0, 0, 1 }, .dst = .{ 127, 0, 0, 1 }, .id = 7, .protocol = 17 };
    var src: [4000]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @truncate(i);
    const hdr = [_]u8{0x45} ++ [_]u8{0} ** 19;
    const q = find(&qs, key, 0);
    try std.testing.expectEqual(Verdict.pending, insert(q, 0, true, src[0..1480], &hdr));
    try std.testing.expectEqual(Verdict.pending, insert(q, 1480, true, src[1480..2960], &hdr));
    try std.testing.expectEqual(Verdict.complete, insert(q, 2960, false, src[2960..4000], &hdr));
    try std.testing.expectEqual(@as(u32, 4000), q.len);
    try std.testing.expect(std.mem.eql(u8, q.data[0..4000], &src));

    const key2: Key = .{ .src = key.src, .dst = key.dst, .id = 8, .protocol = 17 };
    const q2 = find(&qs, key2, 0);
    try std.testing.expect(q2 != q);
    try std.testing.expectEqual(Verdict.pending, insert(q2, 2960, false, src[2960..4000], &hdr));
    try std.testing.expectEqual(Verdict.pending, insert(q2, 0, true, src[0..1480], &hdr));
    try std.testing.expectEqual(Verdict.duplicate, insert(q2, 0, true, src[0..1480], &hdr));
    try std.testing.expectEqual(Verdict.complete, insert(q2, 1480, true, src[1480..2960], &hdr));
    try std.testing.expectEqual(@as(u8, 0x45), q2.header[0]);
}

test "overlaps, a second last fragment and data past the end discard the queue" {
    var qs: [QUEUES]Queue = @splat(.{});
    const key: Key = .{ .src = .{ 1, 2, 3, 4 }, .dst = .{ 5, 6, 7, 8 }, .id = 1, .protocol = 17 };
    const hdr = [_]u8{0x45} ++ [_]u8{0} ** 19;
    var buf: [2000]u8 = @splat(0xaa);
    var q = find(&qs, key, 0);
    _ = insert(q, 0, true, buf[0..1000], &hdr);
    try std.testing.expectEqual(Verdict.discarded, insert(q, 496, true, buf[0..1000], &hdr));
    try std.testing.expect(!q.used);
    q = find(&qs, key, 0);
    _ = insert(q, 1000, false, buf[0..100], &hdr);
    try std.testing.expectEqual(Verdict.discarded, insert(q, 1200, false, buf[0..100], &hdr));
    q = find(&qs, key, 0);
    _ = insert(q, 1000, false, buf[0..100], &hdr);
    try std.testing.expectEqual(Verdict.discarded, insert(q, 1096, true, buf[0..16], &hdr));
    q = find(&qs, key, 0);
    try std.testing.expectEqual(Verdict.discarded, insert(q, 8, true, buf[0..4], &hdr));
}

test "a datagram over 65535 bytes is dropped, and so is a stale queue" {
    var qs: [QUEUES]Queue = @splat(.{});
    const key: Key = .{ .src = .{ 1, 2, 3, 4 }, .dst = .{ 5, 6, 7, 8 }, .id = 1, .protocol = 17 };
    const hdr = [_]u8{0x45} ++ [_]u8{0} ** 19;
    var big: [MAX_PAYLOAD]u8 = undefined;
    var q = find(&qs, key, 0);
    try std.testing.expectEqual(Verdict.discarded, insert(q, 8, false, big[0 .. MAX_PAYLOAD - 7], &hdr));
    q = find(&qs, key, 0);
    try std.testing.expectEqual(Verdict.pending, insert(q, 0, true, big[0..8], &hdr));
    const again = find(&qs, key, TIMEOUT_NS);
    try std.testing.expectEqual(@as(u8, 0), again.n);
}

test "piece length is the MTU less the header, a multiple of 8" {
    try std.testing.expectEqual(@as(u32, 1480), pieceLen(1500, 20));
    try std.testing.expectEqual(@as(u32, 1472), pieceLen(1500, 24));
    try std.testing.expect(needsFragment(1501, 1500));
    try std.testing.expect(!needsFragment(1500, 1500));
}
