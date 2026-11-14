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

const ntp_policy = @import("ntp_policy.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
var ntp_state: ntp_policy.State = .{};
var ntp_lock: IrqSpinlock = .{};

/// The TAI offset adjtimex(ADJ_TAI) set, in nanoseconds: CLOCK_TAI = CLOCK_REALTIME + this.
pub fn taiOffsetNs() i64 {
    const flags = ntp_lock.acquire();
    defer ntp_lock.release(flags);
    return @as(i64, ntp_state.tai) * 1_000_000_000;
}

fn taiNanos() u64 {
    return wallClockNanos() +| @as(u64, @intCast(@max(taiOffsetNs(), 0)));
}

/// adjtimex(buf): clock_adjtime(CLOCK_REALTIME, buf).
pub fn adjtimex(buf_ptr: u64, cap_sys_time: bool) i64 {
    return clockAdjtime(CLOCK_REALTIME, buf_ptr, cap_sys_time);
}

/// clock_adjtime(clockid, buf) (Linux do_clock_adjtime / do_adjtimex): the struct is copied in before the clock id is looked
/// at; only CLOCK_REALTIME adjusts. Returns the clock state (TIME_OK / TIME_ERROR) or a negative errno.
pub fn clockAdjtime(clockid: u64, buf_ptr: u64, cap_sys_time: bool) i64 {
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000 - ntp_policy.TIMEX_SIZE) return -14;
    var buf: [ntp_policy.TIMEX_SIZE]u8 = undefined;
    if (copy.copyFromUser(buf[0..], @ptrFromInt(buf_ptr), buf.len) != buf.len) return -14;
    const clk: u32 = @truncate(clockid);
    if (clk != CLOCK_REALTIME) return ntp_policy.otherClockErrno(@as(i32, @bitCast(clk)));
    var tx = ntp_policy.decode(&buf);
    const v = ntp_policy.validate(&tx, cap_sys_time);
    if (v != 0) return v;
    if (tx.modes & ntp_policy.ADJ_SETOFFSET != 0) setWallClockOffset(wallClockOffset() +| ntp_policy.setOffsetNs(&tx));
    const now = wallClockNanos();
    const result = blk: {
        const flags = ntp_lock.acquire();
        defer ntp_lock.release(flags);
        break :blk ntp_policy.adjtimex(&ntp_state, &tx, @intCast(now / 1_000_000_000), @intCast(now % 1_000_000_000));
    };
    ntp_policy.encode(&tx, &buf);
    if (copy.copyToUser(@ptrFromInt(buf_ptr), buf[0..], buf.len) != buf.len) return -14;
    return result;
}

/// Get current wall-clock nanoseconds (boot time + offset).
pub fn wallClockNanos() u64 {
    const boot_ns: i64 = @intCast(tsc.nanos());
    const adjusted = boot_ns + wall_clock_offset;
    return @intCast(@max(adjusted, 0));
}

/// gettimeofday(tv_ptr, tz_ptr) → 0 or -EFAULT
/// Linux semantics: a bad `tv` or a bad `tz` is EFAULT (checked before anything is written), `tz` is filled
/// with {tz_minuteswest = 0, tz_dsttime = 0} (the kernel keeps no timezone, so UTC), and NULL pointers skip
/// the corresponding write.
pub fn gettimeofday(tv_ptr: u64, tz_ptr: u64) i64 {
    const user_top: u64 = 0x0000_8000_0000_0000;
    if (tv_ptr >= user_top or tz_ptr >= user_top) return -14;

    if (tv_ptr != 0) {
        const ns = wallClockNanos();
        const sec = ns / 1_000_000_000;
        const usec = (ns % 1_000_000_000) / 1000;

        var tv_bytes: [16]u8 = undefined;
        bo.writeU64Le(tv_bytes[0..8], sec);
        const usec_i64: i64 = @intCast(usec);
        bo.writeI64Le(tv_bytes[8..16], usec_i64);

        if (copy.copyToUser(@ptrFromInt(tv_ptr), tv_bytes[0..16], 16) != 16) return -14;
    }
    if (tz_ptr != 0) {
        const tz_bytes = [_]u8{0} ** 8;
        if (copy.copyToUser(@ptrFromInt(tz_ptr), tz_bytes[0..8], 8) != 8) return -14;
    }
    return 0;
}

/// clock_gettime(clockid, tp_ptr) → 0 or -1
/// CLOCK_REALTIME: wall clock (RTC epoch base + TSC-since-boot). Every other
/// clock id (CLOCK_MONOTONIC included) reports the raw TSC-since-boot time,
/// exactly as before the RTC base existed.
pub fn clock_gettime(clockid: u64, tp_ptr: u64) i64 {
    if (!clockIdValid(clockid)) return -22;
    if (tp_ptr == 0 or tp_ptr >= 0x0000_8000_0000_0000) return -14;

    const ns: u64 = if (clockid == clock_ids.CLOCK_TAI) taiNanos() else switch (clock_ids.sourceOf(clockid).?) {
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
    const sched = @import("sched.zig");
    const task_mod = @import("task.zig");
    const rusage_policy = @import("rusage_policy.zig");
    const idx = sched.currentTaskIndex() orelse return 0;
    const t = task_mod.getTask(idx) orelse return 0;
    if (!thread) return task_mod.processCpuTimes(idx, tsc.read(), tsc.tsc_freq_mhz).selfUs() *| 1000;
    const m = task_mod.cpuSnapshot(t);
    const in_flight = rusage_policy.runtimeUs(0, m.sched_in_tsc, tsc.read(), tsc.tsc_freq_mhz);
    return (m.user_us +| m.sys_us +| in_flight) *| 1000;
}
