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
/// Payload room of a reassembly queue: an IPv6 payload may be 65535 bytes (IPV6_MAXPLEN); an IPv4 one stops at 65535 less its header.
pub const MAX_PAYLOAD: usize = 65535;
/// Distinct byte ranges a queue tracks; a datagram cut into more pieces than this is dropped.
pub const MAX_RANGES: usize = 64;
/// Queues kept at once (Linux bounds them by memory, ipfrag_high_thresh); a new datagram when all are busy takes the oldest.
pub const QUEUES: usize = 4;

/// A reassembly queue's identity: (source, destination, id, protocol) for IPv4 (the addresses in the first 4 bytes, a 16-bit id);
/// (source, destination, id) for IPv6, whose 32-bit id names the datagram on its own (ip6_frag_find, `protocol` 0).
pub const Key = struct {
    src: [4]u8 = @splat(0),
    dst: [4]u8 = @splat(0),
    id: u32 = 0,
    protocol: u8 = 0,
    v6: bool = false,
    src6: [16]u8 = @splat(0),
    dst6: [16]u8 = @splat(0),

    pub fn eql(a: Key, b: Key) bool {
        if (a.v6 != b.v6 or a.id != b.id or a.protocol != b.protocol) return false;
        if (a.v6) return std.mem.eql(u8, &a.src6, &b.src6) and std.mem.eql(u8, &a.dst6, &b.dst6);
        return std.mem.eql(u8, &a.src, &b.src) and std.mem.eql(u8, &a.dst, &b.dst);
    }

    /// IP_FRAG_TIME (30 s) for IPv4, IPV6_FRAG_TIMEOUT (60 s) for IPv6.
    pub fn timeoutNs(k: Key) u64 {
        return if (k.v6) TIMEOUT6_NS else TIMEOUT_NS;
    }
};

pub const TIMEOUT6_NS: u64 = 60 * std.time.ns_per_s;

/// The fields of an IPv6 Fragment header (8 bytes: next header, reserved, offset and M flag, id).
pub fn fragHeader6(h: []const u8) struct { nh: u8, offset: u32, more: bool, id: u32 } {
    const fo: u16 = @as(u16, h[2]) << 8 | h[3];
    return .{ .nh = h[0], .offset = fo & 0xfff8, .more = fo & 1 != 0, .id = std.mem.readInt(u32, h[4..8], .big) };
}

/// ipv6_frag_rcv / ip6_frag_queue checks a fragment of `payload_len` bytes (after the Fragment header) at `offset` must pass: an
/// atomic fragment (offset 0, no M) is the datagram itself; a non-last fragment whose length is not a multiple of 8 is a parameter
/// problem pointing at the payload length field (4); past 65535 bytes is a parameter problem at the offset field (`frag_field`).
pub const Check6 = union(enum) { atomic, queue, param_problem: u32 };

pub fn check6(offset: u32, more: bool, payload_len: usize, frag_field: u32) Check6 {
    if (offset == 0 and !more) return .atomic;
    const end = offset + payload_len;
    if (end > 65535) return .{ .param_problem = frag_field };
    if (more and end & 7 != 0) return .{ .param_problem = 4 };
    return .queue;
}

const Range = struct { start: u32, end: u32 };

/// Where a queue's payload starts in `Queue.buf`: room for an Ethernet header and the longest IPv4 header in front of it, so the whole
/// datagram can be handed on as one frame.
pub const PAYLOAD_OFF: usize = 14 + 60;

pub const Queue = struct {
    used: bool = false,
    /// The completed datagram is being delivered (outside the queue lock): nobody may reuse the queue until it is released.
    busy: bool = false,
    key: Key = .{},
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
    buf: [PAYLOAD_OFF + MAX_PAYLOAD]u8 = undefined,

    pub fn data(q: *Queue) []u8 {
        return q.buf[PAYLOAD_OFF..][0..q.len];
    }

    /// The completed datagram as an Ethernet frame (`eth` its 14-byte header): the first fragment's IP header with the fragment
    /// fields cleared, the total length set and the checksum redone (ip_frag_reasm), then the payload.
    pub fn frame(q: *Queue, eth: []const u8) []u8 {
        const hl: usize = q.header_len;
        const start = PAYLOAD_OFF - hl - 14;
        @memcpy(q.buf[start..][0..14], eth[0..14]);
        const h = q.buf[start + 14 ..][0..hl];
        @memcpy(h, q.header[0..hl]);
        const total: u16 = @intCast(hl + q.len);
        h[2] = @intCast(total >> 8);
        h[3] = @truncate(total);
        h[6] = 0;
        h[7] = 0;
        h[10] = 0;
        h[11] = 0;
        const c = headerChecksum(h);
        h[10] = @intCast(c >> 8);
        h[11] = @truncate(c);
        return q.buf[start .. PAYLOAD_OFF + q.len];
    }

    /// frame for an IPv6 datagram: the first fragment's 40-byte header (its next header already the Fragment header's) with the payload
    /// length set (ip6_frag_reasm), then the payload. A payload over 65535 bytes is never complete (insert drops it).
    pub fn frame6(q: *Queue, eth: []const u8) []u8 {
        const start = PAYLOAD_OFF - 40 - 14;
        @memcpy(q.buf[start..][0..14], eth[0..14]);
        const h = q.buf[start + 14 ..][0..40];
        @memcpy(h, q.header[0..40]);
        h[4] = @intCast(q.len >> 8);
        h[5] = @truncate(q.len);
        return q.buf[start .. PAYLOAD_OFF + q.len];
    }
};

pub fn headerChecksum(h: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < h.len) : (i += 2) sum += @as(u32, h[i]) << 8 | h[i + 1];
    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
    return @truncate(~sum);
}

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
    @memcpy(q.buf[PAYLOAD_OFF + offset ..][0 .. end - offset], payload[0 .. end - offset]);
    q.meat += end - offset;
    if (offset == 0) {
        q.first_in = true;
        const hl = @min(header.len, q.header.len);
        @memcpy(q.header[0..hl], header[0..hl]);
        q.header_len = @intCast(hl);
    }
    if (q.first_in and q.last_in and q.meat == q.len) {
        // ip_frag_reasm: the whole IPv4 datagram, header included, must fit 65535 bytes; ip6_frag_reasm bounds the payload alone.
        if (!q.key.v6 and @as(usize, q.len) + q.header_len > MAX_DATAGRAM) return discard(q);
        return .complete;
    }
    return .pending;
}

pub fn discard(q: *Queue) Verdict {
    q.used = false;
    return .discarded;
}

/// The queue for `key` among `qs`: an existing one, else a free one or the oldest (evicted), started at `now_ns`; null when every
/// queue is delivering a datagram. Queues older than TIMEOUT_NS are dropped first (ip_expire).
pub fn find(qs: []Queue, key: Key, now_ns: u64) ?*Queue {
    for (qs) |*q| {
        if (q.used and !q.busy and now_ns -| q.started_ns >= q.key.timeoutNs()) q.used = false;
    }
    for (qs) |*q| {
        if (q.used and !q.busy and q.key.eql(key)) return q;
    }
    var pick: ?*Queue = null;
    for (qs) |*q| {
        if (q.busy) continue;
        if (!q.used) {
            pick = q;
            break;
        }
        if (pick == null or q.started_ns < pick.?.started_ns) pick = q;
    }
    const p = pick orelse return null;
    return reset(p, key, now_ns);
}

fn reset(pick: *Queue, key: Key, now_ns: u64) *Queue {
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
    const q = find(&qs, key, 0).?;
    try std.testing.expectEqual(Verdict.pending, insert(q, 0, true, src[0..1480], &hdr));
    try std.testing.expectEqual(Verdict.pending, insert(q, 1480, true, src[1480..2960], &hdr));
    try std.testing.expectEqual(Verdict.complete, insert(q, 2960, false, src[2960..4000], &hdr));
    try std.testing.expectEqual(@as(u32, 4000), q.len);
    try std.testing.expect(std.mem.eql(u8, q.data(), &src));
    const eth = [_]u8{0xee} ** 14;
    const f = q.frame(&eth);
    try std.testing.expectEqual(@as(usize, 14 + 20 + 4000), f.len);
    try std.testing.expectEqual(@as(u8, 0xee), f[0]);
    try std.testing.expectEqual(@as(u16, 4020), @as(u16, f[16]) << 8 | f[17]);
    try std.testing.expectEqual(@as(u8, 0), f[20]);
    try std.testing.expectEqual(@as(u16, 0), headerChecksum(f[14..34]));
    try std.testing.expect(std.mem.eql(u8, f[34..], &src));

    const key2: Key = .{ .src = key.src, .dst = key.dst, .id = 8, .protocol = 17 };
    const q2 = find(&qs, key2, 0).?;
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
    var q = find(&qs, key, 0).?;
    _ = insert(q, 0, true, buf[0..1000], &hdr);
    try std.testing.expectEqual(Verdict.discarded, insert(q, 496, true, buf[0..1000], &hdr));
    try std.testing.expect(!q.used);
    q = find(&qs, key, 0).?;
    _ = insert(q, 1000, false, buf[0..100], &hdr);
    try std.testing.expectEqual(Verdict.discarded, insert(q, 1200, false, buf[0..100], &hdr));
    q = find(&qs, key, 0).?;
    _ = insert(q, 1000, false, buf[0..100], &hdr);
    try std.testing.expectEqual(Verdict.discarded, insert(q, 1096, true, buf[0..16], &hdr));
    q = find(&qs, key, 0).?;
    try std.testing.expectEqual(Verdict.discarded, insert(q, 8, true, buf[0..4], &hdr));
}

test "a datagram over 65535 bytes is dropped, and so is a stale queue" {
    var qs: [QUEUES]Queue = @splat(.{});
    const key: Key = .{ .src = .{ 1, 2, 3, 4 }, .dst = .{ 5, 6, 7, 8 }, .id = 1, .protocol = 17 };
    const hdr = [_]u8{0x45} ++ [_]u8{0} ** 19;
    var big: [MAX_PAYLOAD]u8 = undefined;
    var q = find(&qs, key, 0).?;
    try std.testing.expectEqual(Verdict.discarded, insert(q, 8, false, big[0 .. MAX_PAYLOAD - 7], &hdr));
    q = find(&qs, key, 0).?;
    try std.testing.expectEqual(Verdict.pending, insert(q, 0, true, big[0..8], &hdr));
    const again = find(&qs, key, TIMEOUT_NS).?;
    try std.testing.expectEqual(@as(u8, 0), again.n);
}

test "piece length is the MTU less the header, a multiple of 8" {
    try std.testing.expectEqual(@as(u32, 1480), pieceLen(1500, 20));
    try std.testing.expectEqual(@as(u32, 1472), pieceLen(1500, 24));
    try std.testing.expect(needsFragment(1501, 1500));
    try std.testing.expect(!needsFragment(1500, 1500));
}

test "a delivering queue is never reused" {
    var qs: [1]Queue = @splat(.{});
    const key: Key = .{ .src = .{ 1, 2, 3, 4 }, .dst = .{ 5, 6, 7, 8 }, .id = 1, .protocol = 17 };
    const q = find(&qs, key, 0).?;
    q.busy = true;
    try std.testing.expect(find(&qs, .{ .src = key.src, .dst = key.dst, .id = 2, .protocol = 17 }, 0) == null);
    try std.testing.expect(find(&qs, key, TIMEOUT_NS * 2) == null);
}

test "IPv6 keys, fragment header and the checks before queueing" {
    var a: Key = .{ .v6 = true, .id = 0x1001 };
    a.src6[15] = 1;
    a.dst6[15] = 1;
    var b = a;
    try std.testing.expect(a.eql(b));
    b.id = 0x1002;
    try std.testing.expect(!a.eql(b));
    const v4: Key = .{ .id = 0x1001 };
    try std.testing.expect(!a.eql(v4));
    try std.testing.expectEqual(TIMEOUT6_NS, a.timeoutNs());
    const h = fragHeader6(&.{ 17, 0, 0x05, 0xa9, 0, 0, 0x10, 0x01 });
    try std.testing.expectEqual(@as(u8, 17), h.nh);
    try std.testing.expectEqual(@as(u32, 1448), h.offset);
    try std.testing.expect(h.more);
    try std.testing.expectEqual(@as(u32, 0x1001), h.id);
    try std.testing.expect(check6(0, false, 12, 42) == .atomic);
    try std.testing.expect(check6(0, true, 1448, 42) == .queue);
    try std.testing.expectEqual(@as(u32, 4), check6(0, true, 1444, 42).param_problem);
    try std.testing.expectEqual(@as(u32, 42), check6(65528, false, 16, 42).param_problem);
    try std.testing.expect(check6(2896, false, 112, 42) == .queue);
}
