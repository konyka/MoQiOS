/// timerfd — Linux-compatible high-precision timer via file descriptor.
///
/// Provides timerfd_create / timerfd_settime / timerfd_gettime system calls.
/// A read() on the timerfd returns the number of expirations as a u64.
/// Integrates with epoll via epollNotify(EPOLLIN) on expiration.
///
/// Design:
///   - Global pool of 16 TimerInstance slots
///   - Each timer tracks clock_id, interval, expiry_ns (CLOCK_MONOTONIC, tsc.nanos()) and expirations
///   - timerTick(now_ns) called from the BSP timer tick to check for expirations
///   - Blocking read when no expirations and !TFD_NONBLOCK
///   - TSC-based nanosecond resolution for absolute time conversion
const std = @import("std");
const sched = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const DeadlineHint = @import("../lib/deadline_hint.zig").DeadlineHint;
const tsc = @import("../arch/arch.zig").tsc;
const bo = @import("../lib/byte_order.zig");
const time_policy = @import("time_policy.zig");

/// Limits.
pub const MAX_TIMERFD_INSTANCES: u32 = 16;

/// Clock IDs (Linux ABI).
pub const CLOCK_REALTIME: u32 = 0;
pub const CLOCK_MONOTONIC: u32 = 1;

/// timerfd_create flags.
pub const TFD_CLOEXEC: u32 = 0x80000;
pub const TFD_NONBLOCK: u32 = 0x800;

/// timerfd_settime flags.
pub const TFD_TIMER_ABSTIME: u32 = 1;

/// Linux timespec structure (16 bytes).
pub const Timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

/// Linux itimerspec structure (32 bytes).
pub const Itimerspec = extern struct {
    it_interval: Timespec,
    it_value: Timespec,
};

/// WaitNode for blocking read — stack-allocated on the waiter's kernel stack.
const WaitNode = struct {
    task_idx: u32,
    granted: bool = false,
    next: ?*WaitNode = null,
};

/// TimerInstance — one active timerfd.
pub const TimerInstance = struct {
    active: bool = false,
    /// Cross-process references (fork/clone) — timerfdClose frees at 0 only.
    ref_count: u32 = 1,
    clock_id: u32 = 0,
    interval_ns: u64 = 0,
    /// CLOCK_MONOTONIC deadline in nanoseconds (tsc.nanos()); 0 when disarmed.
    expiry_ns: u64 = 0,
    expirations: u64 = 0,
    flags: u32 = 0,
    waiter: ?*WaitNode = null,
    valid: bool = false,
    /// Slot incarnation, bumped on every create and preserved across close:
    /// a blocked reader that wakes to a different generation was closed out
    /// (the slot got reused) and must return EBADF.
    generation: u64 = 0,
};

// Global pool
var timer_pool: [MAX_TIMERFD_INSTANCES]TimerInstance = @splat(.{});

/// Global lock protecting the timer pool.
var timer_lock: IrqSpinlock = .{};

/// Earliest armed expiry_ns: lets the per-tick scan skip timer_lock.
var expiry_hint: DeadlineHint = .{};

fn timespecToNs(ts: Timespec) ?u64 {
    return time_policy.timespecToNs(ts.tv_sec, ts.tv_nsec);
}

fn toTimespec(ns: u64) Timespec {
    return .{ .tv_sec = @intCast(ns / 1_000_000_000), .tv_nsec = @intCast(ns % 1_000_000_000) };
}

/// The current value of an instance: the interval, and the time left until the next expiry (zero when disarmed).
fn currentValue(inst: *const TimerInstance) Itimerspec {
    if (!inst.active) return .{ .it_interval = toTimespec(0), .it_value = toTimespec(0) };
    // A deadline that has passed but not been noticed by the tick yet reports 0 left (Linux timerfd_get_remaining clamps at 0).
    return .{ .it_interval = toTimespec(inst.interval_ns), .it_value = toTimespec(inst.expiry_ns -| tsc.nanos()) };
}

/// Create a new timerfd instance.
/// Returns the pool index or a negative errno on failure.
pub fn timerfdCreate(clock_id: u32, flags: u32) i32 {
    // Validate clock_id
    if (clock_id != CLOCK_REALTIME and clock_id != CLOCK_MONOTONIC) {
        return -22; // EINVAL
    }
    // Only TFD_NONBLOCK | TFD_CLOEXEC are recognized (Linux timerfd_create).
    if (!time_policy.timerfdFlagsValid(flags)) return -22; // EINVAL

    const saved = timer_lock.acquire();
    defer timer_lock.release(saved);

    for (&timer_pool, 0..) |*inst, i| {
        if (!inst.valid) {
            inst.* = .{
                .active = false,
                .clock_id = clock_id,
                .interval_ns = 0,
                .expiry_ns = 0,
                .expirations = 0,
                .flags = flags,
                .valid = true,
                .generation = inst.generation +% 1,
            };
            return @intCast(i);
        }
    }
    return -24; // EMFILE
}

/// Arm or disarm the timer.
/// Returns 0 on success, negative errno on failure.
pub fn timerfdSettime(timerfd_idx: u32, flags: u32, new_value: *const Itimerspec, old_value: ?*Itimerspec) i32 {
    if (timerfd_idx >= MAX_TIMERFD_INSTANCES) return -9; // EBADF
    if (flags & ~@as(u32, TFD_TIMER_ABSTIME) != 0) return -22; // EINVAL
    const value_ns = timespecToNs(new_value.it_value) orelse return -22;
    const interval_ns = timespecToNs(new_value.it_interval) orelse return -22;

    const saved = timer_lock.acquire();
    defer timer_lock.release(saved);

    const inst = &timer_pool[timerfd_idx];
    if (!inst.valid) return -9; // EBADF

    // Fill old_value if requested
    if (old_value) |old| old.* = currentValue(inst);

    // Disarm if it_value is zero
    if (value_ns == 0) {
        inst.active = false;
        inst.expiry_ns = 0;
        inst.interval_ns = 0;
        inst.expirations = 0;
        return 0;
    }

    // Set interval
    inst.interval_ns = interval_ns;

    // The deadline on the monotonic nanosecond clock; an absolute time is first turned into a delay from now (an absolute time in
    // the past expires at once).
    const now_ns = tsc.nanos();
    const delay_ns = if ((flags & TFD_TIMER_ABSTIME) != 0)
        time_policy.absoluteDeltaNs(inst.clock_id, value_ns, now_ns, @import("../proc/time_syscall.zig").wallClockOffset()) orelse return -22
    else
        value_ns;
    if (delay_ns > std.math.maxInt(u64) - now_ns) return -22;
    inst.expiry_ns = @max(now_ns + delay_ns, 1);

    inst.active = true;
    inst.expirations = 0;
    expiry_hint.arm(inst.expiry_ns);

    return 0;
}

/// Get the current timer value.
/// Returns 0 on success, negative errno on failure.
pub fn timerfdGettime(timerfd_idx: u32, curr_value: *Itimerspec) i32 {
    if (timerfd_idx >= MAX_TIMERFD_INSTANCES) return -9; // EBADF

    const saved = timer_lock.acquire();
    defer timer_lock.release(saved);

    const inst = &timer_pool[timerfd_idx];
    if (!inst.valid) return -9; // EBADF

    curr_value.* = currentValue(inst);

    return 0;
}

/// Unlink a wait node from the instance waiter list. Caller holds timer_lock.
/// tick/close pop the node they wake; this covers wakes that bypass the queue
/// (signal kick) so the stack-allocated node never dangles.
fn unlinkWaiter(inst: *TimerInstance, node: *WaitNode) void {
    var prev: ?*WaitNode = null;
    var cur = inst.waiter;
    while (cur) |n| {
        if (n == node) {
            if (prev) |p| {
                p.next = n.next;
            } else {
                inst.waiter = n.next;
            }
            n.next = null;
            return;
        }
        prev = n;
        cur = n.next;
    }
}

/// Read from a timerfd instance.
/// Returns 8 on success (u64 expiration count), -EBADF if the instance was
/// destroyed while waiting, -EINTR on signal, -EAGAIN if non-blocking.
pub fn timerfdRead(timerfd_idx: u32, buf: [*]u8, count: usize, nonblock: bool) i64 {
    if (timerfd_idx >= MAX_TIMERFD_INSTANCES) return -9; // EBADF
    if (count < 8) return -22; // EINVAL

    var generation: ?u64 = null;
    while (true) {
        const saved = timer_lock.acquire();
        const inst = &timer_pool[timerfd_idx];
        if (!inst.valid) {
            timer_lock.release(saved);
            return -9; // EBADF — destroyed (timerfdClose) while we waited
        }
        if (generation) |g| {
            if (inst.generation != g) {
                timer_lock.release(saved);
                return -9; // EBADF — closed and the slot reused while we waited
            }
        } else generation = inst.generation;
        if (inst.expirations > 0) {
            const val = inst.expirations;
            inst.expirations = 0;
            timer_lock.release(saved);
            // Write little-endian u64
            bo.writeU64At(buf, 0, val);
            return 8;
        }
        if (nonblock or (inst.flags & TFD_NONBLOCK) != 0) {
            timer_lock.release(saved);
            return -11; // EAGAIN
        }

        // Block the current task
        const cur_idx = sched.currentTaskIndex() orelse {
            timer_lock.release(saved);
            return -1;
        };
        var node: WaitNode = .{ .task_idx = cur_idx };
        // Enqueue at head
        node.next = inst.waiter;
        inst.waiter = &node;

        task_mod.blockTask(cur_idx);
        timer_lock.release(saved);

        // Yield — reschedule will pick another task
        asm volatile ("int $240");
        // 阻塞后状态修复：yield 未切换时本任务仍以 .blocked 继续运行
        @import("../proc/sched.zig").repairCurrentAfterBlock();

        // Woken up — unlink defensively (tick/close already pop their wake;
        // a signal kick leaves the node linked), then decide: re-block unless
        // the instance was destroyed (EBADF, checked at the top of the loop)
        // or a signal arrived (EINTR / fatal exit). Previously an early wake
        // (e.g. timerfdClose granting the node) surfaced as a spurious -1.
        const saved2 = timer_lock.acquire();
        unlinkWaiter(inst, &node);
        timer_lock.release(saved2);

        if (task_mod.getTask(cur_idx)) |ct| {
            const sig_mod = @import("../proc/signal.zig");
            if (sig_mod.pendingFatal(ct)) |sig| task_mod.exitTask(128 + @as(i32, @intCast(sig)));
            if (sig_mod.pendingActionable(ct)) return -4; // EINTR
        }
        // loop and re-check / re-block
    }
}

/// Add a cross-process reference (fork/clone fd-table copy).
pub fn timerfdRetain(timerfd_idx: u32) void {
    if (timerfd_idx >= MAX_TIMERFD_INSTANCES) return;
    const saved = timer_lock.acquire();
    defer timer_lock.release(saved);
    if (!timer_pool[timerfd_idx].valid) return;
    timer_pool[timerfd_idx].ref_count += 1;
}

/// Close a timerfd instance.
pub fn timerfdClose(timerfd_idx: u32) void {
    if (timerfd_idx >= MAX_TIMERFD_INSTANCES) return;

    const saved = timer_lock.acquire();
    defer timer_lock.release(saved);

    const inst = &timer_pool[timerfd_idx];
    if (!inst.valid) return;

    // Shared across fork/clone: drop one reference, free only at zero.
    if (inst.ref_count > 1) {
        inst.ref_count -= 1;
        return;
    }
    inst.ref_count = 0;

    // Wake ALL blocked waiters (the waiter stack may hold several readers) —
    // each woken reader unlinks defensively, re-checks inst.valid at the top
    // of its loop and returns EBADF. Waking only the head would strand the
    // rest on a destroyed instance (lost wakeup).
    while (inst.waiter) |node| {
        inst.waiter = node.next;
        node.next = null;
        @atomicStore(bool, &node.granted, true, .release);
        task_mod.unblockTask(node.task_idx);
    }

    // Notify epoll: hangup
    const epoll_mod = @import("../net/epoll.zig");
    epoll_mod.epollNotify(.timerfd, timerfd_idx, epoll_mod.EPOLLHUP);

    inst.* = .{ .generation = inst.generation };
}

/// Get the current expiration count (for epoll computeCurrentEvents).
pub fn timerfdGetExpirations(timerfd_idx: u32) u64 {
    if (timerfd_idx >= MAX_TIMERFD_INSTANCES) return 0;
    const inst = &timer_pool[timerfd_idx];
    if (!inst.valid) return 0;
    return inst.expirations;
}

/// Called from the BSP timer tick with tsc.nanos().
/// Checks all active timers for expiration and wakes waiters.
pub fn timerTick(now_ns: u64) void {
    if (!expiry_hint.due(now_ns)) return;
    var saved = timer_lock.acquire();
    expiry_hint.beginScan();

    for (&timer_pool, 0..) |*inst, i| {
        if (!inst.valid or !inst.active) continue;

        if (now_ns >= inst.expiry_ns) {
            if (inst.interval_ns > 0) {
                // Repeating timer: count every interval that has ended, and keep the phase: the next expiry is the first one after
                // now on the original schedule (Linux hrtimer_forward), so a tick that comes late loses no expirations.
                const f = time_policy.forwardPeriodic(inst.expiry_ns, inst.interval_ns, now_ns);
                inst.expirations +|= f.count;
                inst.expiry_ns = f.next;
                expiry_hint.arm(inst.expiry_ns);
            } else {
                // One-shot timer: stop
                inst.expirations +|= 1;
                inst.active = false;
            }

            // Wake ALL blocked waiters, not just the head: the first woken
            // reader drains expirations to 0, so a single wake would leave
            // every other reader asleep despite the expiry it should observe
            // (Linux wakes all readers).
            while (inst.waiter) |node| {
                inst.waiter = node.next;
                node.next = null;
                @atomicStore(bool, &node.granted, true, .release);
                task_mod.unblockTask(node.task_idx);
            }

            // Notify epoll
            const idx: u32 = @intCast(i);
            // Must release lock before calling epollNotify (it acquires its own locks)
            timer_lock.release(saved);
            const epoll_mod = @import("../net/epoll.zig");
            epoll_mod.epollNotify(.timerfd, idx, epoll_mod.EPOLLIN);
            // Re-acquire for next iteration
            saved = timer_lock.acquire();
        } else {
            expiry_hint.arm(inst.expiry_ns);
        }
    }

    timer_lock.release(saved);
}
