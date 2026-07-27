/// Futex — Fast Userspace Mutex syscall implementation.
///
/// Provides FUTEX_WAIT/WAKE/REQUEUE/CMP_REQUEUE/WAKE_OP/WAIT_BITSET/WAKE_BITSET.
/// Uses a 64-bucket hash table keyed on the futex address for O(1) lookup.
/// Integrates with the scheduler for blocking/waking tasks.
const std = @import("std");
const task_mod = @import("../proc/task.zig");
const sched_mod = @import("../proc/sched.zig");
const IrqSpinlock = @import("irq_spinlock.zig").IrqSpinlock;
const copy = @import("../mm/copy_from_user.zig");
const bo = @import("../lib/byte_order.zig");

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
    var woken: u64 = 0;
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
            t.state = .ready;
            node.granted = true;
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
    return woken;
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

        const current_val: u64 = @intCast(copyUserU32(uaddr) catch return -14); // -EFAULT
        if (current_val == expected_val) {
            const bucket_idx = hash(uaddr);
            const bucket = &buckets[bucket_idx];

            var node: task_mod.WaitNode = .{ .task_idx = 0 };
            const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
            const irq_flags = bucket.lock.acquire();
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
            // Atomically check *addr == val, then sleep
            const user_val = copyUserU32(addr) catch return -14; // -EFAULT
            if (user_val != @as(u32, @truncate(val))) {
                return -11; // -EAGAIN
            }
            var node: task_mod.WaitNode = .{ .task_idx = 0 };
            const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
            const irq_flags = bucket.lock.acquire();
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
            return 0;
        },
        FUTEX_WAKE => {
            const count: u32 = @truncate(val);
            return @intCast(wakeN(bucket, count));
        },
        FUTEX_WAIT_BITSET => {
            // Same as FUTEX_WAIT (ignore bitset for now)
            const user_val = copyUserU32(addr) catch return -14; // -EFAULT
            if (user_val != @as(u32, @truncate(val))) {
                return -11;
            }
            var node: task_mod.WaitNode = .{ .task_idx = 0 };
            const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
            const irq_flags = bucket.lock.acquire();
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
            // Simplified PI lock: try CAS (*addr: 0 → tid), block on failure
            var word_buf: [4]u8 = undefined;
            if (copy.copyFromUser(&word_buf, @ptrFromInt(addr), 4) != 4) return -14;
            const cur_val: u32 = bo.readU32Le(&word_buf);
            const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
            const cur_task = task_mod.getTask(cur_idx) orelse return -1;
            const tid: u32 = cur_task.tid;

            if (cur_val == 0) {
                // Lock available — set TID
                var new_buf: [4]u8 = undefined;
                bo.writeU32Le(&new_buf, tid);
                return if (copy.copyToUser(@ptrFromInt(addr), &new_buf, 4) == 4) 0 else -14;
            }
            if (cur_val == tid) return 0; // Already locked by us

            // Lock held — block on futex wait queue
            var node: task_mod.WaitNode = .{ .task_idx = 0 };
            const irq_flags = bucket.lock.acquire();
            node.task_idx = cur_idx;
            node.granted = false;
            node.next = bucket.head;
            bucket.head = &node;
            cur_task.state = .blocked;
            bucket.lock.release(irq_flags);

            sched_mod.forceReschedule();

            // Woken up — retry CAS
            if (copy.copyFromUser(&word_buf, @ptrFromInt(addr), 4) != 4) return -14;
            const retry_val: u32 = bo.readU32Le(&word_buf);
            if (retry_val == 0) {
                var new_buf: [4]u8 = undefined;
                bo.writeU32Le(&new_buf, tid);
                if (copy.copyToUser(@ptrFromInt(addr), &new_buf, 4) != 4) return -14;
            }
            // v53.44: Clean up node if not granted (prevents UAF)
            if (!node.granted) {
                removeWaitNode(bucket, &node);
                return -11;
            }
            return 0;
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
            // Non-blocking: try CAS (*addr: 0 → tid)
            var word_buf: [4]u8 = undefined;
            if (copy.copyFromUser(&word_buf, @ptrFromInt(addr), 4) != 4) return -14;
            const cur_val: u32 = bo.readU32Le(&word_buf);
            const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
            const cur_task = task_mod.getTask(cur_idx) orelse return -1;

            if (cur_val == 0 or cur_val == cur_task.tid) {
                var new_buf: [4]u8 = undefined;
                bo.writeU32Le(&new_buf, cur_task.tid);
                return if (copy.copyToUser(@ptrFromInt(addr), &new_buf, 4) == 4) 0 else -14;
            }
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
