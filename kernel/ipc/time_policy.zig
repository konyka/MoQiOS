//! Pure time-conversion policy shared by timerfd, posix_timer, and posix_mq.
//!
//! Every input is a user-controlled timespec; conversions that can overflow
//! return null (callers map that to -EINVAL or "no timeout") instead of
//! panicking in Debug builds or wrapping into a near-immediate deadline.

const std = @import("std");

pub const NS_PER_SEC: u64 = 1_000_000_000;
pub const CLOCK_REALTIME: u32 = 0;
pub const CLOCK_MONOTONIC: u32 = 1;
pub const TIMER_ABSTIME: u32 = 1;

/// Convert an absolute deadline in the selected clock domain into a monotonic
/// delay. A deadline already in the past produces zero; invalid clock IDs
/// return null instead of silently selecting a different clock.
pub fn absoluteDeltaNs(clock_id: u32, deadline_ns: u64, monotonic_now_ns: u64, realtime_offset_ns: i64) ?u64 {
    const now_ns: u64 = if (clock_id == CLOCK_REALTIME) blk: {
        const mono: i128 = @intCast(monotonic_now_ns);
        const wall = mono + @as(i128, realtime_offset_ns);
        break :blk if (wall <= 0) 0 else if (wall > std.math.maxInt(u64)) std.math.maxInt(u64) else @intCast(wall);
    } else if (clock_id == CLOCK_MONOTONIC) monotonic_now_ns else return null;
    return if (deadline_ns > now_ns) deadline_ns - now_ns else 0;
}

/// timespec → nanoseconds. Returns null for negative fields, nsec >= 1e9,
/// or a tv_sec too large to represent in u64 nanoseconds.
pub fn timespecToNs(tv_sec: i64, tv_nsec: i64) ?u64 {
    if (tv_sec < 0 or tv_nsec < 0 or tv_nsec >= NS_PER_SEC) return null;
    const sec: u64 = @intCast(tv_sec);
    const nsec: u64 = @intCast(tv_nsec);
    if (sec > (std.math.maxInt(u64) - nsec) / NS_PER_SEC) return null;
    return sec * NS_PER_SEC + nsec;
}

/// Nanoseconds → scheduler ticks (rounding up, minimum 1 tick when ns > 0).
/// Returns null when the tick count does not fit in u64.
pub fn nsToTicks(ns: u64, ticks_per_sec: u64) ?u64 {
    if (ns == 0) return 0;
    const sec = ns / NS_PER_SEC;
    const rem_ns = ns % NS_PER_SEC;
    if (sec > std.math.maxInt(u64) / ticks_per_sec) return null;
    const ticks_from_sec = sec * ticks_per_sec;
    const ticks_from_rem = (rem_ns * ticks_per_sec + NS_PER_SEC - 1) / NS_PER_SEC;
    if (ticks_from_sec > std.math.maxInt(u64) - ticks_from_rem) return null;
    return ticks_from_sec + ticks_from_rem;
}

/// Scheduler ticks → nanoseconds, saturating at u64 max.
pub fn ticksToNs(ticks: u64, ticks_per_sec: u64) u64 {
    const ns_per_tick = NS_PER_SEC / ticks_per_sec;
    if (ticks > std.math.maxInt(u64) / ns_per_tick) return std.math.maxInt(u64);
    return ticks * ns_per_tick;
}

/// timerfd_create flag validation (Linux ABI): TFD_NONBLOCK (0x800) and
/// TFD_CLOEXEC (0x80000) are the only recognized creation flags; anything
/// else is -EINVAL. Values match timerfd.zig's TFD_* constants.
pub fn timerfdFlagsValid(flags: u32) bool {
    const TFD_NONBLOCK: u32 = 0x800;
    const TFD_CLOEXEC: u32 = 0x80000;
    return flags & ~(TFD_NONBLOCK | TFD_CLOEXEC) == 0;
}
