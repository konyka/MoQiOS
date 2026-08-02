/// timerfd — Linux-compatible high-precision timer via file descriptor.
///
/// Provides timerfd_create / timerfd_settime / timerfd_gettime system calls.
/// A read() on the timerfd returns the number of expirations as a u64.
/// Integrates with epoll via epollNotify(EPOLLIN) on expiration.
///
/// Design:
///   - Global pool of 16 TimerInstance slots
///   - Each timer tracks clock_id, interval, expiry_tick, and expirations
///   - timerTick() called from scheduler tick to check for expirations
///   - Blocking read when no expirations and !TFD_NONBLOCK
///   - TSC-based nanosecond resolution for absolute time conversion
const std = @import("std");
const sched = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const idt = @import("../arch/arch.zig").interrupts;
const tsc = @import("../arch/arch.zig").tsc;
const bo = @import("../lib/byte_order.zig");

/// Limits.
pub const MAX_TIMERFD_INSTANCES: u32 = 16;

/// Timer tick rate — LAPIC timer fires at ~100Hz.
pub const TICKS_PER_SEC: u64 = 100;

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
    expiry_tick: u64 = 0,
    expirations: u64 = 0,
    flags: u32 = 0,
    waiter: ?*WaitNode = null,
    valid: bool = false,
};

// Global pool
var timer_pool: [MAX_TIMERFD_INSTANCES]TimerInstance = @splat(.{});

/// Global lock protecting the timer pool.
var timer_lock: IrqSpinlock = .{};

fn timespecToNs(ts: Timespec) ?u64 {
    if (ts.tv_sec < 0 or ts.tv_nsec < 0 or ts.tv_nsec >= 1_000_000_000) return null;
    const sec: u64 = @intCast(ts.tv_sec);
    const nsec: u64 = @intCast(ts.tv_nsec);
    if (sec > (std.math.maxInt(u64) - nsec) / 1_000_000_000) return null;
    return sec * 1_000_000_000 + nsec;
}

/// Convert nanoseconds to scheduler ticks (rounding up to at least 1 tick).
fn nsToTicks(ns: u64) ?u64 {
    if (ns == 0) return 0;
    // ns * TICKS_PER_SEC / 1_000_000_000, but avoid overflow for large ns
    const sec = ns / 1_000_000_000;
    const rem_ns = ns % 1_000_000_000;
    if (sec > std.math.maxInt(u64) / TICKS_PER_SEC) return null;
    const ticks_from_sec = sec * TICKS_PER_SEC;
    const ticks_from_rem = (rem_ns * TICKS_PER_SEC + 999_999_999) / 1_000_000_000;
    if (ticks_from_sec > std.math.maxInt(u64) - ticks_from_rem) return null;
    return ticks_from_sec + ticks_from_rem;
}

/// Convert scheduler ticks to nanoseconds.
fn ticksToNs(ticks: u64) u64 {
    const ns_per_tick = 1_000_000_000 / TICKS_PER_SEC;
    if (ticks > std.math.maxInt(u64) / ns_per_tick) return std.math.maxInt(u64);
    return ticks * ns_per_tick;
}

/// Create a new timerfd instance.
/// Returns the pool index or a negative errno on failure.
pub fn timerfdCreate(clock_id: u32, flags: u32) i32 {
    // Validate clock_id
    if (clock_id != CLOCK_REALTIME and clock_id != CLOCK_MONOTONIC) {
        return -22; // EINVAL
    }

    const saved = timer_lock.acquire();
    defer timer_lock.release(saved);

    for (&timer_pool, 0..) |*inst, i| {
        if (!inst.valid) {
            inst.* = .{
                .active = false,
                .clock_id = clock_id,
                .interval_ns = 0,
                .expiry_tick = 0,
                .expirations = 0,
                .flags = flags,
                .valid = true,
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
    const value_ticks = nsToTicks(value_ns) orelse return -22;

    const saved = timer_lock.acquire();
    defer timer_lock.release(saved);

    const inst = &timer_pool[timerfd_idx];
    if (!inst.valid) return -9; // EBADF

    // Fill old_value if requested
    if (old_value) |old| {
        if (inst.active) {
            const remaining_ticks = inst.expiry_tick -| idt.getTickCount();
            const remaining_ns = ticksToNs(remaining_ticks);
            const old_sec: i64 = @intCast(remaining_ns / 1_000_000_000);
            const old_nsec: i64 = @intCast(remaining_ns % 1_000_000_000);
            const int_sec: i64 = @intCast(inst.interval_ns / 1_000_000_000);
            const int_nsec: i64 = @intCast(inst.interval_ns % 1_000_000_000);
            old.* = .{
                .it_interval = .{ .tv_sec = int_sec, .tv_nsec = int_nsec },
                .it_value = .{ .tv_sec = old_sec, .tv_nsec = old_nsec },
            };
        } else {
            old.* = .{
                .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
                .it_value = .{ .tv_sec = 0, .tv_nsec = 0 },
            };
        }
    }

    // Disarm if it_value is zero
    if (value_ns == 0) {
        inst.active = false;
        inst.expiry_tick = 0;
        inst.interval_ns = 0;
        return 0;
    }

    // Set interval
    inst.interval_ns = interval_ns;

    // Calculate expiry
    if ((flags & TFD_TIMER_ABSTIME) != 0) {
        // Absolute time: convert to tick
        const abs_ns = value_ns;
        const current_ns = tsc.nanos();
        if (abs_ns > current_ns) {
            const delta = nsToTicks(abs_ns - current_ns) orelse return -22;
            const now = idt.getTickCount();
            if (delta > std.math.maxInt(u64) - now) return -22;
            inst.expiry_tick = now + delta;
        } else {
            // Already expired
            inst.expiry_tick = idt.getTickCount();
        }
    } else {
        // Relative time
        const now = idt.getTickCount();
        if (value_ticks > std.math.maxInt(u64) - now) return -22;
        inst.expiry_tick = now + value_ticks;
    }

    inst.active = true;
    inst.expirations = 0;

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

    if (inst.active) {
        const remaining_ticks = inst.expiry_tick -| idt.getTickCount();
        const remaining_ns = ticksToNs(remaining_ticks);
        const val_sec: i64 = @intCast(remaining_ns / 1_000_000_000);
        const val_nsec: i64 = @intCast(remaining_ns % 1_000_000_000);
        const int_sec: i64 = @intCast(inst.interval_ns / 1_000_000_000);
        const int_nsec: i64 = @intCast(inst.interval_ns % 1_000_000_000);
        curr_value.* = .{
            .it_interval = .{ .tv_sec = int_sec, .tv_nsec = int_nsec },
            .it_value = .{ .tv_sec = val_sec, .tv_nsec = val_nsec },
        };
    } else {
        curr_value.* = .{
            .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
            .it_value = .{ .tv_sec = 0, .tv_nsec = 0 },
        };
    }

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
pub fn timerfdRead(timerfd_idx: u32, buf: [*]u8, count: usize) i64 {
    if (timerfd_idx >= MAX_TIMERFD_INSTANCES) return -1;
    if (count < 8) return -1;

    while (true) {
        const saved = timer_lock.acquire();
        const inst = &timer_pool[timerfd_idx];
        if (!inst.valid) {
            timer_lock.release(saved);
            return -9; // EBADF — destroyed (timerfdClose) while we waited
        }
        if (inst.expirations > 0) {
            const val = inst.expirations;
            inst.expirations = 0;
            timer_lock.release(saved);
            // Write little-endian u64
            bo.writeU64At(buf, 0, val);
            return 8;
        }
        if ((inst.flags & TFD_NONBLOCK) != 0) {
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
            if (sig_mod.pendingAny(ct)) return -4; // EINTR
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

    // Wake any blocked waiter
    if (inst.waiter) |node| {
        inst.waiter = node.next;
        node.next = null;
        @atomicStore(bool, &node.granted, true, .release);
        task_mod.unblockTask(node.task_idx);
    }

    // Notify epoll: hangup
    const epoll_mod = @import("../net/epoll.zig");
    epoll_mod.epollNotify(.timerfd, timerfd_idx, epoll_mod.EPOLLHUP);

    inst.* = .{};
}

/// Get the current expiration count (for epoll computeCurrentEvents).
pub fn timerfdGetExpirations(timerfd_idx: u32) u64 {
    if (timerfd_idx >= MAX_TIMERFD_INSTANCES) return 0;
    const inst = &timer_pool[timerfd_idx];
    if (!inst.valid) return 0;
    return inst.expirations;
}

/// Called from the scheduler timer tick.
/// Checks all active timers for expiration and wakes waiters.
pub fn timerTick(current_tick: u64) void {
    var saved = timer_lock.acquire();

    for (&timer_pool, 0..) |*inst, i| {
        if (!inst.valid or !inst.active) continue;

        if (current_tick >= inst.expiry_tick) {
            if (inst.interval_ns > 0) {
                // Repeating timer: accumulate ALL missed expirations, not
                // just one — a task waking late must read the full count.
                const interval_ticks = nsToTicks(inst.interval_ns) orelse std.math.maxInt(u64);
                if (interval_ticks > 0 and interval_ticks != std.math.maxInt(u64)) {
                    const missed: u64 = 1 + (current_tick - inst.expiry_tick) / interval_ticks;
                    inst.expirations +|= missed;
                } else {
                    inst.expirations +|= 1;
                }
                // Schedule next expiration
                inst.expiry_tick = if (interval_ticks > std.math.maxInt(u64) - current_tick)
                    std.math.maxInt(u64)
                else
                    current_tick + interval_ticks;
            } else {
                // One-shot timer: stop
                inst.expirations +|= 1;
                inst.active = false;
            }

            // Wake any blocked waiter
            if (inst.waiter) |node| {
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
        }
    }

    timer_lock.release(saved);
}
