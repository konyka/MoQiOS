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

/// semop(semid, sops, nsops) -> 0 or -errno
/// Supports blocking: P operations (op < 0) sleep until the semaphore
/// value allows the operation. V operations (op > 0) wake blocked waiters.
pub fn semop(semid: u32, sem_num: u32, op: i16) i64 {
    const MAX_RETRIES: u32 = 64; // prevent infinite loops on race
    var retries: u32 = 0;

    while (retries < MAX_RETRIES) : (retries += 1) {
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
            return errno.EINVAL;
        };

        if (new_val < 0) {
            // v53.44: Add to wait queue while holding lock to prevent lost wakeup.
            // Previously: released lock first, then called sleepOn — V operation
            // could fire wakeOne before we joined the queue, losing the wakeup.
            var node: task.WaitNode = .{ .task_idx = 0 };
            const cur_idx = sched.currentTaskIndex() orelse {
                sem_lock.release(flags);
                return -1;
            };
            node.task_idx = cur_idx;
            node.granted = false;
            node.next = s.wait_queue;
            s.wait_queue = &node;
            s.waiter_count += 1;
            const cur_task = task.getTask(cur_idx) orelse {
                sem_lock.release(flags);
                return -1;
            };
            cur_task.state = .blocked;
            sem_lock.release(flags);
            sched.forceReschedule();
            sched.repairCurrentAfterBlock(); // 阻塞后状态修复（yield 未切换情形）
            if (!node.granted) {
                // Interrupted (EIDRM / signal) before being granted — unlink
                // our stack WaitNode from the queue first, otherwise a later
                // V-op wakeOne would dereference freed stack memory.
                const flags2 = sem_lock.acquire();
                var prev: ?*task.WaitNode = null;
                var cur_node = s.wait_queue;
                while (cur_node) |n| {
                    if (n == &node) {
                        if (prev) |p| {
                            p.next = n.next;
                        } else {
                            s.wait_queue = n.next;
                        }
                        break;
                    }
                    prev = n;
                    cur_node = n.next;
                }
                if (s.waiter_count == 0) {
                    sem_lock.release(flags2);
                    return errno.EIDRM;
                }
                s.waiter_count -= 1;
                const removed_after_detach = sysv_policy.removalCanFree(s.marked_removed, s.waiter_count);
                if (removed_after_detach) s.* = .{};
                sem_lock.release(flags2);
                // Signal kick (sendSignal unblocks without granting): die on
                // a fatal signal via the same exit-by-signal path the timer
                // tick uses, or report EINTR so the handler can run on return.
                const sig_mod = @import("../proc/signal.zig");
                if (sig_mod.pendingFatal(cur_task)) |sig| task.exitTask(128 + @as(i32, @intCast(sig)));
                if (sig_mod.pendingActionable(cur_task)) return -4; // -EINTR
                return errno.EIDRM; // interrupted (EIDRM / signal)
            }
            const flags2 = sem_lock.acquire();
            if (s.waiter_count == 0) {
                sem_lock.release(flags2);
                return errno.EIDRM;
            }
            s.waiter_count -= 1;
            const removed_after_wake = sysv_policy.removalCanFree(s.marked_removed, s.waiter_count);
            sem_lock.release(flags2);
            if (removed_after_wake) return errno.EIDRM;
            continue; // re-acquire lock and re-check condition
        }

        // Operation can proceed
        s.values[sem_num] = new_val;

        // If this is a V operation (releasing), wake one blocked waiter
        if (op > 0) {
            _ = sched.wakeOne(&s.wait_queue);
        }

        sem_lock.release(flags);
        return 0;
    }

    return errno.EAGAIN; // too many retries (shouldn't happen normally)
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
            s.values[@intCast(semnum)] = arg;
            // Mirror the V-op wake: raising the value may let a blocked
            // P-waiter's operation succeed — wake one so it re-checks.
            if (arg > 0) _ = sched.wakeOne(&s.wait_queue);
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
