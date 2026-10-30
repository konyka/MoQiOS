//! Linux clock ids and the time source each one reads. Pure, so it is
//! host-tested; proc/time_syscall.zig supplies the actual clocks.
//!
//! There is one monotonic time base (the TSC since boot) and one wall clock
//! (RTC epoch plus that base). The ids that Linux distinguishes only by
//! adjustment (MONOTONIC_RAW is unslewed, BOOTTIME includes suspend, the
//! COARSE pair trade resolution for speed) map onto them: this kernel does
//! not slew time or suspend, so the answers are the same.

pub const Source = enum { realtime, monotonic, process_cpu, thread_cpu };

pub const CLOCK_REALTIME: u64 = 0;
pub const CLOCK_MONOTONIC: u64 = 1;
pub const CLOCK_PROCESS_CPUTIME_ID: u64 = 2;
pub const CLOCK_THREAD_CPUTIME_ID: u64 = 3;
pub const CLOCK_MONOTONIC_RAW: u64 = 4;
pub const CLOCK_REALTIME_COARSE: u64 = 5;
pub const CLOCK_MONOTONIC_COARSE: u64 = 6;
pub const CLOCK_BOOTTIME: u64 = 7;

pub fn sourceOf(clockid: u64) ?Source {
    return switch (clockid) {
        CLOCK_REALTIME, CLOCK_REALTIME_COARSE => .realtime,
        CLOCK_MONOTONIC, CLOCK_MONOTONIC_RAW, CLOCK_MONOTONIC_COARSE, CLOCK_BOOTTIME => .monotonic,
        CLOCK_PROCESS_CPUTIME_ID => .process_cpu,
        CLOCK_THREAD_CPUTIME_ID => .thread_cpu,
        else => null,
    };
}

/// clock_nanosleep / timers: the CPU-time clocks cannot be waited on here.
pub fn sleepable(clockid: u64) bool {
    return switch (sourceOf(clockid) orelse return false) {
        .realtime, .monotonic => true,
        .process_cpu, .thread_cpu => false,
    };
}

/// clock_getres: the COARSE clocks tick at the scheduler tick (1 ms here).
pub fn resolutionNs(clockid: u64) u64 {
    return switch (clockid) {
        CLOCK_REALTIME_COARSE, CLOCK_MONOTONIC_COARSE => 1_000_000,
        else => 1,
    };
}
