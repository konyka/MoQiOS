/// Futex — Fast Userspace Mutex syscall implementation.
///
/// Provides FUTEX_WAIT/WAKE/REQUEUE/CMP_REQUEUE/WAKE_OP/WAIT_BITSET/WAKE_BITSET.
/// Uses a 64-bucket hash table keyed on the futex address for O(1) lookup.
/// Integrates with the scheduler for blocking/waking tasks.
/// Timed waits (val2 = timespec*) are driven by timerTick from the BSP
/// maintenance tick (sched.zig).
const std = @import("std");
const task_mod = @import("../proc/task.zig");
const sched_mod = @import("../proc/sched.zig");
const IrqSpinlock = @import("irq_spinlock.zig").IrqSpinlock;
const copy = @import("../mm/copy_from_user.zig");
const bo = @import("../lib/byte_order.zig");
const tsc = @import("../arch/arch.zig").tsc;
const futex_key = @import("futex_key.zig");

// ── Futex operation constants (Linux ABI) ──

pub const FUTEX_WAIT: i64 = 0;
pub const FUTEX_WAKE: i64 = 1;
pub const FUTEX_REQUEUE: i64 = 3;
pub const FUTEX_CMP_REQUEUE: i64 = 4;
pub const FUTEX_WAKE_OP: i64 = 5;
pub const FUTEX_LOCK_PI: i64 = 6;
pub const FUTEX_UNLOCK_PI: i64 = 7;
pub const FUTEX_TRYLOCK_PI: i64 = 8;
pub const FUTEX_WAIT_BITSET: i64 = 9;
pub const FUTEX_WAKE_BITSET: i64 = 10;
pub const FUTEX_WAIT_REQUEUE_PI: i64 = 11;
pub const FUTEX_CMP_REQUEUE_PI: i64 = 12;
pub const FUTEX_PRIVATE: i64 = 128;
pub const FUTEX_HASH_BUCKETS: u32 = 64;

// ── Data structures ──

/// Futex hash bucket — one per bucket.
pub const FutexBucket = struct {
    head: ?*task_mod.WaitNode,
    lock: IrqSpinlock,
};

/// Global futex hash table.
pub var buckets: [FUTEX_HASH_BUCKETS]FutexBucket = @splat(.{ .head = null, .lock = .{} });

// ── Timed waits (FUTEX_WAIT / FUTEX_WAIT_BITSET timeout, val2 = timespec*) ──

/// v53.51: Per-slot absolute deadline (TSC ns) for timed futex waits, plus
/// the bucket the waiter is enqueued on. Armed bits in futex_wait_bm are
/// scanned by timerTick from the BSP maintenance tick (sched.zig) — the same
/// pattern as alarm_bm / itimer_bm.
var wait_deadlines: [task_mod.MAX_TASKS]u64 = @splat(0);
var wait_buckets: [task_mod.MAX_TASKS]?*FutexBucket = @splat(null);
pub var futex_wait_bm: u64 = 0;

/// Arm a timed-wait deadline. Caller holds bucket.lock while enqueuing, and
/// timerTick unlinks under the same lock, so arming here is race-free.
fn armWaitDeadline(task_idx: u32, bucket: *FutexBucket, deadline_ns: u64) void {
    wait_buckets[task_idx] = bucket;
    wait_deadlines[task_idx] = deadline_ns;
    // Atomic RMW — futex_wait_bm is read by the BSP timer tick on another CPU.
    _ = @atomicRmw(u64, &futex_wait_bm, .Or, @as(u64, 1) << @intCast(task_idx), .seq_cst);
}

/// Disarm a timed-wait deadline (woken, timed out, or wait abandoned).
fn disarmWaitDeadline(task_idx: u32) void {
    wait_deadlines[task_idx] = 0;
    _ = @atomicRmw(u64, &futex_wait_bm, .And, ~(@as(u64, 1) << @intCast(task_idx)), .seq_cst);
    wait_buckets[task_idx] = null;
}

/// v53.51: Parse a user timespec* (val2) into an absolute TSC-ns deadline.
/// FUTEX_WAIT passes a relative timeout, FUTEX_WAIT_BITSET an absolute one
/// (CLOCK_MONOTONIC domain — the same domain tsc.nanos() counts in).
/// Returns 0 for "wait forever" (val2 == 0).
fn parseTimeout(val2: u64, absolute: bool) error{ Fault, Invalid }!u64 {
    if (val2 == 0) return 0;
    const sec = copyUserU64Fallible(val2) catch return error.Fault;
    const nsec = copyUserU64Fallible(val2 + 8) catch return error.Fault;
    if (nsec >= 1_000_000_000) return error.Invalid;
    const ns = sec *| 1_000_000_000 +| nsec;
    if (absolute) return ns;
    return tsc.nanos() +| ns;
}

// ── Helpers ──

/// Hash a user-space address to a bucket index.
pub fn hash(addr: u64) u32 {
    return @truncate((addr >> 12) % FUTEX_HASH_BUCKETS);
}

/// v53.44: Remove a WaitNode from a bucket's wait list.
/// Used by wait paths to clean up nodes that were not granted (e.g. signaled
/// or timed out). Without this, the stack-allocated node remains in the
/// linked list after the function returns, causing use-after-free.
fn removeWaitNode(bucket: *FutexBucket, node: *task_mod.WaitNode) void {
    const irq_flags = bucket.lock.acquire();
    defer bucket.lock.release(irq_flags);
    var prev: ?*task_mod.WaitNode = null;
    var current = bucket.head;
    while (current) |n| {
        if (n == node) {
            if (prev) |p| {
                p.next = n.next;
            } else {
                bucket.head = n.next;
            }
            return;
        }
        prev = n;
        current = n.next;
    }
}

/// v53.51: Drive timed futex waits. Called from the BSP maintenance tick
/// (sched.zig, alongside the alarm/itimer deadline scans). Unlinks expired
/// waiters and republishes them; the woken waiter observes granted == false
/// with an expired deadline and returns -ETIMEDOUT.
pub fn timerTick(now_ns: u64) void {
    var bm = @atomicLoad(u64, &futex_wait_bm, .acquire);
    while (bm != 0) {
        const i: u6 = @truncate(@ctz(bm));
        bm &= bm - 1;
        const idx: u32 = i;
        const deadline = wait_deadlines[idx];
        if (deadline == 0 or now_ns < deadline) continue;
        const bucket = wait_buckets[idx] orelse {
            disarmWaitDeadline(idx);
            continue;
        };
        // Unlink the waiter under its bucket lock (races with wakeN, which
        // removes the node under the same lock — loser finds nothing).
        var unlinked = false;
        const irq_flags = bucket.lock.acquire();
        var prev: ?*task_mod.WaitNode = null;
        var current = bucket.head;
        while (current) |n| {
            if (n.task_idx == idx) {
                if (prev) |p| {
                    p.next = n.next;
                } else {
                    bucket.head = n.next;
                }
                unlinked = true;
                break;
            }
            prev = n;
            current = n.next;
        }
        bucket.lock.release(irq_flags);
        // Drop the deadline either way so a stale bit cannot fire on a later
        // untimed wait when the slot is reused.
        disarmWaitDeadline(idx);
        if (!unlinked) continue; // Already woken or cleaned up
        // Republish like wakeN: a bare .ready starves on busy CPUs.
        task_mod.unblockTask(idx);
        task_mod.kickRemoteForTask(idx);
    }
}

/// v53.44: Requeue waiters from source to dest bucket. Caller must hold locks.
/// If bucket == dst_bucket, nodes stay in place (just counted).
fn doRequeue(bucket: *FutexBucket, dst_bucket: *FutexBucket, requeue_count: u32) u64 {
    var requeued: u64 = 0;
    var prev: ?*task_mod.WaitNode = null;
    var current = bucket.head;
    while (current) |node| {
        if (requeued >= requeue_count) break;
        const next = node.next;
        const t = task_mod.getTask(node.task_idx) orelse {
            prev = node;
            current = next;
            continue;
        };
        // A scheduler resume/requeue transition may transiently expose a
        // still-linked waiter as blocked, running, or ready. The exact key and
        // live node are the ownership proof; only zombies are ineligible.
        if (t.state != .zombie) {
            if (bucket != dst_bucket) {
                // Remove from source bucket
                if (prev) |p| {
                    p.next = next;
                } else {
                    bucket.head = next;
                }
                // Insert into destination bucket
                node.next = dst_bucket.head;
                dst_bucket.head = node;
            } else {
                // Same bucket: leave node in place, update prev
                prev = node;
            }
            requeued += 1;
        } else {
            prev = node;
        }
        current = next;
    }
    return requeued;
}

/// Read a u32 from user space safely.
pub fn copyUserU32(addr: u64) error{Fault}!u32 {
    var buf: [4]u8 = @splat(0);
    const src: [*]const u8 = @ptrFromInt(addr);
    if (copy.copyFromUser(buf[0..], src, buf.len) != buf.len) return error.Fault;
    return bo.readU32Le(buf[0..]);
}

/// Read a u64 from user space safely.
pub fn copyUserU64Fallible(addr: u64) error{Fault}!u64 {
    var buf: [8]u8 = @splat(0);
    if (copy.copyFromUser(buf[0..], @ptrFromInt(addr), buf.len) != buf.len) return error.Fault;
    return bo.readU64At(&buf, 0);
}

/// Legacy process_vm compatibility wrapper. Futex paths use the fallible helpers.
pub fn copyUserU64(addr: u64) u64 {
    return copyUserU64Fallible(addr) catch 0;
}

/// Wake up to `count` waiters for one address-space-qualified futex key.
pub fn wakeN(bucket: *FutexBucket, key: futex_key.Key, count: u32) u64 {
    var woken: usize = 0;
    var woken_idx: [task_mod.MAX_TASKS]u32 = undefined;
    const irq_flags = bucket.lock.acquire();
    var prev: ?*task_mod.WaitNode = null;
    var current = bucket.head;
    while (current) |node| {
        if (woken >= count) break;
        const next = node.next;
        if (!futex_key.equal(.{ .root = node.futex_root, .addr = node.futex_addr }, key)) {
            prev = node;
            current = next;
            continue;
        }
        const t = task_mod.getTask(node.task_idx) orelse {
            prev = node;
            current = next;
            continue;
        };
        if (t.state != .zombie) {
            node.granted = true;
            woken_idx[woken] = node.task_idx;
            woken += 1;
            if (prev) |p| {
                p.next = next;
            } else {
                bucket.head = next;
            }
        } else {
            prev = node;
        }
        current = next;
    }
    bucket.lock.release(irq_flags);
    // v53.51: Republish woken tasks outside the bucket lock. A bare
    // `state = .ready` never re-enters a run queue and starves on busy CPUs
    // (pickNext drains the per-CPU queue before the bitmap fallback);
    // unblockTask re-enqueues, kickRemoteForTask IPIs the target CPU.
    for (woken_idx[0..woken]) |idx| {
        task_mod.unblockTask(idx);
        task_mod.kickRemoteForTask(idx);
    }
    return @intCast(woken);
}

// ── Vectored futex wait ──

/// futex_waitv(waiters_ptr, nr_waiters, flags, timeout, clockid) -> woken index or -errno.
/// Unsupported until vector entries carry address-space-qualified private keys.
pub fn futexWaitv(waiters_ptr: u64, nr_waiters: u64) i64 {
    _ = waiters_ptr;
    _ = nr_waiters;
    return -38; // -ENOSYS
}

// ── Core futex syscall ──

/// futex(addr, op, val, val2, uaddr2, val3) -> result or -errno.
/// Core logic for syscall #202.
/// v53.44: added val2 param for Linux ABI correctness (r10 = val2/timeout).
pub fn futex(addr: u64, raw_op: i64, val: u64, val2: u64, uaddr2: u64, val3: u64) i64 {
    _ = uaddr2;
    _ = val3;
    const decoded = futex_key.privateOp(raw_op) orelse return -22; // -EINVAL
    const op = decoded.base;

    if (addr == 0 or addr >= 0x0000_8000_0000_0000) {
        return -14; // -EFAULT
    }
    if (!futex_key.aligned(addr)) return -22; // -EINVAL
    if (futex_key.piUnsupported(op)) return -38; // -ENOSYS
    if (!decoded.private) return -38; // -ENOSYS: shared futex keys are unavailable
    switch (op) {
        FUTEX_WAIT, FUTEX_WAKE => {},
        else => return -38, // -ENOSYS: only private basic waits/wakes are implemented
    }

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur_task = task_mod.getTask(cur_idx) orelse return -1;
    const key = futex_key.Key{ .root = cur_task.page_table_phys, .addr = addr };

    const bucket_idx = hash(addr);
    const bucket = &buckets[bucket_idx];

    switch (op) {
        FUTEX_WAIT => {
            // v53.51: val2 = relative timespec* (Linux ABI, r10).
            const deadline = parseTimeout(val2, false) catch |err| switch (err) {
                error.Fault => return -14, // -EFAULT
                error.Invalid => return -22, // -EINVAL
            };
            var node: task_mod.WaitNode = .{ .task_idx = 0 };
            const irq_flags = bucket.lock.acquire();
            // v53.51: Check-and-enqueue atomically w.r.t. FUTEX_WAKE — the
            // canonical futex protocol. Reading *addr before taking the lock
            // left a lost-wakeup window between the check and the enqueue.
            const user_val = copyUserU32(addr) catch {
                bucket.lock.release(irq_flags);
                return -14; // -EFAULT
            };
            if (user_val != @as(u32, @truncate(val))) {
                bucket.lock.release(irq_flags);
                return -11; // -EAGAIN
            }
            node.task_idx = cur_idx;
            node.granted = false;
            node.futex_root = key.root;
            node.futex_addr = key.addr;
            node.next = bucket.head;
            bucket.head = &node;
            if (deadline != 0) armWaitDeadline(cur_idx, bucket, deadline);

            cur_task.state = .blocked;
            bucket.lock.release(irq_flags);

            while (true) {
                sched_mod.forceReschedule();
                const sig_mod = @import("../proc/signal.zig");
                const flags2 = bucket.lock.acquire();
                if (node.granted) {
                    bucket.lock.release(flags2);
                    if (deadline != 0) disarmWaitDeadline(cur_idx);
                    return 0;
                }
                const expired = deadline != 0 and tsc.nanos() >= deadline;
                const fatal = sig_mod.pendingFatal(cur_task);
                const actionable = sig_mod.pendingActionable(cur_task);
                if (!expired and fatal == null and !actionable) {
                    // A yield can resume the current task without a switch.
                    // A linked, ungranted futex node must remain blocked so an
                    // exact-key wake sees it as eligible rather than losing it.
                    cur_task.state = .blocked;
                    bucket.lock.release(flags2);
                    continue;
                }

                // Cancellation owns the node while holding bucket.lock, so a
                // concurrent wake cannot grant a node that is being unlinked.
                var prev: ?*task_mod.WaitNode = null;
                var current = bucket.head;
                while (current) |candidate| {
                    if (candidate == &node) {
                        if (prev) |p| p.next = candidate.next else bucket.head = candidate.next;
                        break;
                    }
                    prev = candidate;
                    current = candidate.next;
                }
                bucket.lock.release(flags2);
                if (deadline != 0) disarmWaitDeadline(cur_idx);
                if (expired) return -110; // -ETIMEDOUT
                if (fatal) |sig| task_mod.exitTask(128 + @as(i32, @intCast(sig)));
                if (actionable) return -4; // -EINTR
                return -11;
            }
        },
        FUTEX_WAKE => {
            const count: u32 = @truncate(val);
            return @intCast(wakeN(bucket, key, count));
        },
        FUTEX_LOCK_PI, FUTEX_UNLOCK_PI, FUTEX_TRYLOCK_PI,
        FUTEX_WAIT_REQUEUE_PI, FUTEX_CMP_REQUEUE_PI => return -38, // ENOSYS: PI semantics unavailable
        else => {
            return -38; // -ENOSYS
        },
    }
}
