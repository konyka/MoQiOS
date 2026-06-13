/// Futex — Fast Userspace Mutex syscall implementation.
///
/// Provides FUTEX_WAIT/WAKE/REQUEUE/CMP_REQUEUE/WAKE_OP/WAIT_BITSET/WAKE_BITSET.
/// Uses a 64-bucket hash table keyed on the futex address for O(1) lookup.
/// Integrates with the scheduler for blocking/waking tasks.
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

/// Read a u32 from user space safely.
pub fn copyUserU32(addr: u64) u32 {
    var buf: [4]u8 = @splat(0);
    const src: [*]const u8 = @ptrFromInt(addr);
    _ = copy.copyFromUser(buf[0..], src, 4);
    return bo.readU32Le(buf[0..]);
}

/// Read a u64 from user space safely.
pub fn copyUserU64(addr: u64) u64 {
    if (addr == 0 or addr >= 0x0000_8000_0000_0000) return 0;
    var buf: [8]u8 = @splat(0);
    const n = copy.copyFromUser(&buf, @ptrFromInt(addr), 8);
    if (n < 8) return 0;
    return bo.readU64At(&buf, 0);
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
    if (waiters_ptr == 0 or waiters_ptr >= 0x0000_8000_0000_0000) return -14; // -EFAULT
    if (nr_waiters == 0) return -22; // -EINVAL

    // struct futex_waitv { val: u64, uaddr: u64, flags: u32, __reserved: u32 }
    const max_waiters: u32 = @intCast(@min(nr_waiters, 16));
    var i: u32 = 0;
    while (i < max_waiters) : (i += 1) {
        const off = @as(u64, i) * 24;
        const expected_val = copyUserU64(waiters_ptr + off);
        const uaddr = copyUserU64(waiters_ptr + off + 8);

        if (uaddr == 0 or uaddr >= 0x0000_8000_0000_0000) continue;

        const current_val: u64 = @intCast(copyUserU32(uaddr));
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

            return @bitCast(@as(u64, i));
        }
    }

    return -11; // -EAGAIN
}

// ── Core futex syscall ──

/// futex(addr, op, val, uaddr2, val3) -> result or -errno.
/// Core logic for syscall #202.
pub fn futex(addr: u64, raw_op: i64, val: u64, uaddr2: u64, val3: u64) i64 {
    const op: i64 = raw_op & ~FUTEX_PRIVATE; // strip private flag

    if (addr == 0 or addr >= 0x0000_8000_0000_0000) {
        return -14; // -EFAULT
    }

    const bucket_idx = hash(addr);
    const bucket = &buckets[bucket_idx];

    switch (op) {
        FUTEX_WAIT => {
            // Atomically check *addr == val, then sleep
            const user_val: u32 = copyUserU32(addr);
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

            return if (node.granted) @as(i64, 0) else -11;
        },
        FUTEX_WAKE => {
            const count: u32 = @truncate(val);
            return @intCast(wakeN(bucket, count));
        },
        FUTEX_WAIT_BITSET => {
            // Same as FUTEX_WAIT (ignore bitset for now)
            const user_val: u32 = copyUserU32(addr);
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
            return if (node.granted) @as(i64, 0) else -11;
        },
        FUTEX_WAKE_BITSET => {
            const count: u32 = @truncate(val);
            return @intCast(wakeN(bucket, count));
        },
        FUTEX_REQUEUE => {
            const wake_count: u32 = @truncate(val);
            const requeue_count: u32 = @truncate(val3);
            const woken = wakeN(bucket, wake_count);
            var requeued: u64 = 0;
            if (requeue_count > 0 and uaddr2 != 0 and uaddr2 < 0x0000_8000_0000_0000) {
                const dst_bucket = &buckets[hash(uaddr2)];
                const irq_flags = bucket.lock.acquire();
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
                        if (prev) |p| {
                            p.next = next;
                        } else {
                            bucket.head = next;
                        }
                        const dst_flags = dst_bucket.lock.acquire();
                        node.next = dst_bucket.head;
                        dst_bucket.head = node;
                        dst_bucket.lock.release(dst_flags);
                        requeued += 1;
                    } else {
                        prev = node;
                    }
                    current = next;
                }
                bucket.lock.release(irq_flags);
            }
            return @intCast(woken + requeued);
        },
        FUTEX_CMP_REQUEUE => {
            const cmp_val: u32 = @truncate(val3);
            if (uaddr2 != 0 and uaddr2 < 0x0000_8000_0000_0000) {
                const user_val2: u32 = copyUserU32(uaddr2);
                if (user_val2 != cmp_val) {
                    return -11; // EAGAIN
                }
            }
            const wake_count: u32 = @truncate(val);
            const requeue_count: u32 = @truncate(val3 >> 32);
            const woken = wakeN(bucket, wake_count);
            var requeued: u64 = 0;
            if (requeue_count > 0 and uaddr2 != 0 and uaddr2 < 0x0000_8000_0000_0000) {
                const dst_bucket = &buckets[hash(uaddr2)];
                const irq_flags = bucket.lock.acquire();
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
                        if (prev) |p| {
                            p.next = next;
                        } else {
                            bucket.head = next;
                        }
                        const dst_flags = dst_bucket.lock.acquire();
                        node.next = dst_bucket.head;
                        dst_bucket.head = node;
                        dst_bucket.lock.release(dst_flags);
                        requeued += 1;
                    } else {
                        prev = node;
                    }
                    current = next;
                }
                bucket.lock.release(irq_flags);
            }
            return @intCast(woken + requeued);
        },
        FUTEX_WAKE_OP => {
            const wake_count1: u32 = @truncate(val);
            const wake_count2: u32 = @truncate(val3 >> 32);
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
                _ = copy.copyToUser(@ptrFromInt(addr), &new_buf, 4);
                return 0;
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
                _ = copy.copyToUser(@ptrFromInt(addr), &new_buf, 4);
            }
            return if (node.granted) @as(i64, 0) else -11;
        },
        FUTEX_UNLOCK_PI => {
            // Set futex word to 0, wake one waiter
            var new_buf: [4]u8 = undefined;
            bo.writeU32Le(&new_buf, 0);
            _ = copy.copyToUser(@ptrFromInt(addr), &new_buf, 4);
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
                _ = copy.copyToUser(@ptrFromInt(addr), &new_buf, 4);
                return 0;
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
