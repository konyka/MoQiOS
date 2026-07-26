/// POSIX Timers — timer_create / timer_settime / timer_gettime / timer_getoverrun / timer_delete.
///
/// Provides the POSIX timer API using the same tick-driven mechanism as timerfd.
/// Max 16 timers, tick resolution ~10ms (100Hz LAPIC timer).
/// Signal delivery is simplified: overrun count is tracked, optional SIGEV_SIGNAL queued.
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const idt = @import("../arch/arch.zig").interrupts;
const copy = @import("../mm/copy_from_user.zig");

const MAX_TIMERS: u32 = 16;
const TICKS_PER_SEC: u64 = 100;

// Error codes
const errno = @import("../lib/errno.zig");
const EINVAL = errno.EINVAL;
const EFAULT = errno.EFAULT;
const EMFILE = errno.EMFILE;

/// Linux sigevent structure (simplified, 64 bytes on x86_64).
pub const Sigevent = extern struct {
    sigev_value: i64 = 0, // sigval (union: int or pointer)
    sigev_signo: i32 = 0,
    sigev_notify: i32 = 0,
    // Remaining bytes (sigev_notify_function, sigev_notify_attributes, padding)
    _pad: [48]u8 = @splat(0),
};

/// Notification types
const SIGEV_NONE: i32 = 1;
const SIGEV_SIGNAL: i32 = 0;
// const SIGEV_THREAD: i32 = 2; // not supported

/// Timer flags
const TIMER_ABSTIME: u32 = 1;

/// Re-export Timespec / Itimerspec from timerfd for ABI compatibility.
pub const Timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

pub const Itimerspec = extern struct {
    it_interval: Timespec,
    it_value: Timespec,
};

/// POSIX timer instance.
const PosixTimer = struct {
    active: bool = false,
    valid: bool = false,
    clock_id: u32 = 0,
    interval_ns: u64 = 0,
    expiry_tick: u64 = 0,
    overrun: u64 = 0,
    sigev_signo: i32 = 0,
    sigev_notify: i32 = SIGEV_NONE,
};

// Global pool
var timers: [MAX_TIMERS]PosixTimer = @splat(.{});
var lock: IrqSpinlock = .{};

/// Convert nanoseconds to ticks (rounding up, minimum 1 if ns > 0).
fn nsToTicks(ns: u64) u64 {
    if (ns == 0) return 0;
    const sec = ns / 1_000_000_000;
    const rem_ns = ns % 1_000_000_000;
    const ticks_from_sec = sec * TICKS_PER_SEC;
    const ticks_from_rem = (rem_ns * TICKS_PER_SEC + 999_999_999) / 1_000_000_000;
    return ticks_from_sec + ticks_from_rem;
}

/// Convert ticks to nanoseconds.
fn ticksToNs(ticks: u64) u64 {
    return ticks * (1_000_000_000 / TICKS_PER_SEC);
}

/// Convert Timespec to nanoseconds.
fn timespecToNs(ts: *const Timespec) u64 {
    if (ts.tv_sec < 0) return 0;
    const sec_ns: u64 = @intCast(ts.tv_sec);
    const nsec: u64 = if (ts.tv_nsec >= 0) @intCast(ts.tv_nsec) else 0;
    return sec_ns * 1_000_000_000 + nsec;
}

/// Fill a Timespec from nanoseconds.
fn nsToTimespec(ns: u64, ts: *Timespec) void {
    ts.tv_sec = @intCast(ns / 1_000_000_000);
    ts.tv_nsec = @intCast(ns % 1_000_000_000);
}

/// timer_create(clockid, sevp, timerid) -> 0 or -errno.
/// Creates a new POSIX timer. Writes the timer ID to *timerid.
pub fn timerCreate(clockid: u32, sigev_ptr: u64, timerid_ptr: u64) i64 {
    // Validate clock ID
    if (clockid > 1) return EINVAL; // only CLOCK_REALTIME(0) and CLOCK_MONOTONIC(1)

    // Read optional sigevent from user space
    var sigev_notify: i32 = SIGEV_NONE;
    var sigev_signo: i32 = 0;
    if (sigev_ptr != 0 and sigev_ptr < 0x0000_8000_0000_0000) {
        var sigev_buf: [@sizeOf(Sigevent)]u8 = undefined;
        const copied = copy.copyFromUser(&sigev_buf, @ptrFromInt(sigev_ptr), @sizeOf(Sigevent));
        if (copied == @sizeOf(Sigevent)) {
            const sigev: *const Sigevent = @ptrCast(@alignCast(&sigev_buf));
            sigev_notify = sigev.sigev_notify;
            sigev_signo = sigev.sigev_signo;
        }
    }

    const saved = lock.acquire();
    defer lock.release(saved);

    for (&timers, 0..) |*t, i| {
        if (!t.valid) {
            t.* = .{
                .active = false,
                .valid = true,
                .clock_id = clockid,
                .interval_ns = 0,
                .expiry_tick = 0,
                .overrun = 0,
                .sigev_signo = sigev_signo,
                .sigev_notify = sigev_notify,
            };
            // Write timer ID to user space
            const id: i32 = @intCast(i);
            const id_bytes: [4]u8 = @bitCast(id);
            if (timerid_ptr != 0 and timerid_ptr < 0x0000_8000_0000_0000) {
                const written = copy.copyToUser(@ptrFromInt(timerid_ptr), &id_bytes, 4);
                if (written != 4) return EFAULT;
            }
            return 0;
        }
    }
    return EMFILE;
}

/// timer_settime(timerid, flags, new_value, old_value) -> 0 or -errno.
/// Arms or disarms the timer.
pub fn timerSettime(timerid: u32, flags: u32, new_value_ptr: u64, old_value_ptr: u64) i64 {
    if (timerid >= MAX_TIMERS) return EINVAL;
    if (new_value_ptr == 0 or new_value_ptr >= 0x0000_8000_0000_0000) return EFAULT;

    // Read new itimerspec from user space
    var new_buf: [@sizeOf(Itimerspec)]u8 = undefined;
    if (copy.copyFromUser(&new_buf, @ptrFromInt(new_value_ptr), @sizeOf(Itimerspec)) != @sizeOf(Itimerspec)) {
        return EFAULT;
    }
    const new_val: *const Itimerspec = @ptrCast(@alignCast(&new_buf));

    if (old_value_ptr != 0 and !copy.validateUserBufferWritable(old_value_ptr, @sizeOf(Itimerspec))) return EFAULT;
    const saved = lock.acquire();

    const t = &timers[timerid];
    if (!t.valid) {
        lock.release(saved);
        return EINVAL;
    }

    // Save old value if requested
    if (old_value_ptr != 0) {
        var old_val: Itimerspec = .{
            .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
            .it_value = .{ .tv_sec = 0, .tv_nsec = 0 },
        };
        nsToTimespec(t.interval_ns, &old_val.it_interval);
        if (t.active and t.expiry_tick > 0) {
            const cur_tick = idt.getTickCount();
            if (t.expiry_tick > cur_tick) {
                const remaining_ns = ticksToNs(t.expiry_tick - cur_tick);
                nsToTimespec(remaining_ns, &old_val.it_value);
            }
        }
        var old_buf: [@sizeOf(Itimerspec)]u8 = undefined;
        @memcpy(&old_buf, @as([*]const u8, @ptrCast(&old_val))[0..@sizeOf(Itimerspec)]);
        if (copy.copyToUser(@ptrFromInt(old_value_ptr), &old_buf, @sizeOf(Itimerspec)) != @sizeOf(Itimerspec)) {
            lock.release(saved);
            return EFAULT;
        }
    }

    // Set interval
    t.interval_ns = timespecToNs(&new_val.it_interval);

    // Set initial expiration
    const value_ns = timespecToNs(&new_val.it_value);
    if (value_ns == 0) {
        // Disarm the timer
        t.active = false;
        t.expiry_tick = 0;
    } else {
        const cur_tick = idt.getTickCount();
        if ((flags & TIMER_ABSTIME) != 0) {
            // Absolute time: convert to relative ticks
            const now_ns = getClockNs(t.clock_id);
            if (value_ns <= now_ns) {
                // Already past — fire immediately
                t.expiry_tick = cur_tick;
            } else {
                t.expiry_tick = cur_tick + nsToTicks(value_ns - now_ns);
            }
        } else {
            // Relative time
            t.expiry_tick = cur_tick + nsToTicks(value_ns);
        }
        t.active = true;
        t.overrun = 0;
    }

    lock.release(saved);
    return 0;
}

/// timer_gettime(timerid, curr_value) -> 0 or -errno.
/// Reads the current timer value (remaining time and interval).
pub fn timerGettime(timerid: u32, curr_value_ptr: u64) i64 {
    if (timerid >= MAX_TIMERS) return EINVAL;
    if (curr_value_ptr == 0 or curr_value_ptr >= 0x0000_8000_0000_0000) return EFAULT;

    const saved = lock.acquire();
    defer lock.release(saved);

    const t = &timers[timerid];
    if (!t.valid) return EINVAL;

    var val: Itimerspec = .{
        .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
        .it_value = .{ .tv_sec = 0, .tv_nsec = 0 },
    };

    nsToTimespec(t.interval_ns, &val.it_interval);

    if (t.active and t.expiry_tick > 0) {
        const cur_tick = idt.getTickCount();
        if (t.expiry_tick > cur_tick) {
            const remaining_ns = ticksToNs(t.expiry_tick - cur_tick);
            nsToTimespec(remaining_ns, &val.it_value);
        }
        // else: expired, value stays 0
    }

    var buf: [@sizeOf(Itimerspec)]u8 = undefined;
    @memcpy(&buf, @as([*]const u8, @ptrCast(&val))[0..@sizeOf(Itimerspec)]);
    if (copy.copyToUser(@ptrFromInt(curr_value_ptr), &buf, @sizeOf(Itimerspec)) != @sizeOf(Itimerspec)) {
        return EFAULT;
    }
    return 0;
}

/// timer_getoverrun(timerid) -> overrun count or -errno.
/// Returns the number of extra expirations since the last notification.
pub fn timerGetoverrun(timerid: u32) i64 {
    if (timerid >= MAX_TIMERS) return EINVAL;

    const saved = lock.acquire();
    defer lock.release(saved);

    const t = &timers[timerid];
    if (!t.valid) return EINVAL;

    const result: i64 = @intCast(t.overrun);
    t.overrun = 0; // reset after reading
    return result;
}

/// timer_delete(timerid) -> 0 or -errno.
/// Deletes (deallocates) a POSIX timer.
pub fn timerDelete(timerid: u32) i64 {
    if (timerid >= MAX_TIMERS) return EINVAL;

    const saved = lock.acquire();
    defer lock.release(saved);

    const t = &timers[timerid];
    if (!t.valid) return EINVAL;

    t.* = .{}; // reset all fields
    return 0;
}

/// Called from scheduler timer tick. Checks POSIX timers for expiration.
pub fn timerTick(current_tick: u64) void {
    const saved = lock.acquire();
    defer lock.release(saved);

    for (&timers) |*t| {
        if (!t.valid or !t.active) continue;

        if (current_tick >= t.expiry_tick) {
            t.overrun +|= 1;

            if (t.interval_ns > 0) {
                // Repeating timer: schedule next expiration
                t.expiry_tick = current_tick + nsToTicks(t.interval_ns);
            } else {
                // One-shot: stop
                t.active = false;
            }

            // Simplified signal delivery: if SIGEV_SIGNAL, queue the signal
            if (t.sigev_notify == SIGEV_SIGNAL and t.sigev_signo > 0 and t.sigev_signo < 32) {
                const sched_mod = @import("../proc/sched.zig");
                const task_mod = @import("../proc/task.zig");
                if (sched_mod.currentTaskIndex()) |ci| {
                    if (task_mod.getTask(ci)) |cur| {
                        cur.pending_signals |= @as(u32, 1) << @as(u5, @intCast(t.sigev_signo));
                    }
                }
            }
        }
    }
}

/// Get current time in nanoseconds for a given clock ID.
fn getClockNs(clock_id: u32) u64 {
    _ = clock_id;
    const tsc = @import("../arch/arch.zig").tsc;
    return tsc.nanos();
}
