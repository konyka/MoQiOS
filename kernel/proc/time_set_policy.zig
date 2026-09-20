//! Pure validation and conversion policy for clock_settime.

pub const CLOCK_REALTIME: u32 = 0;
pub const NSEC_PER_SEC: u64 = 1_000_000_000;

pub fn canSetRealtime(has_cap_sys_time: bool) bool {
    return has_cap_sys_time;
}

pub fn requestedNanoseconds(clockid: u32, sec: u64, nsec: u64) ?i64 {
    if (clockid != CLOCK_REALTIME or nsec >= NSEC_PER_SEC) return null;
    if (sec > @as(u64, @intCast(std.math.maxInt(i64))) / NSEC_PER_SEC) return null;
    const whole = sec * NSEC_PER_SEC;
    if (nsec > @as(u64, @intCast(std.math.maxInt(i64))) - whole) return null;
    return @intCast(whole + nsec);
}

const std = @import("std");

test "clock_settime policy rejects invalid clock and overflowing times" {
    try std.testing.expectEqual(@as(?i64, 1_000_000_001), requestedNanoseconds(CLOCK_REALTIME, 1, 1));
    try std.testing.expect(requestedNanoseconds(1, 1, 0) == null);
    try std.testing.expect(requestedNanoseconds(CLOCK_REALTIME, 0, NSEC_PER_SEC) == null);
    try std.testing.expect(requestedNanoseconds(CLOCK_REALTIME, std.math.maxInt(u64), 0) == null);
}

test "clock_settime policy requires CAP_SYS_TIME" {
    try std.testing.expect(canSetRealtime(true));
    try std.testing.expect(!canSetRealtime(false));
}
