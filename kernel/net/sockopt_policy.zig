//! Pure SOL_SOCKET option rules shared by every socket kind.
//!
//! Boolean options are stored as flag bits, buffer sizes follow Linux (the
//! request is capped at rmem_max/wmem_max, doubled for bookkeeping overhead,
//! and never below the minimum), and the read-only options describe the
//! socket itself.

const std = @import("std");

pub const SO_DEBUG: u64 = 1;
pub const SO_REUSEADDR: u64 = 2;
pub const SO_TYPE: u64 = 3;
pub const SO_ERROR: u64 = 4;
pub const SO_BROADCAST: u64 = 6;
pub const SO_SNDBUF: u64 = 7;
pub const SO_RCVBUF: u64 = 8;
pub const SO_KEEPALIVE: u64 = 9;
pub const SO_LINGER: u64 = 13;
pub const SO_REUSEPORT: u64 = 15;
pub const SO_PASSCRED: u64 = 16;
pub const SO_PEERCRED: u64 = 17;
pub const SO_RCVTIMEO: u64 = 20;
pub const SO_SNDTIMEO: u64 = 21;
pub const SO_ACCEPTCONN: u64 = 30;
pub const SO_PROTOCOL: u64 = 38;
pub const SO_DOMAIN: u64 = 39;

pub const AF_UNIX: u32 = 1;
pub const AF_INET: u32 = 2;
pub const AF_INET6: u32 = 10;
pub const SOCK_STREAM: u32 = 1;
pub const SOCK_DGRAM: u32 = 2;
pub const SOCK_RAW: u32 = 3;
pub const IPPROTO_TCP: u32 = 6;
pub const IPPROTO_UDP: u32 = 17;

pub const Kind = enum { tcp, udp, unix_stream, unix_dgram, raw };

pub const Identity = struct { domain: u32, sock_type: u32, protocol: u32 };

pub fn identity(kind: Kind, v6: bool) Identity {
    const inet: u32 = if (v6) AF_INET6 else AF_INET;
    return switch (kind) {
        .tcp => .{ .domain = inet, .sock_type = SOCK_STREAM, .protocol = IPPROTO_TCP },
        .udp => .{ .domain = inet, .sock_type = SOCK_DGRAM, .protocol = IPPROTO_UDP },
        .unix_stream => .{ .domain = AF_UNIX, .sock_type = SOCK_STREAM, .protocol = 0 },
        .unix_dgram => .{ .domain = AF_UNIX, .sock_type = SOCK_DGRAM, .protocol = 0 },
        .raw => .{ .domain = inet, .sock_type = SOCK_RAW, .protocol = 0 },
    };
}

/// Options that only report state: setsockopt on them is ENOPROTOOPT.
pub fn readOnly(optname: u64) bool {
    return switch (optname) {
        SO_TYPE, SO_ERROR, SO_ACCEPTCONN, SO_PROTOCOL, SO_DOMAIN, SO_PEERCRED => true,
        else => false,
    };
}

/// Flag bit for a boolean option, or null.
pub fn flagBit(optname: u64) ?u16 {
    return switch (optname) {
        SO_REUSEADDR => 1,
        SO_KEEPALIVE => 2,
        SO_BROADCAST => 4,
        SO_REUSEPORT => 8,
        SO_DEBUG => 16,
        SO_PASSCRED => 32,
        else => null,
    };
}

pub const RMEM_MAX: u32 = 212992;
pub const SOCK_MIN_RCVBUF: u32 = 2304;
pub const SOCK_MIN_SNDBUF: u32 = 4608;

/// SO_RCVBUF / SO_SNDBUF: the value getsockopt reports after a set.
pub fn bufferValue(requested: u32, min: u32) u32 {
    const capped = @min(requested, RMEM_MAX);
    return @max(capped * 2, min);
}

/// The value getsockopt reports for a buffer that was never set.
pub const DEFAULT_BUF: u32 = 212992;

pub const Cred = struct {
    pid: i32 = 0,
    uid: u32 = 0xFFFF_FFFF,
    gid: u32 = 0xFFFF_FFFF,
};

pub const UCRED_SIZE: usize = 12;

pub fn encodeCred(c: Cred) [UCRED_SIZE]u8 {
    var out: [UCRED_SIZE]u8 = undefined;
    std.mem.writeInt(i32, out[0..4], c.pid, .little);
    std.mem.writeInt(u32, out[4..8], c.uid, .little);
    std.mem.writeInt(u32, out[8..12], c.gid, .little);
    return out;
}

/// A timeval (seconds, microseconds) as milliseconds; null = invalid.
pub fn timevalMs(sec: i64, usec: i64) ?u32 {
    if (sec < 0 or usec < 0 or usec >= 1_000_000) return null;
    const max_ms: u64 = 0xFFFF_FFFF;
    const s: u64 = @intCast(sec);
    if (s > max_ms / 1000) return @intCast(max_ms);
    return @intCast(@min(s * 1000 + @as(u64, @intCast(usec)) / 1000, max_ms));
}

/// The SOL_SOCKET state every socket kind keeps.
pub const Stored = struct {
    flags: u16 = 0,
    rcv_ms: u32 = 0,
    snd_ms: u32 = 0,
    rcvbuf: u32 = DEFAULT_BUF,
    sndbuf: u32 = DEFAULT_BUF,
    linger_on: bool = false,
    linger_sec: u32 = 0,
};

fn rd32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .little);
}

/// setsockopt(SOL_SOCKET, optname, val) on `s`: 0 or -errno.
pub fn applySet(s: *Stored, optname: u64, val: []const u8) i64 {
    if (readOnly(optname)) return -92; // ENOPROTOOPT
    if (flagBit(optname)) |bit| {
        if (val.len < 4) return -22;
        if (rd32(val) != 0) s.flags |= bit else s.flags &= ~bit;
        return 0;
    }
    switch (optname) {
        SO_RCVBUF => {
            if (val.len < 4) return -22;
            s.rcvbuf = bufferValue(rd32(val), SOCK_MIN_RCVBUF);
        },
        SO_SNDBUF => {
            if (val.len < 4) return -22;
            s.sndbuf = bufferValue(rd32(val), SOCK_MIN_SNDBUF);
        },
        SO_RCVTIMEO, SO_SNDTIMEO => {
            if (val.len < 16) return -22;
            const sec = std.mem.readInt(i64, val[0..8], .little);
            const usec = std.mem.readInt(i64, val[8..16], .little);
            const ms = timevalMs(sec, usec) orelse return -22;
            if (optname == SO_RCVTIMEO) s.rcv_ms = ms else s.snd_ms = ms;
        },
        SO_LINGER => {
            if (val.len < 8) return -22;
            s.linger_on = rd32(val) != 0;
            s.linger_sec = rd32(val[4..]);
        },
        else => return -92,
    }
    return 0;
}

/// What a socket reports besides its Stored state.
pub const Facts = struct {
    id: Identity,
    accepting: bool = false,
    so_error: i32 = 0,
    /// Peer credentials (AF_UNIX only); null = the option does not exist.
    cred: ?Cred = null,
};

/// getsockopt(SOL_SOCKET, optname): the value bytes written into `out`
/// (returns their count) or null for an unknown option.
pub fn encodeGet(s: Stored, f: Facts, optname: u64, out: *[16]u8) ?usize {
    const put = struct {
        fn int(o: *[16]u8, v: u32) usize {
            std.mem.writeInt(u32, o[0..4], v, .little);
            return 4;
        }
    };
    if (flagBit(optname)) |bit| return put.int(out, if (s.flags & bit != 0) 1 else 0);
    switch (optname) {
        SO_TYPE => return put.int(out, f.id.sock_type),
        SO_DOMAIN => return put.int(out, f.id.domain),
        SO_PROTOCOL => return put.int(out, f.id.protocol),
        SO_ACCEPTCONN => return put.int(out, if (f.accepting) 1 else 0),
        SO_ERROR => {
            std.mem.writeInt(i32, out[0..4], f.so_error, .little);
            return 4;
        },
        SO_RCVBUF => return put.int(out, s.rcvbuf),
        SO_SNDBUF => return put.int(out, s.sndbuf),
        SO_RCVTIMEO, SO_SNDTIMEO => {
            const ms = if (optname == SO_RCVTIMEO) s.rcv_ms else s.snd_ms;
            std.mem.writeInt(i64, out[0..8], ms / 1000, .little);
            std.mem.writeInt(i64, out[8..16], (ms % 1000) * 1000, .little);
            return 16;
        },
        SO_LINGER => {
            std.mem.writeInt(u32, out[0..4], if (s.linger_on) 1 else 0, .little);
            std.mem.writeInt(u32, out[4..8], s.linger_sec, .little);
            return 8;
        },
        SO_PEERCRED => {
            const c = f.cred orelse return null;
            const raw = encodeCred(c);
            @memcpy(out[0..UCRED_SIZE], &raw);
            return UCRED_SIZE;
        },
        else => return null,
    }
}

test "applySet and encodeGet round-trip every stored option" {
    var s: Stored = .{};
    var one = [_]u8{ 1, 0, 0, 0 };
    try std.testing.expectEqual(@as(i64, 0), applySet(&s, SO_REUSEPORT, &one));
    try std.testing.expectEqual(@as(i64, 0), applySet(&s, SO_BROADCAST, &one));
    var out: [16]u8 = undefined;
    const f: Facts = .{ .id = identity(.udp, false) };
    try std.testing.expectEqual(@as(?usize, 4), encodeGet(s, f, SO_REUSEPORT, &out));
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    var zero = [_]u8{ 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(i64, 0), applySet(&s, SO_REUSEPORT, &zero));
    _ = encodeGet(s, f, SO_REUSEPORT, &out);
    try std.testing.expectEqual(@as(u8, 0), out[0]);
    _ = encodeGet(s, f, SO_BROADCAST, &out);
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    var big = [_]u8{ 0x00, 0x00, 0x01, 0x00 }; // 65536
    try std.testing.expectEqual(@as(i64, 0), applySet(&s, SO_RCVBUF, &big));
    _ = encodeGet(s, f, SO_RCVBUF, &out);
    try std.testing.expectEqual(@as(u32, 131072), std.mem.readInt(u32, out[0..4], .little));
    var tv: [16]u8 = undefined;
    std.mem.writeInt(i64, tv[0..8], 2, .little);
    std.mem.writeInt(i64, tv[8..16], 500_000, .little);
    try std.testing.expectEqual(@as(i64, 0), applySet(&s, SO_RCVTIMEO, &tv));
    try std.testing.expectEqual(@as(?usize, 16), encodeGet(s, f, SO_RCVTIMEO, &out));
    try std.testing.expectEqual(@as(i64, 2), std.mem.readInt(i64, out[0..8], .little));
    try std.testing.expectEqual(@as(i64, 500_000), std.mem.readInt(i64, out[8..16], .little));
}

test "applySet rejects read-only options, short values and bad timevals" {
    var s: Stored = .{};
    var one = [_]u8{ 1, 0, 0, 0 };
    try std.testing.expectEqual(@as(i64, -92), applySet(&s, SO_TYPE, &one));
    try std.testing.expectEqual(@as(i64, -92), applySet(&s, SO_PEERCRED, &one));
    try std.testing.expectEqual(@as(i64, -92), applySet(&s, 9999, &one));
    try std.testing.expectEqual(@as(i64, -22), applySet(&s, SO_REUSEADDR, one[0..2]));
    var tv: [16]u8 = @splat(0);
    std.mem.writeInt(i64, tv[8..16], 1_000_000, .little);
    try std.testing.expectEqual(@as(i64, -22), applySet(&s, SO_SNDTIMEO, &tv));
    try std.testing.expectEqual(@as(i64, -22), applySet(&s, SO_LINGER, one[0..4]));
}

test "encodeGet reports identity, acceptance, errors and peer credentials" {
    var out: [16]u8 = undefined;
    const s: Stored = .{};
    const f: Facts = .{ .id = identity(.unix_stream, false), .accepting = true, .so_error = 111, .cred = .{ .pid = 5, .uid = 6, .gid = 7 } };
    _ = encodeGet(s, f, SO_TYPE, &out);
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    _ = encodeGet(s, f, SO_DOMAIN, &out);
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    _ = encodeGet(s, f, SO_ACCEPTCONN, &out);
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    _ = encodeGet(s, f, SO_ERROR, &out);
    try std.testing.expectEqual(@as(u8, 111), out[0]);
    try std.testing.expectEqual(@as(?usize, 12), encodeGet(s, f, SO_PEERCRED, &out));
    try std.testing.expectEqual(@as(u8, 5), out[0]);
    const no_cred: Facts = .{ .id = identity(.tcp, false) };
    try std.testing.expectEqual(@as(?usize, null), encodeGet(s, no_cred, SO_PEERCRED, &out));
    try std.testing.expectEqual(@as(?usize, null), encodeGet(s, f, 9999, &out));
}

test "identity of every socket kind" {
    try std.testing.expectEqual(Identity{ .domain = 2, .sock_type = 1, .protocol = 6 }, identity(.tcp, false));
    try std.testing.expectEqual(Identity{ .domain = 10, .sock_type = 2, .protocol = 17 }, identity(.udp, true));
    try std.testing.expectEqual(Identity{ .domain = 1, .sock_type = 1, .protocol = 0 }, identity(.unix_stream, false));
    try std.testing.expectEqual(@as(u32, 2), identity(.unix_dgram, false).sock_type);
    try std.testing.expectEqual(@as(u32, 3), identity(.raw, false).sock_type);
}

test "read-only and boolean options" {
    try std.testing.expect(readOnly(SO_TYPE) and readOnly(SO_PEERCRED) and readOnly(SO_ACCEPTCONN));
    try std.testing.expect(!readOnly(SO_REUSEADDR) and !readOnly(SO_RCVBUF));
    try std.testing.expectEqual(@as(?u16, 1), flagBit(SO_REUSEADDR));
    try std.testing.expectEqual(@as(?u16, 8), flagBit(SO_REUSEPORT));
    try std.testing.expectEqual(@as(?u16, null), flagBit(SO_RCVBUF));
}

test "buffer sizes double, are capped and have a floor" {
    try std.testing.expectEqual(@as(u32, 131072), bufferValue(65536, SOCK_MIN_RCVBUF));
    try std.testing.expectEqual(@as(u32, 2 * RMEM_MAX), bufferValue(0x7FFF_FFFF, SOCK_MIN_RCVBUF));
    try std.testing.expectEqual(SOCK_MIN_RCVBUF, bufferValue(1, SOCK_MIN_RCVBUF));
    try std.testing.expectEqual(SOCK_MIN_SNDBUF, bufferValue(1, SOCK_MIN_SNDBUF));
}

test "ucred layout and the unset credential" {
    const raw = encodeCred(.{ .pid = 42, .uid = 7, .gid = 9 });
    try std.testing.expectEqual(@as(u8, 42), raw[0]);
    try std.testing.expectEqual(@as(u8, 7), raw[4]);
    try std.testing.expectEqual(@as(u8, 9), raw[8]);
    const unset = encodeCred(.{});
    try std.testing.expectEqual(@as(u8, 0), unset[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), unset[4]);
    try std.testing.expectEqual(@as(u8, 0xFF), unset[11]);
}

test "timeval to milliseconds" {
    try std.testing.expectEqual(@as(?u32, 2500), timevalMs(2, 500_000));
    try std.testing.expectEqual(@as(?u32, null), timevalMs(-1, 0));
    try std.testing.expectEqual(@as(?u32, null), timevalMs(0, 1_000_000));
    try std.testing.expectEqual(@as(?u32, 0xFFFF_FFFF), timevalMs(0x7FFF_FFFF_FFFF, 0));
}
