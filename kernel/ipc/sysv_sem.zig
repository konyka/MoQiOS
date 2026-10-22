/// SysV Semaphores (semget/semop/semctl) implementation.
///
/// Provides basic counting semaphore support for process synchronization.
const std = @import("std");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const serial = @import("../arch/arch.zig").serial;
const fmt = @import("../lib/fmt.zig");
const task = @import("../proc/task.zig");
const sched = @import("../proc/sched.zig");
const errno = @import("../lib/errno.zig");
const sysv_policy = @import("sysv_policy.zig");

const MAX_SEM_SETS: u32 = 16;
const MAX_SEMS_PER_SET: u32 = 32;

/// Semaphore set descriptor
pub const SemSet = struct {
    active: bool = false,
    semid: u32 = 0,
    key: i32 = 0,
    nsems: u32 = 0,
    /// Semaphore values
    values: [MAX_SEMS_PER_SET]i32 = @splat(0),
    /// Owner TID
    owner_tid: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    cuid: u32 = 0,
    cgid: u32 = 0,
    /// Permissions
    mode: u32 = 0,
    /// Marked for removal
    marked_removed: bool = false,
    /// Wait queue for blocked semop waiters
    wait_queue: ?*task.WaitNode = null,
    waiter_count: u32 = 0,
};

var sem_sets: [MAX_SEM_SETS]SemSet = @splat(.{});
var next_semid: u32 = 1;
var sem_lock: IrqSpinlock = .{};

const IPC_CREAT: i32 = 0o1000;
const IPC_EXCL: i32 = 0o2000;
const IPC_RMID: i32 = 0;
const IPC_STAT: i32 = 2;
const IPC_SET: i32 = 1;
const IPC_PRIVATE: i32 = 0;
const SETVAL: i32 = 16;
const GETVAL: i32 = 12;
const SEMGET_FLAGS = IPC_CREAT | IPC_EXCL | 0o777;

fn credentials() sysv_policy.Credentials {
    if (sched.currentTaskIndex()) |idx| {
        if (task.getTask(idx)) |t| return .{ .euid = t.euid, .egid = t.egid, .cap_sys_admin = t.effective_caps.cap_sys_admin };
    }
    return .{ .euid = 0, .egid = 0, .cap_sys_admin = true };
}

fn owner(s: *const SemSet) sysv_policy.Owner {
    return .{ .uid = s.uid, .gid = s.gid, .cuid = s.cuid, .cgid = s.cgid };
}

fn canAccess(s: *const SemSet, read: bool, write: bool) bool {
    return sysv_policy.modeAllows(s.mode, owner(s), credentials(), read, write);
}

fn canManage(s: *const SemSet) bool {
    return sysv_policy.canManage(owner(s), credentials());
}

fn allocateSemId() ?u32 {
    var attempts: u32 = 0;
    while (attempts < std.math.maxInt(u32)) : (attempts += 1) {
        const candidate = next_semid;
        next_semid +%= 1;
        if (candidate == 0) continue;
        if (findSemSet(candidate) == null) return candidate;
    }
    return null;
}

/// semget(key, nsems, semflg) -> semid or -errno
pub fn semget(key: i32, nsems: i32, semflg: i32) i64 {
    if (!sysv_policy.flagsValid(semflg, SEMGET_FLAGS)) return errno.EINVAL;
    const flags = sem_lock.acquire();
    defer sem_lock.release(flags);

    if (nsems < 0 or nsems > MAX_SEMS_PER_SET) return errno.EINVAL;

    // Search for existing
    if (key != IPC_PRIVATE) {
        for (&sem_sets) |*s| {
            if (s.active and !s.marked_removed and s.key == key) {
                if (semflg & IPC_CREAT != 0 and semflg & IPC_EXCL != 0) {
                    return errno.EEXIST;
                }
                const requested = @as(u32, @intCast(semflg)) & 0o6;
                if (requested != 0 and !canAccess(s, (requested & 0o4) != 0, (requested & 0o2) != 0)) return errno.EACCES;
                return @intCast(s.semid);
            }
        }
    }

    if (semflg & IPC_CREAT == 0 and key != IPC_PRIVATE) {
        return errno.ENOENT;
    }
    if (nsems == 0) return errno.EINVAL;

    // Find free slot
    var slot: ?u32 = null;
    for (0..MAX_SEM_SETS) |i| {
        if (!sem_sets[i].active) {
            slot = @intCast(i);
            break;
        }
    }
    if (slot == null) return errno.ENOSPC;

    const idx = slot.?;
    const sid = allocateSemId() orelse return errno.ENOSPC;

    sem_sets[idx] = .{
        .active = true,
        .semid = sid,
        .key = key,
        .nsems = @intCast(nsems),
        .values = @splat(0),
        .mode = @intCast(semflg & 0o777),
        .owner_tid = if (sched.currentTaskIndex()) |tid| tid else 0,
        .uid = credentials().euid,
        .gid = credentials().egid,
        .cuid = credentials().euid,
        .cgid = credentials().egid,
    };

    serial.writeString("[sysv_sem] created semid=");
    fmt.writeDecimal(sid);
    serial.writeString(" nsems=");
    fmt.writeDecimal64(@intCast(nsems));
    serial.writeString("\n");

    return @intCast(sid);
}

/// semop(semid, sem_num, op) -> 0 or -errno
///
/// op < 0 blocks until the value can absorb it; op == 0 blocks until the
/// value is zero; op > 0 adds. Every successful change wakes ALL waiters of
/// the set: they wait on different semaphores and with different amounts, so
/// waking only the oldest could pick one that still cannot proceed and strand
/// another that now can. Each waiter re-checks its own condition and blocks
/// again if it still fails.
pub fn semop(semid: u32, sem_num: u32, op: i16) i64 {
    while (true) {
        const flags = sem_lock.acquire();

        const s = findSemSet(semid) orelse {
            sem_lock.release(flags);
            return errno.EINVAL;
        };
        if (sem_num >= s.nsems) {
            sem_lock.release(flags);
            return errno.EINVAL;
        }
        if (s.marked_removed) {
            sem_lock.release(flags);
            return errno.EIDRM;
        }
        if (!canAccess(s, false, true)) {
            sem_lock.release(flags);
            return errno.EACCES;
        }

        const val: i32 = @intCast(op);
        const new_val = std.math.add(i32, s.values[sem_num], val) catch {
            sem_lock.release(flags);
            return errno.ERANGE;
        };

        const must_wait = new_val < 0 or (op == 0 and s.values[sem_num] != 0);
        if (!must_wait) {
            if (op != 0) {
                s.values[sem_num] = new_val;
                // The value changed: a P-waiter may now fit, a wait-for-zero
                // waiter may now see zero.
                sched.wakeAll(&s.wait_queue);
            }
            sem_lock.release(flags);
            return 0;
        }

        // Join the wait queue while still holding the lock so a concurrent
        // change cannot slip between the check and the enqueue.
        const cur_idx = sched.currentTaskIndex() orelse {
            sem_lock.release(flags);
            return -1;
        };
        const cur_task = task.getTask(cur_idx) orelse {
            sem_lock.release(flags);
            return -1;
        };
        var node: task.WaitNode = .{ .task_idx = cur_idx };
        node.granted = false;
        node.next = s.wait_queue;
        s.wait_queue = &node;
        s.waiter_count += 1;
        cur_task.state = .blocked;
        sem_lock.release(flags);
        sched.forceReschedule();
        sched.repairCurrentAfterBlock(); // forceReschedule may return without switching

        const flags2 = sem_lock.acquire();
        // Our node lives on this stack: take it off the queue unless a waker
        // already detached the whole queue (wakeAll empties it).
        {
            var prev: ?*task.WaitNode = null;
            var cur_node = s.wait_queue;
            while (cur_node) |n| {
                if (n == &node) {
                    if (prev) |p| p.next = n.next else s.wait_queue = n.next;
                    break;
                }
                prev = n;
                cur_node = n.next;
            }
        }
        if (s.waiter_count > 0) s.waiter_count -= 1;
        const gone = !s.active or s.semid != semid;
        if (!gone and sysv_policy.removalCanFree(s.marked_removed, s.waiter_count)) {
            // Last waiter out of a removed set releases the slot.
            s.* = .{};
            sem_lock.release(flags2);
            return errno.EIDRM;
        }
        const removed = gone or s.marked_removed;
        sem_lock.release(flags2);
        if (removed) return errno.EIDRM;

        // Fatal / handled signals end the wait; a plain wake (grant, SIGCONT,
        // yield without a switch) just re-evaluates the condition.
        const sig_mod = @import("../proc/signal.zig");
        if (sig_mod.pendingFatal(cur_task)) |sig| task.exitTask(128 + @as(i32, @intCast(sig)));
        if (!node.granted and sig_mod.pendingActionable(cur_task)) return -4; // -EINTR
    }
}

/// semctl(semid, semnum, cmd, arg) -> value or -errno
pub fn semctl(semid: u32, semnum: i32, cmd: i32, arg: i32) i64 {
    const flags = sem_lock.acquire();
    defer sem_lock.release(flags);

    const s = findSemSet(semid) orelse return errno.EINVAL;

    switch (cmd) {
        IPC_RMID => {
            if (!canManage(s)) return errno.EPERM;
            s.marked_removed = true;
            serial.writeString("[sysv_sem] removed semid=");
            fmt.writeDecimal(semid);
            serial.writeString("\n");
            // Wake all blocked waiters WITHOUT setting granted, so semop
            // takes its interrupted path and returns -EIDRM. wakeAll() would
            // set granted=true and the waiters would report -EINVAL instead.
            var node = s.wait_queue;
            while (node) |n| {
                task.unblockTask(n.task_idx);
                node = n.next;
            }
            s.wait_queue = null;
            if (s.waiter_count == 0 and s.wait_queue == null) s.* = .{};
            return 0;
        },
        IPC_STAT => {
            if (!canAccess(s, true, false)) return errno.EACCES;
            return @intCast(s.nsems);
        },
        IPC_SET => {
            if (!canManage(s)) return errno.EPERM;
            // Update permission mode bits from arg (lower 9 bits: rwxrwxrwx)
            s.mode = @intCast(arg & 0o777);
            return 0;
        },
        SETVAL => {
            if (!canAccess(s, false, true)) return errno.EACCES;
            if (semnum < 0 or @as(u32, @intCast(semnum)) >= s.nsems) return errno.EINVAL;
            // semval is non-negative by definition (Linux rejects SETVAL<0);
            // a negative value wedges every future P/V into permanent
            // blocking.
            if (arg < 0) return errno.EINVAL;
            s.values[@intCast(semnum)] = arg;
            // Any change may let a P-waiter (or a wait-for-zero waiter) proceed.
            sched.wakeAll(&s.wait_queue);
            return 0;
        },
        GETVAL => {
            if (!canAccess(s, true, false)) return errno.EACCES;
            if (semnum < 0 or @as(u32, @intCast(semnum)) >= s.nsems) return errno.EINVAL;
            return @intCast(s.values[@intCast(semnum)]);
        },
        else => return errno.EINVAL,
    }
}

// ── Internal helpers ──

fn findSemSet(semid: u32) ?*SemSet {
    for (&sem_sets) |*s| {
        if (s.active and s.semid == semid) return s;
    }
    return null;
}
