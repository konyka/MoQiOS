/// kernel/proc/time_syscall.zig — Time-related syscall implementations
///
/// Extracted from syscall_entry.zig (v19.1).
const copy = @import("../mm/copy_from_user.zig");
const tsc = @import("../arch/arch.zig").tsc;
const bo = @import("../lib/byte_order.zig");

/// Wall-clock offset from boot time (set by clock_settime, or seeded from
/// the RTC at boot by drivers/rtc.zig).
/// wall_time_ns = tsc.nanos() + wall_clock_offset
var wall_clock_offset: i64 = 0;

pub const CLOCK_REALTIME: u64 = 0;
pub const CLOCK_MONOTONIC: u64 = 1;

pub fn clockIdValid(clockid: u64) bool {
    return clock_ids.sourceOf(clockid) != null;
}

const clock_ids = @import("clock_ids.zig");

/// Set wall-clock offset so that clock_gettime returns the desired time.
pub fn setWallClockOffset(offset_ns: i64) void {
    wall_clock_offset = offset_ns;
}

pub fn wallClockOffset() i64 {
    return wall_clock_offset;
}

/// Get current wall-clock nanoseconds (boot time + offset).
pub fn wallClockNanos() u64 {
    const boot_ns: i64 = @intCast(tsc.nanos());
    const adjusted = boot_ns + wall_clock_offset;
    return @intCast(@max(adjusted, 0));
}

/// gettimeofday(tv_ptr) → 0 or -1
pub fn gettimeofday(tv_ptr: u64) i64 {
    if (tv_ptr == 0) return 0; // gettimeofday(NULL, tz): nothing to store
    if (tv_ptr >= 0x0000_8000_0000_0000) return -14;

    const ns = wallClockNanos();
    const sec = ns / 1_000_000_000;
    const usec = (ns % 1_000_000_000) / 1000;

    var tv_bytes: [16]u8 = undefined;
    bo.writeU64Le(tv_bytes[0..8], sec);
    const usec_i64: i64 = @intCast(usec);
    bo.writeI64Le(tv_bytes[8..16], usec_i64);

    if (copy.copyToUser(@ptrFromInt(tv_ptr), tv_bytes[0..16], 16) != 16) return -14;
    return 0;
}

/// clock_gettime(clockid, tp_ptr) → 0 or -1
/// CLOCK_REALTIME: wall clock (RTC epoch base + TSC-since-boot). Every other
/// clock id (CLOCK_MONOTONIC included) reports the raw TSC-since-boot time,
/// exactly as before the RTC base existed.
pub fn clock_gettime(clockid: u64, tp_ptr: u64) i64 {
    if (!clockIdValid(clockid)) return -22;
    if (tp_ptr == 0 or tp_ptr >= 0x0000_8000_0000_0000) return -14;

    const ns: u64 = switch (clock_ids.sourceOf(clockid).?) {
        .realtime => wallClockNanos(),
        .monotonic => tsc.nanos(),
        .process_cpu => cpuTimeNs(false),
        .thread_cpu => cpuTimeNs(true),
    };
    const sec = ns / 1_000_000_000;
    const nsec = ns % 1_000_000_000;

    var ts_bytes: [16]u8 = undefined;
    bo.writeU64Le(ts_bytes[0..8], sec);
    const nsec_i64: i64 = @intCast(nsec);
    bo.writeI64Le(ts_bytes[8..16], nsec_i64);

    if (copy.copyToUser(@ptrFromInt(tp_ptr), ts_bytes[0..16], 16) != 16) return -14;
    return 0;
}

/// CPU time consumed by the calling thread (`thread`) or process (this kernel
/// keeps per-task accounting, so a process is its main task plus nothing more
/// that we can attribute here; the calling task's time is the honest answer).
fn cpuTimeNs(thread: bool) u64 {
    _ = thread;
    const sched = @import("sched.zig");
    const task_mod = @import("task.zig");
    const rusage_policy = @import("rusage_policy.zig");
    const idx = sched.currentTaskIndex() orelse return 0;
    const t = task_mod.getTask(idx) orelse return 0;
    const in_flight = rusage_policy.runtimeUs(0, t.sched_in_tsc, tsc.read(), tsc.tsc_freq_mhz);
    return (t.utime_us +| t.stime_us +| in_flight) *| 1000;
}
