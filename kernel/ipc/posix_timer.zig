/// POSIX Timers — timer_create / timer_settime / timer_gettime / timer_getoverrun / timer_delete.
///
/// Deadlines are kept in TSC nanoseconds (the CLOCK_MONOTONIC clock), so timer_gettime reports the time left to the nanosecond and a
/// lagging tick never pushes an expiry back; the BSP timer tick checks them against tsc.nanos(), so a timer is noticed within one
/// tick (~10 ms) of its deadline. Max 16 timers.
/// A SIGEV_SIGNAL timer queues at most one signal at a time (Linux keeps one sigqueue per timer): it carries SI_TIMER, the timer id
/// and the sigev_value, expiries before it is taken are counted as its si_overrun (filled in at delivery, takeSignal), and
/// timer_getoverrun reports the overrun of the last delivered signal. A NULL sigevent means SIGALRM with the timer id as the value.
const std = @import("std");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const DeadlineHint = @import("../lib/deadline_hint.zig").DeadlineHint;
const copy = @import("../mm/copy_from_user.zig");
const sched_mod = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const time_policy = @import("time_policy.zig");
const owner_gen_policy = @import("owner_gen_policy.zig");
const timer_policy = @import("posix_timer_policy.zig");
const tsc = @import("../arch/arch.zig").tsc;

const MAX_TIMERS: u32 = 16;

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
const SIGEV_NONE: i32 = timer_policy.SIGEV_NONE;
const SIGEV_SIGNAL: i32 = timer_policy.SIGEV_SIGNAL;
const SIGEV_THREAD_ID: i32 = timer_policy.SIGEV_THREAD_ID;
const SIGALRM: i32 = 14;

/// Timer flags
const TIMER_ABSTIME: u32 = timer_policy.TIMER_ABSTIME;

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
    /// CLOCK_MONOTONIC deadline in nanoseconds (tsc.nanos()); 0 when disarmed.
    expiry_ns: u64 = 0,
    sigev_value: u64 = 0,
    /// Bumped on every create and kept across delete: a queued signal of a deleted timer is not charged to its successor.
    generation: u32 = 0,
    /// The timer's one signal: owed / queued and the overruns piling up behind it.
    sig: timer_policy.SigState = .{},
    /// si_overrun of the last delivered signal (timer_getoverrun).
    last_overrun: u64 = 0,
    sigev_signo: i32 = 0,
    sigev_notify: i32 = SIGEV_NONE,
    /// Task that created the timer — signals go here, not to the task
    /// that happens to be running when the tick fires. With SIGEV_THREAD_ID the signal goes to target_tid instead.
    owner_task_idx: ?u32 = null,
    target_tid: u32 = 0,
    /// Owner tid recorded at creation — a slot INDEX alone aliases after the
    /// owner exits and its slot is recycled; the tid match proves identity.
    owner_tid: u32 = 0,
    owner_group_tid: u32 = 0,
};

// Global pool
var timers: [MAX_TIMERS]PosixTimer = @splat(.{});
var lock: IrqSpinlock = .{};
/// Earliest armed expiry_ns: lets the per-tick scan skip `lock`.
var expiry_hint: DeadlineHint = .{};

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
    if (!timer_policy.timerIdPointerValid(timerid_ptr) or
        !copy.validateUserBufferWritable(timerid_ptr, 4)) return EFAULT;
    if (!timer_policy.sigeventPointerValid(sigev_ptr)) return EFAULT;

    // Read optional sigevent from user space. Without one the timer sends SIGALRM with its id as the value (Linux do_timer_create).
    var sigev_notify: i32 = SIGEV_SIGNAL;
    var sigev_signo: i32 = SIGALRM;
    var sigev_value: ?u64 = null;
    var thread_tid: u32 = 0;
    if (sigev_ptr != 0) {
        var sigev_buf: [@sizeOf(Sigevent)]u8 = undefined;
        const copied = copy.copyFromUser(&sigev_buf, @ptrFromInt(sigev_ptr), @sizeOf(Sigevent));
        if (copied != @sizeOf(Sigevent)) return EFAULT;
        const sigev: *const Sigevent = @ptrCast(@alignCast(&sigev_buf));
        sigev_notify = sigev.sigev_notify;
        sigev_signo = sigev.sigev_signo;
        sigev_value = @bitCast(sigev.sigev_value);
        // sigev_notify_thread_id sits at offset 16 (the first int of the union).
        thread_tid = @bitCast(sigev._pad[0..4].*);
    }
    if (!timer_policy.sigeventValid(sigev_notify, sigev_signo)) return EINVAL;

    const owner_idx = sched_mod.currentTaskIndex();
    const owner_tid: u32 = if (owner_idx) |oi|
        (if (task_mod.getTask(oi)) |ot| ot.tid else 0)
    else
        0;
    const owner_group_tid: u32 = if (owner_idx) |oi|
        (if (task_mod.getTask(oi)) |ot| timer_policy.timerOwnerTid(ot.is_thread, ot.tid, ot.parent_tid) else 0)
    else
        0;
    // SIGEV_THREAD_ID: the named tid must be a live thread of the caller's process (Linux good_sigevent). Resolved before the
    // timer lock: findTaskByTid takes the task lock, and the early returns must not release a lock the defer also releases.
    const target_tid = timer_policy.signalTarget(sigev_notify, thread_tid, owner_tid);
    if ((sigev_notify & SIGEV_THREAD_ID) != 0) {
        const ti = task_mod.findTaskByTid(target_tid) orelse return EINVAL;
        const tt = task_mod.getTask(ti) orelse return EINVAL;
        if (tt.state == .zombie or timer_policy.timerOwnerTid(tt.is_thread, tt.tid, tt.parent_tid) != owner_group_tid) return EINVAL;
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
                .expiry_ns = 0,
                .sigev_value = sigev_value orelse i,
                .generation = t.generation +% 1,
                .sigev_signo = sigev_signo,
                .sigev_notify = sigev_notify,
                .owner_task_idx = owner_idx,
                .owner_tid = owner_tid,
                .owner_group_tid = owner_group_tid,
                .target_tid = target_tid,
            };
            // Write timer ID to user space
            const id: i32 = @intCast(i);
            const id_bytes: [4]u8 = @bitCast(id);
            const written = copy.copyToUser(@ptrFromInt(timerid_ptr), &id_bytes, 4);
            if (written != 4) {
                t.* = .{ .generation = t.generation }; // roll back the slot on failure
                return EFAULT;
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
    if (!timer_policy.flagsValid(flags)) return EINVAL;
    if (new_value_ptr == 0 or new_value_ptr >= 0x0000_8000_0000_0000) return EFAULT;

    // Read new itimerspec from user space
    var new_buf: [@sizeOf(Itimerspec)]u8 = undefined;
    if (copy.copyFromUser(&new_buf, @ptrFromInt(new_value_ptr), @sizeOf(Itimerspec)) != @sizeOf(Itimerspec)) {
        return EFAULT;
    }
    const new_val: *const Itimerspec = @ptrCast(@alignCast(&new_buf));

    // Validate + convert up front: an unrepresentable user timespec is
    // EINVAL, never a wrapped (or Debug-panicking) u64 multiply.
    const interval_ns = time_policy.timespecToNs(new_val.it_interval.tv_sec, new_val.it_interval.tv_nsec) orelse return EINVAL;
    const value_ns = time_policy.timespecToNs(new_val.it_value.tv_sec, new_val.it_value.tv_nsec) orelse return EINVAL;

    if (old_value_ptr != 0 and !copy.validateUserBufferWritable(old_value_ptr, @sizeOf(Itimerspec))) return EFAULT;
    const saved = lock.acquire();

    const t = &timers[timerid];
    if (!t.valid) {
        lock.release(saved);
        return EINVAL;
    }
    const current_group_tid = currentOwnerGroupTid() orelse {
        lock.release(saved);
        return EINVAL;
    };
    if (!timer_policy.ownerMatches(t.owner_group_tid, current_group_tid)) {
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
        if (t.active and t.expiry_ns > 0) nsToTimespec(t.expiry_ns -| tsc.nanos(), &old_val.it_value);
        var old_buf: [@sizeOf(Itimerspec)]u8 = undefined;
        @memcpy(&old_buf, @as([*]const u8, @ptrCast(&old_val))[0..@sizeOf(Itimerspec)]);
        if (copy.copyToUser(@ptrFromInt(old_value_ptr), &old_buf, @sizeOf(Itimerspec)) != @sizeOf(Itimerspec)) {
            lock.release(saved);
            return EFAULT;
        }
    }

    // Set interval
    t.interval_ns = interval_ns;
    // Re-arming or disarming starts the overrun count over (Linux, measured: timer_getoverrun reads 0 after timer_settime).
    t.sig = .{};
    t.last_overrun = 0;

    // Set initial expiration
    if (value_ns == 0) {
        // Disarm the timer
        t.active = false;
        t.expiry_ns = 0;
    } else {
        const now_ns = tsc.nanos();
        // An absolute deadline becomes a delay from now on the monotonic clock; one already past fires at the next tick.
        const delay_ns = if ((flags & TIMER_ABSTIME) != 0)
            time_policy.absoluteDeltaNs(t.clock_id, value_ns, now_ns, @import("../proc/time_syscall.zig").wallClockOffset()) orelse {
                lock.release(saved);
                return EINVAL;
            }
        else
            value_ns;
        if (delay_ns > std.math.maxInt(u64) - now_ns) {
            lock.release(saved);
            return EINVAL;
        }
        t.expiry_ns = now_ns + delay_ns;
        t.active = true;
        expiry_hint.arm(t.expiry_ns);
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
    const current_group_tid = currentOwnerGroupTid() orelse return EINVAL;
    if (!timer_policy.ownerMatches(t.owner_group_tid, current_group_tid)) return EINVAL;

    var val: Itimerspec = .{
        .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
        .it_value = .{ .tv_sec = 0, .tv_nsec = 0 },
    };

    nsToTimespec(t.interval_ns, &val.it_interval);

    // An expired timer reports 0.
    if (t.active and t.expiry_ns > 0) nsToTimespec(t.expiry_ns -| tsc.nanos(), &val.it_value);

    var buf: [@sizeOf(Itimerspec)]u8 = undefined;
    @memcpy(&buf, @as([*]const u8, @ptrCast(&val))[0..@sizeOf(Itimerspec)]);
    if (copy.copyToUser(@ptrFromInt(curr_value_ptr), &buf, @sizeOf(Itimerspec)) != @sizeOf(Itimerspec)) {
        return EFAULT;
    }
    return 0;
}

/// timer_getoverrun(timerid) -> overrun count or -errno.
/// The si_overrun of the timer's last delivered signal (Linux it_overrun_last), clamped to INT_MAX; reading it does not reset it.
pub fn timerGetoverrun(timerid: u32) i64 {
    if (timerid >= MAX_TIMERS) return EINVAL;

    const saved = lock.acquire();
    defer lock.release(saved);

    const t = &timers[timerid];
    if (!t.valid) return EINVAL;
    const current_group_tid = currentOwnerGroupTid() orelse return EINVAL;
    if (!timer_policy.ownerMatches(t.owner_group_tid, current_group_tid)) return EINVAL;

    return @intCast(@min(t.last_overrun, 0x7fff_ffff));
}

/// timer_delete(timerid) -> 0 or -errno.
/// Deletes (deallocates) a POSIX timer.
pub fn timerDelete(timerid: u32) i64 {
    if (timerid >= MAX_TIMERS) return EINVAL;

    const saved = lock.acquire();
    defer lock.release(saved);

    const t = &timers[timerid];
    if (!t.valid) return EINVAL;
    const current_group_tid = currentOwnerGroupTid() orelse return EINVAL;
    if (!timer_policy.ownerMatches(t.owner_group_tid, current_group_tid)) return EINVAL;

    t.* = .{ .generation = t.generation }; // reset all fields but the slot generation
    return 0;
}

fn currentOwnerGroupTid() ?u32 {
    const idx = sched_mod.currentTaskIndex() orelse return null;
    const current = task_mod.getTask(idx) orelse return null;
    return timer_policy.timerOwnerTid(current.is_thread, current.tid, current.parent_tid);
}

/// Delete all timers owned by `task_idx`. Called from task.exitTask:
/// per-process timers die with the process (POSIX), and dropping them here
/// also closes the stale-slot window before reapZombies recycles the slot.
pub fn deleteTimersForTask(task_idx: u32) void {
    const saved = lock.acquire();
    defer lock.release(saved);

    for (&timers) |*t| {
        if (!t.valid) continue;
        const exiting = task_mod.getTask(task_idx) orelse continue;
        if (timer_policy.shouldDeleteForExit(t.owner_group_tid, exiting.is_thread, exiting.tid)) t.* = .{ .generation = t.generation };
    }
}

/// Called from the BSP timer tick with tsc.nanos(). Fires every timer whose deadline has passed.
pub fn timerTick(now_ns: u64) void {
    if (!expiry_hint.due(now_ns)) return;
    const saved = lock.acquire();
    defer lock.release(saved);
    expiry_hint.beginScan();

    for (&timers, 0..) |*t, i| {
        if (!t.valid or !t.active) continue;

        if (now_ns < t.expiry_ns) {
            expiry_hint.arm(t.expiry_ns);
        } else {
            // Every interval that has ended counts: the first is this expiry, the rest are overruns. The next expiry keeps the
            // original phase, so a late tick loses none (Linux hrtimer_forward).
            var count: u64 = 1;
            if (t.interval_ns > 0) {
                const f = time_policy.forwardPeriodic(t.expiry_ns, t.interval_ns, now_ns);
                count = f.count;
                t.expiry_ns = f.next;
                expiry_hint.arm(t.expiry_ns);
            } else {
                // One-shot: stop
                t.active = false;
            }
            if ((t.sigev_notify & ~SIGEV_THREAD_ID) == SIGEV_SIGNAL and t.sigev_signo > 0 and t.sigev_signo <= 64) notifyOwner(t, @intCast(i), count);
        }
    }
}

/// Signal the timer's owner (recorded at timer_create, the slot checked against the tid it had then) for `count` expiries. Only
/// one signal is queued at a time; expiries before it is taken are its overruns. An ignored, unblocked signal is not sent, and
/// the expiries keep counting until it can be. Caller holds `lock`.
fn notifyOwner(t: *PosixTimer, idx: u32, count: u64) void {
    const owner_idx = t.owner_task_idx orelse return;
    const owner = task_mod.getTask(owner_idx) orelse return;
    if (!owner_gen_policy.ownerMatches(t.owner_tid, owner.tid)) return;
    // SIGEV_THREAD_ID queues the signal on the named thread; anything else goes to the creator.
    const dest = if ((t.sigev_notify & SIGEV_THREAD_ID) != 0) blk: {
        const di = task_mod.findTaskByTid(t.target_tid) orelse return;
        break :blk task_mod.getTask(di) orelse return;
    } else owner;
    const sig_mod = @import("../proc/signal.zig");
    const signo: u32 = @intCast(t.sigev_signo);
    const bit = @as(u64, 1) << @intCast(signo - 1);
    const pending = @atomicLoad(u64, &dest.pending_signals, .seq_cst) | @atomicLoad(u64, &dest.grp().held_signals, .seq_cst);
    const send = timer_policy.onExpiry(&t.sig, pending & bit != 0, sig_mod.ignoredAtSend(dest, signo));
    if (count > 1) t.sig.overrun +|= count - 1;
    if (!send) return;
    const info = @import("../proc/siginfo_policy.zig").timerInfo(idx, t.generation, t.sigev_value);
    if (sig_mod.sendSignalInfoResult(dest.tid, signo, info) == 0) t.sig.queued = true;
}

/// A timer signal is being delivered: its overrun count, which becomes the timer's timer_getoverrun value, and the timer may queue
/// its next signal. 0 for a timer that was deleted (or whose slot was reused) since the signal was queued.
pub fn takeSignal(idx: u32, generation: u32) u64 {
    if (idx >= MAX_TIMERS) return 0;
    const saved = lock.acquire();
    defer lock.release(saved);
    const t = &timers[idx];
    if (!t.valid or t.generation != generation) return 0;
    const ov = timer_policy.onDeliver(&t.sig);
    t.last_overrun = ov;
    return ov;
}

/// Get current time in nanoseconds for a given clock ID.
fn getClockNs(clock_id: u32) u64 {
    return switch (clock_id) {
        time_policy.CLOCK_REALTIME => @import("../proc/time_syscall.zig").wallClockNanos(),
        time_policy.CLOCK_MONOTONIC => tsc.nanos(),
        else => 0,
    };
}
