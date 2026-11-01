//! setitimer/getitimer argument rules (Linux), kept free of kernel state so the host tests can run them.

pub const NS_PER_SEC: u64 = 1_000_000_000;
pub const ITIMER_REAL: u32 = 0;
pub const ITIMER_VIRTUAL: u32 = 1;
pub const ITIMER_PROF: u32 = 2;

/// A struct timeval as the user wrote it (both fields are signed 64-bit on x86_64).
pub const Timeval = struct { sec: i64, usec: i64 };

/// Linux timeval_valid(): non-negative seconds and 0 <= usec < 1,000,000.
pub fn timevalValid(tv: Timeval) bool {
    return tv.sec >= 0 and tv.usec >= 0 and tv.usec < 1_000_000;
}

/// Nanoseconds of a valid timeval, saturating instead of overflowing: a huge number of seconds means
/// "effectively never" rather than an arithmetic panic.
pub fn timevalNs(tv: Timeval) u64 {
    const sec: u64 = @intCast(tv.sec);
    const usec: u64 = @intCast(tv.usec);
    return (sec *| NS_PER_SEC) +| (usec * 1000);
}

/// Absolute deadline `delay_ns` after `now_ns`, saturating at the largest representable time.
pub fn deadlineNs(now_ns: u64, delay_ns: u64) u64 {
    return now_ns +| delay_ns;
}

/// Only ITIMER_REAL, ITIMER_VIRTUAL and ITIMER_PROF exist.
pub fn whichValid(which: u32) bool {
    return which <= ITIMER_PROF;
}

/// Seconds of an alarm() request in nanoseconds, saturating (alarm(0xffffffff) is ~136 years).
pub fn alarmNs(seconds: u32) u64 {
    return @as(u64, seconds) *| NS_PER_SEC;
}
