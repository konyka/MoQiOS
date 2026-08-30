//! Validation for the epoll_create1 flags supported by the kernel.
const std = @import("std");
const errno = @import("../lib/errno.zig");

pub const EPOLL_CLOEXEC: u32 = 0x80000;
pub const SIGSET_SIZE: u64 = 8;
pub const SIGKILL_BIT: u64 = @as(u64, 1) << 8;
pub const SIGSTOP_BIT: u64 = @as(u64, 1) << 18;
pub const UNBLOCKABLE_MASK: u64 = SIGKILL_BIT | SIGSTOP_BIT;

pub fn validate(flags: u32) i64 {
    return if (flags & ~EPOLL_CLOEXEC == 0) 0 else errno.EINVAL;
}

pub fn validateSigsetSize(size: u64) i64 {
    return if (size == SIGSET_SIZE) 0 else errno.EINVAL;
}

pub fn validateTemporaryMask(sigmask_ptr: u64, sigsetsize: u64) i64 {
    return if (sigmask_ptr == 0) 0 else validateSigsetSize(sigsetsize);
}

pub fn temporaryMask(mask: u64) u64 {
    return mask & ~UNBLOCKABLE_MASK;
}

pub const TimespecResult = union(enum) {
    milliseconds: i32,
    invalid,
};

/// Convert a non-negative Linux timespec to epoll's bounded millisecond API.
pub fn timeoutMilliseconds(tv_sec: i64, tv_nsec: i64) TimespecResult {
    if (tv_sec < 0 or tv_nsec < 0 or tv_nsec > 999_999_999) return .invalid;
    const max_ms: u64 = 0x7fffffff;
    const sec: u64 = @intCast(tv_sec);
    if (sec > max_ms / 1000) return .{ .milliseconds = @intCast(max_ms) };
    const whole_ms = sec * 1000;
    const nsec_ms = @as(u64, @intCast(@divTrunc(tv_nsec, 1_000_000)));
    const rounded_ms = if (tv_nsec != 0 and nsec_ms == 0) @as(u64, 1) else nsec_ms;
    const with_nsec = whole_ms + rounded_ms;
    return .{ .milliseconds = @intCast(@min(with_nsec, max_ms)) };
}

test "epoll_create1 accepts zero and EPOLL_CLOEXEC" {
    try std.testing.expectEqual(@as(i64, 0), validate(0));
    try std.testing.expectEqual(@as(i64, 0), validate(EPOLL_CLOEXEC));
    try std.testing.expectEqual(errno.EINVAL, validate(1));
}

test "epoll temporary mask policy validates size and excludes unblockable signals" {
    try std.testing.expectEqual(@as(i64, 0), validateTemporaryMask(0, 4));
    try std.testing.expectEqual(errno.EINVAL, validateTemporaryMask(1, 4));
    try std.testing.expectEqual(@as(i64, 0), validateSigsetSize(SIGSET_SIZE));
    try std.testing.expectEqual(errno.EINVAL, validateSigsetSize(4));
    try std.testing.expectEqual(errno.EINVAL, validateSigsetSize(16));
    try std.testing.expectEqual(@as(u64, 0x21), temporaryMask(0x21 | SIGKILL_BIT | SIGSTOP_BIT));
}

test "epoll_pwait2 timeout policy handles null-style infinity and overflow" {
    try std.testing.expectEqual(@as(i32, 0), timeoutMilliseconds(0, 0).milliseconds);
    try std.testing.expectEqual(@as(i32, 1), timeoutMilliseconds(0, 1).milliseconds);
    try std.testing.expectEqual(@as(i32, 1), timeoutMilliseconds(0, 999_999).milliseconds);
    try std.testing.expectEqual(@as(i32, 1_000_001), timeoutMilliseconds(1000, 1).milliseconds);
    try std.testing.expectEqual(@as(i32, 1500), timeoutMilliseconds(1, 500_000_000).milliseconds);
    try std.testing.expectEqual(@as(i32, 0x7fffffff), timeoutMilliseconds(std.math.maxInt(i64), 0).milliseconds);
    try std.testing.expect(timeoutMilliseconds(-1, 0) == .invalid);
    try std.testing.expect(timeoutMilliseconds(0, -1) == .invalid);
    try std.testing.expect(timeoutMilliseconds(0, 1_000_000_000) == .invalid);
}
