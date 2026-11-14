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
/// TAI: REALTIME plus the kernel's TAI offset (0 here — the kernel has no adjtimex and never applies a leap-second table).
pub const CLOCK_TAI: u64 = 11;

pub fn sourceOf(clockid: u64) ?Source {
    return switch (clockid) {
        CLOCK_REALTIME, CLOCK_REALTIME_COARSE => .realtime,
        CLOCK_MONOTONIC, CLOCK_MONOTONIC_RAW, CLOCK_MONOTONIC_COARSE, CLOCK_BOOTTIME => .monotonic,
        CLOCK_TAI => .realtime,
        CLOCK_PROCESS_CPUTIME_ID => .process_cpu,
        CLOCK_THREAD_CPUTIME_ID => .thread_cpu,
        else => null,
    };
}

/// What clock_nanosleep says about a clock id (measured on Linux): REALTIME, MONOTONIC and BOOTTIME sleep;
/// MONOTONIC_RAW, REALTIME_COARSE, MONOTONIC_COARSE and THREAD_CPUTIME are EOPNOTSUPP; unknown ids are EINVAL.
/// PROCESS_CPUTIME_ID sleeps until the process's CPU clock reaches the deadline (Linux posix_cpu_nsleep): CPU time the
/// other threads of the process use counts, the sleeper's own does not move.
pub const SleepVerdict = enum { ok, process_cpu, not_supported, invalid };

pub fn sleepVerdict(clockid: u64) SleepVerdict {
    return switch (clockid) {
        CLOCK_REALTIME, CLOCK_MONOTONIC, CLOCK_BOOTTIME, CLOCK_TAI => .ok,
        CLOCK_PROCESS_CPUTIME_ID => .process_cpu,
        CLOCK_MONOTONIC_RAW, CLOCK_REALTIME_COARSE, CLOCK_MONOTONIC_COARSE, CLOCK_THREAD_CPUTIME_ID => .not_supported,
        else => .invalid,
    };
}

pub fn sleepErrno(v: SleepVerdict) i64 {
    return switch (v) {
        .ok, .process_cpu => 0,
        .not_supported => -95,
        .invalid => -22,
    };
}

/// clock_getres: the COARSE clocks tick at the scheduler tick (1 ms here).
pub fn resolutionNs(clockid: u64) u64 {
    return switch (clockid) {
        CLOCK_REALTIME_COARSE, CLOCK_MONOTONIC_COARSE => 1_000_000,
        else => 1,
    };
}
