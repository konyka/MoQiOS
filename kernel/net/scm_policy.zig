//! Pure SCM_RIGHTS control-message rules (Linux x86-64 ABI).
//!
//! msghdr (56 bytes): msg_name@0 namelen@8 msg_iov@16 iovlen@24
//! msg_control@32 controllen@40 msg_flags@48. A control message is
//! { u64 cmsg_len; i32 level; i32 type; data } padded to 8 bytes.
//! SCM_RIGHTS carries an array of i32 descriptors.

const std = @import("std");

pub const SOL_SOCKET: i32 = 1;
pub const SCM_RIGHTS: i32 = 1;
pub const SCM_CREDENTIALS: i32 = 2;
pub const UCRED_LEN: usize = 12;
pub const HDR: usize = 16;
pub const MAX_FDS: usize = 8;

pub const MSG_CTRUNC: u32 = 0x8;
pub const MSG_CMSG_CLOEXEC: u32 = 0x4000_0000;

fn align8(n: usize) usize {
    return (n + 7) & ~@as(usize, 7);
}

/// CMSG_LEN / CMSG_SPACE for `payload` bytes.
pub fn cmsgLen(payload: usize) usize {
    return HDR + payload;
}
pub fn cmsgSpace(payload: usize) usize {
    return align8(HDR + payload);
}

pub const Parsed = struct {
    count: usize = 0,
    fds: [MAX_FDS]i32 = @splat(-1),
    /// An explicit SCM_CREDENTIALS from the sender, if one was supplied.
    has_cred: bool = false,
    cred_pid: i32 = 0,
    cred_uid: u32 = 0,
    cred_gid: u32 = 0,
};

pub const ParseError = enum { invalid, too_many };

/// Collect the descriptors of every SCM_RIGHTS message in `control`.
/// Any other message type, a length shorter than its header, or one running
/// past the buffer is EINVAL; more than MAX_FDS descriptors is too_many.
pub fn parseRights(control: []const u8) union(enum) { ok: Parsed, err: ParseError } {
    var out: Parsed = .{};
    var off: usize = 0;
    while (off + HDR <= control.len) {
        const len = std.mem.readInt(u64, control[off..][0..8], .little);
        const level = std.mem.readInt(i32, control[off + 8 ..][0..4], .little);
        const typ = std.mem.readInt(i32, control[off + 12 ..][0..4], .little);
        if (len < HDR or len > control.len - off) return .{ .err = .invalid };
        if (level == SOL_SOCKET and typ == SCM_CREDENTIALS) {
            if (len - HDR != UCRED_LEN) return .{ .err = .invalid };
            out.has_cred = true;
            out.cred_pid = std.mem.readInt(i32, control[off + HDR ..][0..4], .little);
            out.cred_uid = std.mem.readInt(u32, control[off + HDR + 4 ..][0..4], .little);
            out.cred_gid = std.mem.readInt(u32, control[off + HDR + 8 ..][0..4], .little);
            off += align8(@intCast(len));
            continue;
        }
        if (level != SOL_SOCKET or typ != SCM_RIGHTS) return .{ .err = .invalid };
        const payload: usize = @intCast(len - HDR);
        if (payload % 4 != 0) return .{ .err = .invalid };
        var i: usize = 0;
        while (i < payload / 4) : (i += 1) {
            if (out.count == MAX_FDS) return .{ .err = .too_many };
            out.fds[out.count] = std.mem.readInt(i32, control[off + HDR + i * 4 ..][0..4], .little);
            out.count += 1;
        }
        off += align8(@intCast(len));
    }
    return .{ .ok = out };
}

pub const Built = struct {
    /// Bytes of control written (CMSG_SPACE of what fitted; 0 = nothing).
    written: usize,
    /// How many descriptors fit in the caller's buffer.
    fits: usize,
    /// True when fewer descriptors fit than were offered (MSG_CTRUNC).
    truncated: bool,
};

/// Lay out one SCM_RIGHTS message for `fds` in a buffer of `cap` bytes.
/// A buffer too small for the header yields nothing and truncation.
pub fn buildRights(fds: []const i32, cap: usize, out: []u8) Built {
    if (fds.len == 0) return .{ .written = 0, .fits = 0, .truncated = false };
    if (cap < HDR) return .{ .written = 0, .fits = 0, .truncated = true };
    const room = @min(cap, out.len) - HDR;
    const fits = @min(fds.len, room / 4);
    if (fits == 0) return .{ .written = 0, .fits = 0, .truncated = true };
    std.mem.writeInt(u64, out[0..8], cmsgLen(fits * 4), .little);
    std.mem.writeInt(i32, out[8..12], SOL_SOCKET, .little);
    std.mem.writeInt(i32, out[12..16], SCM_RIGHTS, .little);
    for (fds[0..fits], 0..) |fd, i| std.mem.writeInt(i32, out[HDR + i * 4 ..][0..4], fd, .little);
    const total = @min(cmsgSpace(fits * 4), cap);
    var pad = HDR + fits * 4;
    while (pad < total and pad < out.len) : (pad += 1) out[pad] = 0;
    return .{ .written = total, .fits = fits, .truncated = fits < fds.len };
}

/// Lay out one SCM_CREDENTIALS message ({i32 pid; u32 uid; u32 gid}) in a
/// buffer of `cap` bytes. A buffer too small for the whole message yields
/// nothing and truncation (the credentials are never cut in half).
pub fn buildCredentials(pid: i32, uid: u32, gid: u32, cap: usize, out: []u8) Built {
    const space = cmsgSpace(UCRED_LEN);
    if (cap < cmsgLen(UCRED_LEN) or out.len < space) return .{ .written = 0, .fits = 0, .truncated = true };
    std.mem.writeInt(u64, out[0..8], cmsgLen(UCRED_LEN), .little);
    std.mem.writeInt(i32, out[8..12], SOL_SOCKET, .little);
    std.mem.writeInt(i32, out[12..16], SCM_CREDENTIALS, .little);
    std.mem.writeInt(i32, out[16..20], pid, .little);
    std.mem.writeInt(u32, out[20..24], uid, .little);
    std.mem.writeInt(u32, out[24..28], gid, .little);
    var pad: usize = 28;
    while (pad < space) : (pad += 1) out[pad] = 0;
    return .{ .written = @min(space, cap), .fits = 1, .truncated = false };
}

/// Whether the ids in a sender-supplied SCM_CREDENTIALS are acceptable: a
/// process may only claim its own pid/uid/gid unless it holds the matching
/// capability (CAP_SYS_ADMIN for the pid, CAP_SETUID / CAP_SETGID for ids).
pub fn credsAcceptable(claim_pid: i32, claim_uid: u32, claim_gid: u32, own_pid: i32, own_uid: u32, own_gid: u32, can_pid: bool, can_uid: bool, can_gid: bool) bool {
    if (claim_pid != own_pid and !can_pid) return false;
    if (claim_uid != own_uid and !can_uid) return false;
    if (claim_gid != own_gid and !can_gid) return false;
    return true;
}

pub const ReadPlan = struct {
    /// Most bytes this read may take.
    cap: usize,
    /// True when the first queued descriptor set belongs to this read.
    deliver: bool,
};

/// How far one read may go when descriptor sets are queued on the socket.
/// `first_rel` / `second_rel` are the distances in bytes from the read
/// position to the first and second queued set (null = none). A read that
/// asks for control data never crosses a set boundary: plain data in front of
/// a set is returned first, and a read that delivers a set stops before the
/// next one. A plain read takes everything and discards the sets it passes.
pub fn readPlan(len: usize, first_rel: ?u64, second_rel: ?u64, wants_rights: bool) ReadPlan {
    if (!wants_rights) return .{ .cap = len, .deliver = false };
    const first = first_rel orelse return .{ .cap = len, .deliver = false };
    if (first > 0) return .{ .cap = @min(len, @as(usize, @intCast(@min(first, std.math.maxInt(usize))))), .deliver = false };
    var cap = len;
    if (second_rel) |second| cap = @min(cap, @as(usize, @intCast(@min(second, std.math.maxInt(usize)))));
    return .{ .cap = cap, .deliver = true };
}

/// A queued descriptor set that was attached at stream position `pos` is
/// handed over by a read that consumed bytes [old_read, new_read).
pub fn deliveredBy(pos: u64, new_read: u64) bool {
    return pos < new_read;
}

test "parse a single SCM_RIGHTS message" {
    var buf: [24]u8 = @splat(0);
    std.mem.writeInt(u64, buf[0..8], 20, .little);
    std.mem.writeInt(i32, buf[8..12], SOL_SOCKET, .little);
    std.mem.writeInt(i32, buf[12..16], SCM_RIGHTS, .little);
    std.mem.writeInt(i32, buf[16..20], 7, .little);
    const r = parseRights(&buf).ok;
    try std.testing.expectEqual(@as(usize, 1), r.count);
    try std.testing.expectEqual(@as(i32, 7), r.fds[0]);
}

test "parse rejects short, overlong and foreign messages" {
    var buf: [24]u8 = @splat(0);
    std.mem.writeInt(u64, buf[0..8], 8, .little); // shorter than the header
    try std.testing.expect(parseRights(&buf).err == .invalid);
    std.mem.writeInt(u64, buf[0..8], 64, .little); // runs past the buffer
    try std.testing.expect(parseRights(&buf).err == .invalid);
    std.mem.writeInt(u64, buf[0..8], 20, .little);
    std.mem.writeInt(i32, buf[8..12], 6, .little); // not SOL_SOCKET
    try std.testing.expect(parseRights(&buf).err == .invalid);
    std.mem.writeInt(i32, buf[8..12], SOL_SOCKET, .little);
    std.mem.writeInt(i32, buf[12..16], 3, .little); // SCM_SECURITY: unsupported
    try std.testing.expect(parseRights(&buf).err == .invalid);
    std.mem.writeInt(i32, buf[12..16], SCM_RIGHTS, .little);
    std.mem.writeInt(u64, buf[0..8], 19, .little); // payload not a multiple of 4
    try std.testing.expect(parseRights(&buf).err == .invalid);
}

test "parse caps the descriptor count" {
    var buf: [16 + 4 * 9]u8 = @splat(0);
    std.mem.writeInt(u64, buf[0..8], 16 + 4 * 9, .little);
    std.mem.writeInt(i32, buf[8..12], SOL_SOCKET, .little);
    std.mem.writeInt(i32, buf[12..16], SCM_RIGHTS, .little);
    try std.testing.expect(parseRights(&buf).err == .too_many);
    try std.testing.expectEqual(@as(usize, 0), parseRights(buf[0..0]).ok.count);
}

test "build lays out CMSG_LEN and pads to CMSG_SPACE" {
    var out: [64]u8 = @splat(0xAA);
    const b = buildRights(&[_]i32{ 5, 6 }, 64, &out);
    try std.testing.expectEqual(@as(usize, 24), b.fits * 4 + HDR);
    try std.testing.expectEqual(@as(usize, 24), b.written);
    try std.testing.expect(!b.truncated);
    try std.testing.expectEqual(@as(u64, 24), std.mem.readInt(u64, out[0..8], .little));
    try std.testing.expectEqual(@as(i32, 6), std.mem.readInt(i32, out[20..24], .little));
    const one = buildRights(&[_]i32{9}, 64, &out);
    try std.testing.expectEqual(@as(usize, 24), one.written); // CMSG_SPACE(4)
    try std.testing.expectEqual(@as(u8, 0), out[20]); // padding cleared
}

test "build truncates when the buffer is small" {
    var out: [64]u8 = @splat(0);
    const none = buildRights(&[_]i32{ 1, 2 }, 8, &out);
    try std.testing.expect(none.truncated and none.fits == 0 and none.written == 0);
    const partial = buildRights(&[_]i32{ 1, 2, 3 }, 16 + 8, &out);
    try std.testing.expectEqual(@as(usize, 2), partial.fits);
    try std.testing.expect(partial.truncated);
    try std.testing.expectEqual(@as(usize, 0), buildRights(&[_]i32{}, 64, &out).written);
}

test "queued descriptors are delivered by the read that covers their byte" {
    try std.testing.expect(deliveredBy(0, 1));
    try std.testing.expect(!deliveredBy(5, 5));
    try std.testing.expect(deliveredBy(5, 6));
}

test "a read for control data stops at descriptor boundaries" {
    // nothing queued
    try std.testing.expectEqual(@as(usize, 100), readPlan(100, null, null, true).cap);
    try std.testing.expect(!readPlan(100, null, null, true).deliver);
    // plain data in front: stop right before the set
    const front = readPlan(100, 10, null, true);
    try std.testing.expectEqual(@as(usize, 10), front.cap);
    try std.testing.expect(!front.deliver);
    // the set is next: deliver it, stop before the following one
    const own = readPlan(100, 0, 30, true);
    try std.testing.expectEqual(@as(usize, 30), own.cap);
    try std.testing.expect(own.deliver);
    const last = readPlan(100, 0, null, true);
    try std.testing.expectEqual(@as(usize, 100), last.cap);
    try std.testing.expect(last.deliver);
    // a plain read never delivers and never stops early
    const plain = readPlan(100, 0, 30, false);
    try std.testing.expectEqual(@as(usize, 100), plain.cap);
    try std.testing.expect(!plain.deliver);
}
