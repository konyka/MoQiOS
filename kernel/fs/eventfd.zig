/// eventfd — lightweight event notification mechanism.
///
/// Provides a simple file-descriptor-based event notification that can be
/// used for signaling between kernel subsystems or user-space processes.
///
/// Design (Linux eventfd2 semantics):
///   - Global pool of 16 eventfd instances
///   - Each instance holds a 64-bit counter (max 2^64-2)
///   - Read (8 bytes): blocks while counter == 0 (or -EAGAIN when the fd is
///     nonblocking); default mode drains the counter and returns its value,
///     EFD_SEMAPHORE mode decrements by 1 and returns 1
///   - Write (8 bytes): blocks while counter + val would exceed 2^64-2 (or
///     -EAGAIN when nonblocking); val == 2^64-1 is -EINVAL
///   - Wake-ups are a broadcast: every blocked reader/writer is woken and
///     re-checks its own condition
///   - Supports epoll integration via epollNotify
const sched = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const idt = @import("../arch/arch.zig").interrupts;
const bo = @import("../lib/byte_order.zig");
const eventfd_policy = @import("eventfd_policy.zig");

/// Limits.
pub const MAX_EVENTFD_INSTANCES: u32 = 16;

/// eventfd2 creation flags (Linux ABI). EFD_NONBLOCK matches O_NONBLOCK and
/// is stored in the fd's status_flags; EFD_SEMAPHORE is an instance property.
pub const EFD_SEMAPHORE: u32 = 1;
pub const EFD_NONBLOCK: u32 = 0x800;
pub const EFD_CLOEXEC: u32 = 0x80000;

/// Eventfd instance.
pub const EventfdInstance = struct {
    counter: u64 = 0,
    spin: IrqSpinlock = .{},
    /// EFD_SEMAPHORE: read decrements by 1 and returns 1 instead of draining.
    semaphore: bool = false,
    /// Readers blocked on counter == 0 — stack-allocated on each waiter's
    /// kernel stack.
    read_waiters: ?*WaitNode = null,
    /// Writers blocked because the counter has no room for their value.
    write_waiters: ?*WaitNode = null,
    owner_task_idx: u32 = 0,
    /// Cross-process references (fork/clone) — eventfdClose frees at 0 only.
    ref_count: u32 = 1,
    valid: bool = false,
};

/// WaitNode for blocking read/write — stack-allocated on the waiter's kernel
/// stack.
const WaitNode = struct {
    task_idx: u32,
    granted: bool = false,
    next: ?*WaitNode = null,
};

// Global pool
var eventfd_pool: [MAX_EVENTFD_INSTANCES]EventfdInstance = @splat(.{});

/// Global lock protecting the pool claim scan (find-and-initialize must be
/// atomic across CPUs — mirrors timerfd.timer_lock). Never held together
/// with a per-instance `spin`.
var pool_lock: IrqSpinlock = .{};

/// Create a new eventfd instance.
/// Returns the pool index or a negative errno on failure.
pub fn eventfdCreate(init_val: u64, semaphore: bool) i32 {
    const cur_idx = sched.currentTaskIndex() orelse return -24; // EMFILE
    const saved = pool_lock.acquire();
    defer pool_lock.release(saved);
    for (&eventfd_pool, 0..) |*inst, i| {
        if (!inst.valid) {
            inst.* = .{
                .counter = init_val,
                .semaphore = semaphore,
                .owner_task_idx = cur_idx,
                .ref_count = 1,
                .valid = true,
            };
            return @intCast(i);
        }
    }
    return -24; // EMFILE
}

/// eventfd2(initval, flags): validate flags, create an instance, and install
/// a real fd (mirrors inotifyInit). Returns fd or -errno.
pub fn eventfdCreateFd(init_val: u64, flags: u32) i64 {
    if (flags & ~(EFD_SEMAPHORE | EFD_NONBLOCK | EFD_CLOEXEC) != 0) return -22; // EINVAL
    const cur_idx = sched.currentTaskIndex() orelse return -24;
    const cur = task_mod.getTask(cur_idx) orelse return -24;

    const inst_idx = eventfdCreate(init_val, (flags & EFD_SEMAPHORE) != 0);
    if (inst_idx < 0) return inst_idx;

    const slot = cur.fd_table.allocFd() orelse {
        eventfdClose(@intCast(inst_idx));
        return -24; // EMFILE
    };
    cur.fd_table.fds[slot] = .{
        .fd_type = .eventfd,
        .eventfd_idx = @intCast(inst_idx),
        .writable = true,
        .fd_flags = if ((flags & EFD_CLOEXEC) != 0) 1 else 0,
        .status_flags = flags & EFD_NONBLOCK,
    };
    cur.fd_table.publishFd(slot);
    return @intCast(slot);
}

/// Unlink a wait node from a waiter stack. Caller holds inst.spin.
/// Wake paths pop the nodes they wake; this covers wakes that bypass the
/// stack (signal kick) so the stack-allocated node never dangles.
fn unlinkWaiter(stack: *?*WaitNode, node: *WaitNode) void {
    var prev: ?*WaitNode = null;
    var cur = stack.*;
    while (cur) |n| {
        if (n == node) {
            if (prev) |p| {
                p.next = n.next;
            } else {
                stack.* = n.next;
            }
            n.next = null;
            return;
        }
        prev = n;
        cur = n.next;
    }
}

/// Wake every node on a waiter stack. Caller holds inst.spin. Wake-ups are a
/// broadcast (Linux semantics): each woken task re-checks its own condition
/// — a single wake would strand the rest asleep (lost wakeup).
fn wakeAll(stack: *?*WaitNode) void {
    while (stack.*) |node| {
        stack.* = node.next;
        node.next = null;
        @atomicStore(bool, &node.granted, true, .release);
        task_mod.unblockTask(node.task_idx);
    }
}

/// Block the current task on a waiter stack until woken. Caller holds
/// inst.spin; releases and re-acquires it around the sleep. Returns -4 on an
/// actionable signal (EINTR), exits the task on a fatal one; 0 means "woken,
/// re-check the condition" (mirrors the timerfdRead mechanics).
fn blockOn(stack: *?*WaitNode, inst: *EventfdInstance, saved: anytype) i64 {
    const cur_idx = sched.currentTaskIndex() orelse {
        inst.spin.release(saved);
        return -1;
    };
    var node: WaitNode = .{ .task_idx = cur_idx };
    // Enqueue at head
    node.next = stack.*;
    stack.* = &node;

    task_mod.blockTask(cur_idx);
    inst.spin.release(saved);

    // Yield — reschedule will pick another task
    asm volatile ("int $240");
    // 阻塞后状态修复：yield 未切换时本任务仍以 .blocked 继续运行
    sched.repairCurrentAfterBlock();

    // Woken — unlink defensively (wake paths already popped the node; a
    // signal kick leaves it linked), then handle signals like timerfdRead.
    const saved2 = inst.spin.acquire();
    unlinkWaiter(stack, &node);
    inst.spin.release(saved2);

    if (task_mod.getTask(cur_idx)) |ct| {
        const sig_mod = @import("../proc/signal.zig");
        if (sig_mod.pendingFatal(ct)) |sig| task_mod.exitTask(128 + @as(i32, @intCast(sig)));
        if (sig_mod.pendingActionable(ct)) return -4; // EINTR
    }
    return 0;
}

/// Read from an eventfd instance.
/// Blocks while the counter is 0 (unless the fd is nonblocking → -EAGAIN).
/// Returns 8 on success (the u64 is written to buf), -EBADF if the instance
/// was destroyed while waiting, -EINTR on signal, -EINVAL when count < 8.
pub fn eventfdRead(eventfd_idx: u32, buf: [*]u8, count: usize, status_flags: u32) i64 {
    if (eventfd_idx >= MAX_EVENTFD_INSTANCES) return -1;
    if (count < 8) return -22; // EINVAL — eventfd reads are exactly 8 bytes
    const nonblocking = (status_flags & EFD_NONBLOCK) != 0;
    const inst = &eventfd_pool[eventfd_idx];

    while (true) {
        const saved = inst.spin.acquire();
        if (!inst.valid) {
            inst.spin.release(saved);
            return -9; // EBADF — destroyed (eventfdClose) while we waited
        }
        if (inst.counter > 0) {
            const res = eventfd_policy.readResult(inst.counter, inst.semaphore);
            inst.counter = res.counter_after;
            // The counter only shrank → blocked writers may have room now.
            wakeAll(&inst.write_waiters);
            inst.spin.release(saved);

            // Write little-endian u64
            bo.writeU64At(buf, 0, res.value);

            // Notify epoll: writable now (counter shrank)
            const epoll_mod = @import("../net/epoll.zig");
            epoll_mod.epollNotify(.eventfd, eventfd_idx, epoll_mod.EPOLLOUT);
            return 8;
        }
        if (nonblocking) {
            inst.spin.release(saved);
            return -11; // EAGAIN
        }
        const rc = blockOn(&inst.read_waiters, inst, saved);
        if (rc != 0) return rc;
        // loop and re-check / re-block
    }
}

/// Write to an eventfd instance.
/// Blocks while counter + val would exceed 2^64-2 (unless the fd is
/// nonblocking → -EAGAIN). Returns 8 on success, -EINVAL when count < 8 or
/// val == 2^64-1, -EBADF if the instance was destroyed while waiting.
pub fn eventfdWrite(eventfd_idx: u32, buf: [*]const u8, count: usize, status_flags: u32) i64 {
    if (eventfd_idx >= MAX_EVENTFD_INSTANCES) return -1;
    if (count < 8) return -22; // EINVAL

    // Read little-endian u64
    const val: u64 = bo.readU64At(buf, 0);
    if (!eventfd_policy.writeValValid(val)) return -22; // EINVAL
    const nonblocking = (status_flags & EFD_NONBLOCK) != 0;
    const inst = &eventfd_pool[eventfd_idx];

    while (true) {
        const saved = inst.spin.acquire();
        if (!inst.valid) {
            inst.spin.release(saved);
            return -9; // EBADF
        }
        if (eventfd_policy.writeAdmitted(inst.counter, val)) {
            inst.counter += val;
            // Broadcast to blocked readers iff the counter became readable
            // (a no-op write onto a zero counter must not wake anyone).
            const became_readable = eventfd_policy.writeWakesReaders(inst.counter);
            if (became_readable) wakeAll(&inst.read_waiters);
            inst.spin.release(saved);

            // Notify epoll: readable now (counter > 0)
            if (became_readable) {
                const epoll_mod = @import("../net/epoll.zig");
                epoll_mod.epollNotify(.eventfd, eventfd_idx, epoll_mod.EPOLLIN);
            }
            return 8;
        }
        if (nonblocking) {
            inst.spin.release(saved);
            return -11; // EAGAIN
        }
        const rc = blockOn(&inst.write_waiters, inst, saved);
        if (rc != 0) return rc;
        // loop and re-check / re-block
    }
}

/// Add a cross-process reference (fork/clone fd-table copy).
pub fn eventfdRetain(eventfd_idx: u32) void {
    if (eventfd_idx >= MAX_EVENTFD_INSTANCES) return;
    const inst = &eventfd_pool[eventfd_idx];
    const saved = inst.spin.acquire();
    defer inst.spin.release(saved);
    if (!inst.valid) return;
    inst.ref_count += 1;
}

/// Close an eventfd instance.
pub fn eventfdClose(eventfd_idx: u32) void {
    if (eventfd_idx >= MAX_EVENTFD_INSTANCES) return;
    const inst = &eventfd_pool[eventfd_idx];

    const saved = inst.spin.acquire();
    defer inst.spin.release(saved);
    if (!inst.valid) return;

    // Shared across fork/clone: drop one reference, free only at zero.
    if (inst.ref_count > 1) {
        inst.ref_count -= 1;
        return;
    }
    inst.ref_count = 0;

    // Wake ALL blocked readers and writers — each woken task re-checks
    // inst.valid and observes the destroyed instance (-EBADF). Waking only
    // one would strand the rest on a freed slot (lost wakeup).
    wakeAll(&inst.read_waiters);
    wakeAll(&inst.write_waiters);

    // Notify epoll: hangup
    const epoll_mod = @import("../net/epoll.zig");
    epoll_mod.epollNotify(.eventfd, eventfd_idx, epoll_mod.EPOLLHUP);

    // Clear payload without resetting the held spinlock word.
    inst.counter = 0;
    inst.semaphore = false;
    inst.read_waiters = null;
    inst.write_waiters = null;
    inst.owner_task_idx = 0;
    inst.ref_count = 0;
    inst.valid = false;
}

/// Get the current counter value (for epoll computeCurrentEvents).
pub fn eventfdGetCounter(eventfd_idx: u32) u64 {
    if (eventfd_idx >= MAX_EVENTFD_INSTANCES) return 0;
    const inst = &eventfd_pool[eventfd_idx];
    if (!inst.valid) return 0;
    return inst.counter;
}
