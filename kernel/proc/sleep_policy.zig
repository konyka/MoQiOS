//! Pure sleep-request planning shared by nanosleep and clock_nanosleep.
//!
//! Every input is a user-controlled timespec. Malformed values are rejected;
//! well-formed but unrepresentable ones saturate to "sleep until a signal"
//! (Linux clamps to KTIME_MAX) instead of overflowing.

const std = @import("std");
const time_policy = @import("../ipc/time_policy.zig");

pub const Plan = union(enum) {
    invalid,
    immediate,
    /// Absolute deadline on the monotonic (TSC) clock, in nanoseconds.
    sleep: u64,
};

fn requestNs(sec: i64, nsec: i64) ?u64 {
    if (sec < 0 or nsec < 0 or nsec >= time_policy.NS_PER_SEC) return null;
    return time_policy.timespecToNs(sec, nsec) orelse std.math.maxInt(u64);
}

pub fn planRelative(sec: i64, nsec: i64, now_ns: u64) Plan {
    const ns = requestNs(sec, nsec) orelse return .invalid;
    if (ns == 0) return .immediate;
    return .{ .sleep = now_ns +| ns };
}

pub fn planClock(clock_id: u32, flags: u32, sec: i64, nsec: i64, now_ns: u64, realtime_offset_ns: i64) Plan {
    if (clock_id != time_policy.CLOCK_REALTIME and clock_id != time_policy.CLOCK_MONOTONIC) return .invalid;
    if (flags & ~time_policy.TIMER_ABSTIME != 0) return .invalid;
    if (flags & time_policy.TIMER_ABSTIME == 0) return planRelative(sec, nsec, now_ns);
    const target = requestNs(sec, nsec) orelse return .invalid;
    const delta = time_policy.absoluteDeltaNs(clock_id, target, now_ns, realtime_offset_ns) orelse return .invalid;
    if (delta == 0) return .immediate;
    return .{ .sleep = now_ns +| delta };
}

/// POSIX: `rem` is only meaningful for relative sleeps.
pub fn writesRemaining(flags: u32) bool {
    return flags & time_policy.TIMER_ABSTIME == 0;
}

pub const Timespec = struct { sec: u64, nsec: u64 };

pub fn remaining(deadline_ns: u64, now_ns: u64) Timespec {
    const left = deadline_ns -| now_ns;
    return .{ .sec = left / time_policy.NS_PER_SEC, .nsec = left % time_policy.NS_PER_SEC };
}
