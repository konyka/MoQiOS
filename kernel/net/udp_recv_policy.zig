//! Pure decision for a UDP receive on a (possibly empty) queue.
//!
//! A datagram socket never reports EOF: an empty queue is "no data yet", so
//! the call waits (blocking sockets), fails with EAGAIN (O_NONBLOCK or
//! MSG_DONTWAIT, or once SO_RCVTIMEO ran out) or is cut short by a signal.

const std = @import("std");

pub const Step = enum { deliver, wait, eagain };

pub fn step(queue_has_data: bool, nonblock: bool, timed_out: bool) Step {
    if (queue_has_data) return .deliver;
    if (nonblock or timed_out) return .eagain;
    return .wait;
}

/// Absolute monotonic deadline for an SO_RCVTIMEO of `timeout_ms`; null waits
/// forever. The clock is only read for sockets that set a timeout.
pub fn deadlineNs(now_ns: u64, timeout_ms: u32) ?u64 {
    if (timeout_ms == 0) return null;
    return now_ns +| @as(u64, timeout_ms) * 1_000_000;
}

pub fn timedOut(deadline: ?u64, now_ns: u64) bool {
    const d = deadline orelse return false;
    return now_ns >= d;
}

test "an empty UDP queue waits, fails or delivers" {
    try std.testing.expectEqual(Step.deliver, step(true, false, false));
    try std.testing.expectEqual(Step.deliver, step(true, true, true));
    try std.testing.expectEqual(Step.wait, step(false, false, false));
    try std.testing.expectEqual(Step.eagain, step(false, true, false));
    try std.testing.expectEqual(Step.eagain, step(false, false, true));
}

test "receive timeout deadline" {
    try std.testing.expectEqual(@as(?u64, null), deadlineNs(100, 0));
    try std.testing.expectEqual(@as(?u64, 100 + 5_000_000), deadlineNs(100, 5));
    try std.testing.expect(!timedOut(null, 1 << 60));
    try std.testing.expect(!timedOut(10, 9));
    try std.testing.expect(timedOut(10, 10));
}
