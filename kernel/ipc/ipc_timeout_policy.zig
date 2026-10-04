//! Pure deadline rules for synchronous IPC waits.

const std = @import("std");

pub fn deadlineExpired(now: u64, deadline: u64) bool {
    return deadline != 0 and now >= deadline;
}

pub fn deadlineAfter(start: u64, timeout_ticks: u64) u64 {
    const deadline = start +% timeout_ticks;
    return if (deadline < start) std.math.maxInt(u64) else deadline;
}

pub fn wakeResult(reply_present: bool, invalidated: bool, expired: bool, signal_interrupted: bool) i32 {
    if (reply_present) return 0;
    if (invalidated) return -1;
    if (expired) return -4;
    if (signal_interrupted) return -4;
    return 0;
}

test "IPC timeout deadlines are overflow-safe and inclusive" {
    try std.testing.expect(!deadlineExpired(0, 0));
    try std.testing.expect(!deadlineExpired(9, 10));
    try std.testing.expect(deadlineExpired(10, 10));
    try std.testing.expectEqual(@as(u64, 40), deadlineAfter(10, 30));
    try std.testing.expectEqual(std.math.maxInt(u64), deadlineAfter(std.math.maxInt(u64) - 1, 3));
}

test "IPC wake precedence preserves replies and invalidation" {
    try std.testing.expectEqual(@as(i32, 0), wakeResult(true, true, true, true));
    try std.testing.expectEqual(@as(i32, -1), wakeResult(false, true, true, true));
    try std.testing.expectEqual(@as(i32, -4), wakeResult(false, false, true, true));
}
