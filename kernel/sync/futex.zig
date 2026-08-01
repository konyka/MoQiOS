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
        if (t.state == .blocked) {
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

/// Wake up to `count` waiters from a futex bucket.
pub fn wakeN(bucket: *FutexBucket, count: u32) u64 {
    var woken: usize = 0;
    var woken_idx: [task_mod.MAX_TASKS]u32 = undefined;
    const irq_flags = bucket.lock.acquire();
    var prev: ?*task_mod.WaitNode = null;
    var current = bucket.head;
    while (current) |node| {
        if (woken >= count) break;
        const next = node.next;
        const t = task_mod.getTask(node.task_idx) orelse {
            prev = node;
            current = next;
            continue;
        };
        if (t.state == .blocked) {
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
/// Vectored futex wait. Simplified: iterate and wait on first matching futex.
pub fn futexWaitv(waiters_ptr: u64, nr_waiters: u64) i64 {
    if (nr_waiters == 0) return -22; // -EINVAL
    const max_waiters = 16;
    if (nr_waiters > max_waiters) return -22; // -EINVAL

    // struct futex_waitv { val: u64, uaddr: u64, flags: u32, __reserved: u32 }
    const waiter_size = 24;
    const waiters_len = std.math.mul(u64, nr_waiters, waiter_size) catch return -14; // -EFAULT
    if (!copy.validateUserBuffer(waiters_ptr, @intCast(waiters_len))) return -14; // -EFAULT

    var waiters: [max_waiters][waiter_size]u8 = undefined;
    var i: u64 = 0;
    while (i < nr_waiters) : (i += 1) {
        const off = i * waiter_size;
        const waiter_ptr = std.math.add(u64, waiters_ptr, off) catch return -14; // -EFAULT
        const waiter = &waiters[@intCast(i)];
        if (copy.copyFromUser(waiter[0..], @ptrFromInt(waiter_ptr), waiter.len) != waiter.len) {
            return -14; // -EFAULT
        }
    }

    i = 0;
    while (i < nr_waiters) : (i += 1) {
        const waiter = &waiters[@intCast(i)];
        const expected_val = bo.readU64At(waiter, 0);
        const uaddr = bo.readU64At(waiter, 8);

        if (uaddr == 0 or uaddr >= 0x0000_8000_0000_0000) return -14; // -EFAULT

        const bucket_idx = hash(uaddr);
        const bucket = &buckets[bucket_idx];

        var node: task_mod.WaitNode = .{ .task_idx = 0 };
        const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
        const irq_flags = bucket.lock.acquire();
        // v53.51: Check-and-enqueue under bucket.lock — validating *uaddr
        // before taking the lock left a window where FUTEX_WAKE could fire
        // between the check and the enqueue (lost wakeup).
        const cur_u32 = copyUserU32(uaddr) catch {
            bucket.lock.release(irq_flags);
            return -14; // -EFAULT
        };
        if (@as(u64, cur_u32) != expected_val) {
            bucket.lock.release(irq_flags);
            continue; // Value mismatch — try the next waiter
        }
        node.task_idx = cur_idx;
        node.granted = false;
        node.next = bucket.head;
        bucket.head = &node;

        const cur = task_mod.getTask(cur_idx) orelse {
            bucket.lock.release(irq_flags);
            return -1;
        };
        cur.state = .blocked;
        bucket.lock.release(irq_flags);

        sched_mod.forceReschedule();

        // v53.44: Clean up node if not granted (prevents UAF)
        if (!node.granted) {
            removeWaitNode(bucket, &node);
            return -11;
        }
        return @bitCast(i);
    }

    return -11; // -EAGAIN
}

// ── Core futex syscall ──

/// futex(addr, op, val, val2, uaddr2, val3) -> result or -errno.
/// Core logic for syscall #202.
/// v53.44: added val2 param for Linux ABI correctness (r10 = val2/timeout).
pub fn futex(addr: u64, raw_op: i64, val: u64, val2: u64, uaddr2: u64, val3: u64) i64 {
    const op: i64 = raw_op & ~FUTEX_PRIVATE; // strip private flag

    if (addr == 0 or addr >= 0x0000_8000_0000_0000) {
        return -14; // -EFAULT
    }

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
            const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
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
            node.next = bucket.head;
            bucket.head = &node;
            if (deadline != 0) armWaitDeadline(cur_idx, bucket, deadline);

            const cur = task_mod.getTask(cur_idx) orelse {
                bucket.lock.release(irq_flags);
                return -1;
            };
            cur.state = .blocked;
            bucket.lock.release(irq_flags);

            sched_mod.forceReschedule();

            if (deadline != 0) disarmWaitDeadline(cur_idx);
            // v53.44: Clean up node if not granted (prevents UAF)
            if (!node.granted) {
                removeWaitNode(bucket, &node);
                if (deadline != 0 and tsc.nanos() >= deadline) {
                    return -110; // -ETIMEDOUT
                }
                return -11;
            }
            return 0;
        },
        FUTEX_WAKE => {
            const count: u32 = @truncate(val);
            return @intCast(wakeN(bucket, count));
        },
        FUTEX_WAIT_BITSET => {
            // Same as FUTEX_WAIT (ignore bitset for now), but val2 is an
            // absolute timespec* per the Linux ABI.
            const deadline = parseTimeout(val2, true) catch |err| switch (err) {
                error.Fault => return -14, // -EFAULT
                error.Invalid => return -22, // -EINVAL
            };
            var node: task_mod.WaitNode = .{ .task_idx = 0 };
            const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
            const irq_flags = bucket.lock.acquire();
            // v53.51: Check-and-enqueue under bucket.lock (lost-wakeup fix,
            // see FUTEX_WAIT).
            const user_val = copyUserU32(addr) catch {
                bucket.lock.release(irq_flags);
                return -14; // -EFAULT
            };
            if (user_val != @as(u32, @truncate(val))) {
                bucket.lock.release(irq_flags);
                return -11;
            }
            node.task_idx = cur_idx;
            node.granted = false;
            node.next = bucket.head;
            bucket.head = &node;
            if (deadline != 0) armWaitDeadline(cur_idx, bucket, deadline);

            const cur = task_mod.getTask(cur_idx) orelse {
                bucket.lock.release(irq_flags);
                return -1;
            };
            cur.state = .blocked;
            bucket.lock.release(irq_flags);
            sched_mod.forceReschedule();
            if (deadline != 0) disarmWaitDeadline(cur_idx);
            // v53.44: Clean up node if not granted (prevents UAF)
            if (!node.granted) {
                removeWaitNode(bucket, &node);
                if (deadline != 0 and tsc.nanos() >= deadline) {
                    return -110; // -ETIMEDOUT
                }
                return -11;
            }
            return 0;
        },
        FUTEX_WAKE_BITSET => {
            const count: u32 = @truncate(val);
            return @intCast(wakeN(bucket, count));
        },
        FUTEX_REQUEUE => {
            const wake_count: u32 = @truncate(val);
            const requeue_count: u32 = @truncate(val2); // v53.44: val2 not val3
            const woken = wakeN(bucket, wake_count);
            var requeued: u64 = 0;
            if (requeue_count > 0 and uaddr2 != 0 and uaddr2 < 0x0000_8000_0000_0000) {
                const dst_bucket = &buckets[hash(uaddr2)];
                // v53.44: Same-bucket check prevents double-acquire deadlock
                if (bucket == dst_bucket) {
                    const f1 = bucket.lock.acquire();
                    requeued = doRequeue(bucket, dst_bucket, requeue_count);
                    bucket.lock.release(f1);
                } else {
                    const src_first = @intFromPtr(bucket) <= @intFromPtr(dst_bucket);
                    const b1 = if (src_first) bucket else dst_bucket;
                    const b2 = if (src_first) dst_bucket else bucket;
                    const f1 = b1.lock.acquire();
                    const f2 = b2.lock.acquire();
                    requeued = doRequeue(bucket, dst_bucket, requeue_count);
                    b2.lock.release(f2);
                    b1.lock.release(f1);
                }
            }
            return @intCast(woken + requeued);
        },
        FUTEX_CMP_REQUEUE => {
            const cmp_val: u32 = @truncate(val3);
            // v53.44: Check *addr (not *uaddr2) per Linux CMP_REQUEUE semantics
            const user_val = copyUserU32(addr) catch return -14; // -EFAULT
            if (user_val != cmp_val) {
                return -11; // EAGAIN
            }
            const wake_count: u32 = @truncate(val);
            const requeue_count: u32 = @truncate(val2); // v53.44: val2 not val3>>32
            const woken = wakeN(bucket, wake_count);
            var requeued: u64 = 0;
            if (requeue_count > 0 and uaddr2 != 0 and uaddr2 < 0x0000_8000_0000_0000) {
                const dst_bucket = &buckets[hash(uaddr2)];
                // v53.44: Same-bucket check prevents double-acquire deadlock
                if (bucket == dst_bucket) {
                    const f1 = bucket.lock.acquire();
                    requeued = doRequeue(bucket, dst_bucket, requeue_count);
                    bucket.lock.release(f1);
                } else {
                    const src_first = @intFromPtr(bucket) <= @intFromPtr(dst_bucket);
                    const b1 = if (src_first) bucket else dst_bucket;
                    const b2 = if (src_first) dst_bucket else bucket;
                    const f1 = b1.lock.acquire();
                    const f2 = b2.lock.acquire();
                    requeued = doRequeue(bucket, dst_bucket, requeue_count);
                    b2.lock.release(f2);
                    b1.lock.release(f1);
                }
            }
            return @intCast(woken + requeued);
        },
        FUTEX_WAKE_OP => {
            const wake_count1: u32 = @truncate(val);
            const wake_count2: u32 = @truncate(val2); // v53.44: val2 not val3>>32
            const woken1 = wakeN(bucket, wake_count1);
            var woken2: u64 = 0;
            if (uaddr2 != 0 and uaddr2 < 0x0000_8000_0000_0000 and wake_count2 > 0) {
                const bucket2 = &buckets[hash(uaddr2)];
                woken2 = wakeN(bucket2, wake_count2);
            }
            return @intCast(woken1 + woken2);
        },
        FUTEX_LOCK_PI => {
            // Simplified PI lock: claim (*addr: 0 → tid), block on contention.
            const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
            const cur_task = task_mod.getTask(cur_idx) orelse return -1;
            const tid: u32 = cur_task.tid;

            while (true) {
                var node: task_mod.WaitNode = .{ .task_idx = 0 };
                // v53.51: Serialize check-and-set under bucket.lock — the old
                // copyFromUser-check-copyToUser "CAS" let two threads on two
                // CPUs both read 0 and both return success (two owners).
                const irq_flags = bucket.lock.acquire();
                var word_buf: [4]u8 = undefined;
                if (copy.copyFromUser(&word_buf, @ptrFromInt(addr), 4) != 4) {
                    bucket.lock.release(irq_flags);
                    return -14;
                }
                const cur_val: u32 = bo.readU32Le(&word_buf);
                if (cur_val == 0 or cur_val == tid) {
                    // Lock available (or already ours) — claim it under the lock.
                    var new_buf: [4]u8 = undefined;
                    bo.writeU32Le(&new_buf, tid);
                    const ok = copy.copyToUser(@ptrFromInt(addr), &new_buf, 4) == 4;
                    bucket.lock.release(irq_flags);
                    return if (ok) 0 else -14;
                }

                // Lock held — block on futex wait queue (still under the lock,
                // so FUTEX_UNLOCK_PI's wake cannot be lost).
                node.task_idx = cur_idx;
                node.granted = false;
                node.next = bucket.head;
                bucket.head = &node;
                cur_task.state = .blocked;
                bucket.lock.release(irq_flags);

                sched_mod.forceReschedule();

                // v53.44: Clean up node if not granted (prevents UAF)
                if (!node.granted) {
                    removeWaitNode(bucket, &node);
                    return -11;
                }
                // v53.51: Woken — loop back and re-contend instead of
                // returning success unconditionally: another thread may have
                // grabbed the word first, in which case we re-block.
            }
        },
        FUTEX_UNLOCK_PI => {
            // Set futex word to 0, wake one waiter
            var new_buf: [4]u8 = undefined;
            bo.writeU32Le(&new_buf, 0);
            if (copy.copyToUser(@ptrFromInt(addr), &new_buf, 4) != 4) return -14;
            const woken = wakeN(bucket, 1);
            return @intCast(woken);
        },
        FUTEX_TRYLOCK_PI => {
            // Non-blocking: try claim (*addr: 0 → tid), serialized like LOCK_PI.
            const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
            const cur_task = task_mod.getTask(cur_idx) orelse return -1;

            const irq_flags = bucket.lock.acquire();
            var word_buf: [4]u8 = undefined;
            if (copy.copyFromUser(&word_buf, @ptrFromInt(addr), 4) != 4) {
                bucket.lock.release(irq_flags);
                return -14;
            }
            const cur_val: u32 = bo.readU32Le(&word_buf);
            if (cur_val == 0 or cur_val == cur_task.tid) {
                var new_buf: [4]u8 = undefined;
                bo.writeU32Le(&new_buf, cur_task.tid);
                const ok = copy.copyToUser(@ptrFromInt(addr), &new_buf, 4) == 4;
                bucket.lock.release(irq_flags);
                return if (ok) 0 else -14;
            }
            bucket.lock.release(irq_flags);
            return -11; // -EAGAIN: lock held
        },
        FUTEX_WAIT_REQUEUE_PI, FUTEX_CMP_REQUEUE_PI => {
            // Complex PI requeue — not commonly used, return success as no-op
            return 0;
        },
        else => {
            return -38; // -ENOSYS
        },
    }
}
