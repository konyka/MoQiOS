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

/// Convert nanoseconds to scheduler ticks (rounding up to at least 1 tick).
fn nsToTicks(ns: u64) u64 {
    if (ns == 0) return 0;
    // ns * TICKS_PER_SEC / 1_000_000_000, but avoid overflow for large ns
    const sec = ns / 1_000_000_000;
    const rem_ns = ns % 1_000_000_000;
    const ticks_from_sec = sec * TICKS_PER_SEC;
    const ticks_from_rem = (rem_ns * TICKS_PER_SEC + 999_999_999) / 1_000_000_000;
    return ticks_from_sec + ticks_from_rem;
}

/// Convert scheduler ticks to nanoseconds.
fn ticksToNs(ticks: u64) u64 {
    return ticks * (1_000_000_000 / TICKS_PER_SEC);
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
    const value_ns = @as(u64, @bitCast(new_value.it_value.tv_sec)) * 1_000_000_000 +
        @as(u64, @bitCast(new_value.it_value.tv_nsec));
    if (value_ns == 0) {
        inst.active = false;
        inst.expiry_tick = 0;
        inst.interval_ns = 0;
        return 0;
    }

    // Set interval
    inst.interval_ns = @as(u64, @bitCast(new_value.it_interval.tv_sec)) * 1_000_000_000 +
        @as(u64, @bitCast(new_value.it_interval.tv_nsec));

    // Calculate expiry
    if ((flags & TFD_TIMER_ABSTIME) != 0) {
        // Absolute time: convert to tick
        const abs_ns = value_ns;
        const current_ns = tsc.nanos();
        if (abs_ns > current_ns) {
            inst.expiry_tick = idt.getTickCount() + nsToTicks(abs_ns - current_ns);
        } else {
            // Already expired
            inst.expiry_tick = idt.getTickCount();
        }
    } else {
        // Relative time
        inst.expiry_tick = idt.getTickCount() + nsToTicks(value_ns);
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

/// Read from a timerfd instance.
/// Returns 8 on success (u64 expiration count), -1 on error, 0 if would block.
pub fn timerfdRead(timerfd_idx: u32, buf: [*]u8, count: usize) i64 {
    if (timerfd_idx >= MAX_TIMERFD_INSTANCES) return -1;
    const inst = &timer_pool[timerfd_idx];
    if (!inst.valid) return -1;
    if (count < 8) return -1;

    const saved = timer_lock.acquire();

    if (inst.expirations == 0) {
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

        // Woken up — check again
        const saved2 = timer_lock.acquire();
        defer timer_lock.release(saved2);

        if (inst.expirations == 0) return -1;
    } else {
        timer_lock.release(saved);
    }

    // Re-acquire to read expirations
    const saved3 = timer_lock.acquire();
    const val = inst.expirations;
    inst.expirations = 0;
    timer_lock.release(saved3);

    // Write little-endian u64
    bo.writeU64At(buf, 0, val);

    return 8;
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
    const saved = timer_lock.acquire();

    for (&timer_pool, 0..) |*inst, i| {
        if (!inst.valid or !inst.active) continue;

        if (current_tick >= inst.expiry_tick) {
            inst.expirations += 1;

            if (inst.interval_ns > 0) {
                // Repeating timer: schedule next expiration
                inst.expiry_tick = current_tick + nsToTicks(inst.interval_ns);
            } else {
                // One-shot timer: stop
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
            _ = timer_lock.acquire();
        }
    }

    timer_lock.release(saved);
}
