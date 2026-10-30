//! Pure policy for the bounded sendmmsg/recvmmsg ABI.
//!
//! vlen is clamped (Linux clamps to UIO_MAXIOV; this kernel keeps a smaller
//! bound), flags are validated per call, MSG_WAITFORONE turns later messages
//! non-blocking, and an optional timespec timeout ends the batch between
//! messages.

const std = @import("std");
const errno = @import("../lib/errno.zig");

pub const MAX_MESSAGES: u64 = 16;

pub const MSG_PEEK: u32 = 0x02;
pub const MSG_TRUNC: u32 = 0x20;
pub const MSG_DONTWAIT: u32 = 0x40;
pub const MSG_NOSIGNAL: u32 = 0x4000;
pub const MSG_WAITFORONE: u32 = 0x10000;
pub const MSG_CMSG_CLOEXEC: u32 = 0x4000_0000;

pub const RECV_FLAGS: u32 = MSG_PEEK | MSG_TRUNC | MSG_DONTWAIT | MSG_WAITFORONE | MSG_CMSG_CLOEXEC;
pub const SEND_FLAGS: u32 = MSG_DONTWAIT | MSG_NOSIGNAL;

pub fn clampVlen(vlen: u64) u64 {
    return @min(vlen, MAX_MESSAGES);
}

pub fn validateRecvFlags(flags: u32) i64 {
    return if ((flags & ~RECV_FLAGS) != 0) errno.EINVAL else 0;
}

pub fn validateSendFlags(flags: u32) i64 {
    return if ((flags & ~SEND_FLAGS) != 0) errno.EINVAL else 0;
}

/// Flags for the next message of a batch: MSG_WAITFORONE is the batch's own
/// flag (never passed on) and, once one message arrived, makes the rest
/// non-blocking.
pub fn messageFlags(flags: u32, delivered: u64) u32 {
    var f = flags & ~MSG_WAITFORONE;
    if ((flags & MSG_WAITFORONE) != 0 and delivered > 0) f |= MSG_DONTWAIT;
    return f;
}

/// Result of a batch that stopped on `err` after `count` messages: the count
/// if anything was transferred, else the error.
pub fn batchResult(count: u64, err: i64) i64 {
    return if (count > 0) @intCast(count) else err;
}

/// An optional recvmmsg timeout: null pointer = none. Returns the deadline in
/// ns (relative to `now_ns`), EINVAL for a malformed timespec.
pub fn timeoutDeadline(have: bool, sec: i64, nsec: i64, now_ns: u64) union(enum) { none, deadline: u64, invalid } {
    if (!have) return .none;
    if (sec < 0 or nsec < 0 or nsec >= 1_000_000_000) return .invalid;
    const total = std.math.mul(u64, @intCast(sec), 1_000_000_000) catch return .none;
    return .{ .deadline = now_ns +| (total +| @as(u64, @intCast(nsec))) };
}

pub fn expired(deadline: ?u64, now_ns: u64) bool {
    const d = deadline orelse return false;
    return now_ns >= d;
}

test "vlen is clamped, not refused" {
    try std.testing.expectEqual(@as(u64, 0), clampVlen(0));
    try std.testing.expectEqual(MAX_MESSAGES, clampVlen(MAX_MESSAGES));
    try std.testing.expectEqual(MAX_MESSAGES, clampVlen(5000));
}

test "flag validation" {
    try std.testing.expectEqual(@as(i64, 0), validateRecvFlags(MSG_DONTWAIT | MSG_WAITFORONE));
    try std.testing.expectEqual(errno.EINVAL, validateRecvFlags(0x1000_0000));
    try std.testing.expectEqual(@as(i64, 0), validateSendFlags(MSG_NOSIGNAL));
    try std.testing.expectEqual(errno.EINVAL, validateSendFlags(MSG_WAITFORONE));
}

test "MSG_WAITFORONE makes later messages non-blocking" {
    try std.testing.expectEqual(@as(u32, 0), messageFlags(MSG_WAITFORONE, 0));
    try std.testing.expectEqual(MSG_DONTWAIT, messageFlags(MSG_WAITFORONE, 1));
    try std.testing.expectEqual(MSG_DONTWAIT, messageFlags(MSG_DONTWAIT, 0));
    try std.testing.expectEqual(MSG_TRUNC, messageFlags(MSG_TRUNC | MSG_WAITFORONE, 0));
}

test "batch result and timeout" {
    try std.testing.expectEqual(@as(i64, 3), batchResult(3, -11));
    try std.testing.expectEqual(@as(i64, -11), batchResult(0, -11));
    try std.testing.expect(timeoutDeadline(false, 0, 0, 5) == .none);
    try std.testing.expect(timeoutDeadline(true, -1, 0, 5) == .invalid);
    try std.testing.expect(timeoutDeadline(true, 0, 1_000_000_000, 5) == .invalid);
    try std.testing.expectEqual(@as(u64, 5 + 1_500_000_000), timeoutDeadline(true, 1, 500_000_000, 5).deadline);
    try std.testing.expect(!expired(null, 1 << 60));
    try std.testing.expect(expired(10, 10));
}
