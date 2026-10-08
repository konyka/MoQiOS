//! Reaper kernel thread: tears down detached zombies with IRQs enabled.
//!
//! waitpid and the BSP maintenance scan only *detach* a quiesced zombie under
//! task_lock (O(1), see task.zig reapZombies / waitpidScanLocked) and queue it
//! here. The expensive part — user-driver/devfs/fbdev cleanup, the address
//! space walk that frees every user page, the kernel stack — runs in this
//! thread, outside task_lock, interruptible and preemptible by every user RT
//! task (it is SCHED_FIFO priority 1, the lowest RT level, so it still
//! preempts SCHED_OTHER work and reaps promptly). It is pinned to CPU 0 so a
//! teardown never migrates between CPUs half-way.
//!
//! A waitpid parent blocks until its child's teardown finished, so the
//! observable semantics (memory and the task slot are free once waitpid
//! returns) are unchanged. Before the reaper is running (early boot,
//! non-x86 bring-up) the callers tear down inline as they always did.
//!
//! Lock order: task_lock → reap_lock (detach queues while holding
//! task_lock); nothing takes task_lock while holding reap_lock.

const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const reap_policy = @import("reap_policy.zig");
const task = @import("task.zig");
const sched = @import("sched.zig");
const sched_claim = @import("sched_claim.zig");
const sched_policy = @import("sched_policy.zig");

var reap_lock: IrqSpinlock = .{};
var set: reap_policy.PendingSet(task.MAX_TASKS) = .{};
var reaper_wq: ?*task.WaitNode = null;
var active: u8 = 0;

const REAPER_RT_PRIORITY: u8 = 1;

pub fn isActive() bool {
    return @atomicLoad(u8, &active, .acquire) != 0;
}

/// Start the reaper. Call once from boot context after the scheduler is up.
/// Failure is reported so boot cannot silently fall back to inline teardown.
pub fn start() bool {
    const slot = task.createKernelThreadAffinity(reaperMain, 0, 0) orelse return false;
    const t = task.getTask(slot) orelse {
        task.cancelUnstartedKernelThread(slot);
        return false;
    };
    t.sched_policy = sched_policy.SCHED_FIFO;
    t.priority = sched_policy.rtToKernelPriority(REAPER_RT_PRIORITY);
    // Kernel threads are otherwise discovered only via the bitmap fallback,
    // which a busy CPU never reaches. Put it on CPU 0's queue now.
    sched.enqueue(t);
    @atomicStore(u8, &active, 1, .release);
    return true;
}

/// Queue a detached slot. Caller holds task_lock; call `wake` after
/// releasing it.
pub fn queueLocked(slot: u32, waiter: reap_policy.WaiterToken) void {
    const f = reap_lock.acquire();
    defer reap_lock.release(f);
    set.add(slot, waiter);
}

pub fn wake() void {
    const woken = blk: {
        const f = reap_lock.acquire();
        defer reap_lock.release(f);
        break :blk sched.wakeOne(&reaper_wq);
    };
    if (woken) |idx| {
        if (task.getTask(idx)) |t| sched.notifyWake(t);
    }
}

/// Block the current task until `slot`'s teardown has finished. This internal
/// wait is not interruptible: waitpid must not return before the detached
/// child's slot and resources are released.
pub fn waitDone(slot: u32) void {
    wake();
    const cur_idx = sched.currentTaskIndex() orelse return;
    const cur = task.getTask(cur_idx) orelse return;
    while (true) {
        {
            const f = reap_lock.acquire();
            defer reap_lock.release(f);
            const waiter_token: reap_policy.WaiterToken = .{
                .slot = cur_idx,
                .tid = cur.tid,
                .incarnation = cur.incarnation,
            };
            if (!set.setWaiter(slot, waiter_token)) return;
            sched_claim.store(&cur.state, .blocked);
        }
        sched.rescheduleAfterBlock();
    }
}

/// Mark `slot` torn down and return its waiter. Called by task.zig with
/// task_lock held, in the same section that frees the slot, so a reused slot
/// can never be queued while its previous incarnation is still pending.
pub fn completeLocked(slot: u32) reap_policy.WaiterToken {
    const f = reap_lock.acquire();
    defer reap_lock.release(f);
    return set.complete(slot);
}

fn takeWork() ?u32 {
    const f = reap_lock.acquire();
    defer reap_lock.release(f);
    return set.takeUnstarted();
}

fn reaperMain() callconv(.c) void {
    while (true) {
        while (takeWork()) |slot| task.teardownDetached(slot);

        var node: task.WaitNode = .{ .task_idx = 0 };
        {
            const f = reap_lock.acquire();
            defer reap_lock.release(f);
            if (set.hasUnstarted()) continue;
            // Sole waiter: drop a node left linked by a resume without wake,
            // or the re-push would link the (same) node to itself.
            reaper_wq = null;
            _ = sched.blockOn(&reaper_wq, &node);
        }
        sched.rescheduleAfterBlock();
    }
}
