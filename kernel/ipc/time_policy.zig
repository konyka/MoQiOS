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
pub const CLOCK_MONOTONIC_RAW: u32 = 4;
pub const CLOCK_REALTIME_COARSE: u32 = 5;
pub const CLOCK_MONOTONIC_COARSE: u32 = 6;
pub const CLOCK_BOOTTIME: u32 = 7;
/// TAI counts on the realtime base plus the TAI offset adjtimex(ADJ_TAI) sets (0 at boot; no leap-second table).
pub const CLOCK_TAI: u32 = 11;
/// CPU-time clocks: a timer on them counts the process's (or the calling thread's) CPU time, not wall time. `timerClockBase` has no
/// base for them; posix_timer accounts their expiries from the scheduler tick.
pub const CLOCK_PROCESS_CPUTIME_ID: u32 = 2;
pub const CLOCK_THREAD_CPUTIME_ID: u32 = 3;

pub fn isCpuClock(clock_id: u32) bool {
    return clock_id == CLOCK_PROCESS_CPUTIME_ID or clock_id == CLOCK_THREAD_CPUTIME_ID;
}

/// Which time base a timer's TIMER_ABSTIME deadline is counted on. CLOCK_BOOTTIME shares the monotonic base: this kernel does not
/// suspend, so boot time and monotonic time are the same clock (clock_ids.zig). A clock id a timer cannot use is null.
pub fn timerClockBase(clock_id: u32) ?u32 {
    return switch (clock_id) {
        CLOCK_REALTIME => CLOCK_REALTIME,
        CLOCK_MONOTONIC, CLOCK_BOOTTIME => CLOCK_MONOTONIC,
        CLOCK_TAI => CLOCK_REALTIME,
        else => null,
    };
}

/// Why timer_create refuses a clock id (measured on Linux): the coarse clocks and MONOTONIC_RAW are EOPNOTSUPP, anything else it
/// does not implement is EINVAL. timerfd_create says EINVAL for all of them.
pub fn timerCreateErrno(clock_id: u32) ?i64 {
    if (isCpuClock(clock_id)) return null; // accepted; their expiries are counted from CPU time
    if (timerClockBase(clock_id) != null) return null;
    return switch (clock_id) {
        CLOCK_MONOTONIC_RAW, CLOCK_REALTIME_COARSE, CLOCK_MONOTONIC_COARSE => -95,
        else => -22,
    };
}

pub fn absoluteDeltaNs(clock_id: u32, deadline_ns: u64, monotonic_now_ns: u64, realtime_offset_ns: i64) ?u64 {
    const base = timerClockBase(clock_id) orelse return null;
    const now_ns: u64 = if (base == CLOCK_REALTIME) blk: {
        const mono: i128 = @intCast(monotonic_now_ns);
        const wall = mono + @as(i128, realtime_offset_ns);
        break :blk if (wall <= 0) 0 else if (wall > std.math.maxInt(u64)) std.math.maxInt(u64) else @intCast(wall);
    } else monotonic_now_ns;
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

/// A periodic timer whose expiry `expiry` (ns) has been reached at `now`: how many intervals have ended (the one at `expiry` and every
/// later one at or before `now`), and the first expiry after `now` on the same schedule, saturating. Linux hrtimer_forward keeps the
/// phase the same way, so a check that comes late counts the expiries it missed instead of restarting the period.
pub const Forward = struct { count: u64, next: u64 };
pub fn forwardPeriodic(expiry: u64, interval: u64, now: u64) Forward {
    if (interval == 0 or now < expiry) return .{ .count = if (now < expiry) 0 else 1, .next = expiry };
    const extra = (now - expiry) / interval;
    const count = extra +| 1;
    const step = std.math.mul(u64, count, interval) catch return .{ .count = count, .next = std.math.maxInt(u64) };
    return .{ .count = count, .next = expiry +| step };
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

test "CLOCK_BOOTTIME timers share the monotonic base and the rest are rejected" {
    const t = std.testing;
    try t.expectEqual(@as(?u32, CLOCK_MONOTONIC), timerClockBase(CLOCK_BOOTTIME));
    try t.expectEqual(@as(?u32, CLOCK_MONOTONIC), timerClockBase(CLOCK_MONOTONIC));
    try t.expectEqual(@as(?u32, CLOCK_REALTIME), timerClockBase(CLOCK_REALTIME));
    try t.expectEqual(@as(?u32, null), timerClockBase(CLOCK_MONOTONIC_RAW));
    try t.expectEqual(@as(?u32, null), timerClockBase(2));
    // An absolute boot-time deadline 5 ms ahead of the monotonic clock is a 5 ms delay.
    try t.expectEqual(@as(?u64, 5_000_000), absoluteDeltaNs(CLOCK_BOOTTIME, 1_005_000_000, 1_000_000_000, 123));
    try t.expectEqual(@as(?u64, null), absoluteDeltaNs(CLOCK_MONOTONIC_RAW, 1, 0, 0));
    try t.expectEqual(@as(?i64, null), timerCreateErrno(CLOCK_BOOTTIME));
    try t.expectEqual(@as(?i64, -95), timerCreateErrno(CLOCK_MONOTONIC_RAW));
    try t.expectEqual(@as(?i64, -95), timerCreateErrno(CLOCK_REALTIME_COARSE));
    // clock 2 is CLOCK_PROCESS_CPUTIME_ID, a timer clock since hello308; only an unknown id is EINVAL without a specific reason.
    try t.expectEqual(@as(?i64, -22), timerCreateErrno(99));
    // CPU-time clocks are timer clocks without a wall base; their count is CPU time.
    try t.expectEqual(@as(?i64, null), timerCreateErrno(CLOCK_PROCESS_CPUTIME_ID));
    try t.expectEqual(@as(?i64, null), timerCreateErrno(CLOCK_THREAD_CPUTIME_ID));
    try t.expect(isCpuClock(CLOCK_PROCESS_CPUTIME_ID) and isCpuClock(CLOCK_THREAD_CPUTIME_ID) and !isCpuClock(CLOCK_MONOTONIC));
    // TAI counts on the realtime base and is a timer clock; its deadline is a wall-clock one.
    try t.expectEqual(@as(?u32, CLOCK_REALTIME), timerClockBase(CLOCK_TAI));
    try t.expectEqual(@as(?i64, null), timerCreateErrno(CLOCK_TAI));
    try t.expectEqual(@as(?u64, 5_000_000), absoluteDeltaNs(CLOCK_TAI, 1_005_000_000, 1_000_000_000, 0));
}
