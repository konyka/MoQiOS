/// File locking — flock() and fcntl() byte-range locks.
///
/// Implementation:
///   - Static table of 64 active locks
///   - A blocked flock/F_SETLKW parks the task (sleep_bm) and is woken when a
///     conflicting lock is released, or by the scheduler tick within 10 ms
///   - inode_id identifies the underlying file across different fds
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const vfs = @import("vfs.zig");
const task_mod = @import("../proc/task.zig");
const bo = @import("../lib/byte_order.zig");

// flock() operation bits
pub const LOCK_SH = 1; // shared lock
pub const LOCK_EX = 2; // exclusive lock
pub const LOCK_NB = 4; // non-blocking
pub const LOCK_UN = 8; // unlock

// fcntl lock types
pub const F_RDLCK = 0;
pub const F_WRLCK = 1;
pub const F_UNLCK = 2;

const FileLock = struct {
    active: bool,
    inode: u64, // file identifier
    lock_type: u8, // LOCK_SH or LOCK_EX
    owner_pid: u16,
    start: u64,
    len: u64,
};

var locks: [64]FileLock = undefined;
var lock_count: u32 = 0;
var fl_lock: IrqSpinlock = .{};
/// Tasks parked in a blocking flock/F_SETLKW, by task index. Releasing a lock
/// unblocks them; the scheduler tick does too, so a missed wake still ends.
var lock_waiter_bm: u64 = 0;

/// How long a blocked lock sleeps before it looks again: one scheduler tick.
const LOCK_POLL_NS: u64 = 10_000_000;

/// The file a lock is keyed by: the same identity O_APPEND uses, so two opens
/// of one file share a key and two files never do. tmpfs descriptors carry no
/// inode_id (every one would be 0), and every new empty FAT32 file has first
/// cluster 0, so neither can be told apart by inode_id. Null for a descriptor
/// that cannot be locked.
pub fn lockKey(desc: *const vfs.FileDescriptor) ?u64 {
    if (desc.fd_type == .none) return null;
    return switch (desc.fd_type) {
        .tmpfs_file => 0x1000_0000_0000_0000 + @as(u64, desc.tmpfs_idx),
        .fat32_file => 0x2000_0000_0000_0000 + @as(u64, @import("fat32.zig").getFirstCluster(desc.fat32_file_idx)),
        else => if (desc.inode_id == 0) null else desc.inode_id,
    };
}

fn getInodeForFd(fd_table: *vfs.FdTable, fd: u32) ?u64 {
    if (fd >= vfs.MAX_FDS) return null;
    return lockKey(&fd_table.fds[fd]);
}

/// The process a lock belongs to: flock and fcntl locks are per process, so
/// every thread of one process shares them (getpid()'s id).
fn lockOwner(t: *task_mod.Task) u16 {
    const pid: u32 = if (t.is_thread and t.parent_tid != 0) t.parent_tid else t.tid;
    return @truncate(pid);
}

/// Park until a conflicting lock is released, or a signal arrives. A bare
/// yield does not sleep: the task stays .running and a CPU with nothing else
/// to run takes no timer interrupt for the whole wait.
fn sleepForLock(t: *task_mod.Task, cur_idx: u32) void {
    const sched_mod = @import("../proc/sched.zig");
    const tsc = @import("../arch/arch.zig").tsc;
    const bit = @as(u64, 1) << @intCast(cur_idx);
    @atomicStore(u64, &t.sleep_deadline_ns, tsc.nanos() +| LOCK_POLL_NS, .release);
    _ = @atomicRmw(u64, &sched_mod.sleep_bm, .Or, bit, .seq_cst);
    _ = @atomicRmw(u64, &lock_waiter_bm, .Or, bit, .seq_cst);
    task_mod.blockTask(cur_idx);
    const sig_mod = @import("../proc/signal.zig");
    if (sig_mod.pendingFatal(t) != null or sig_mod.pendingActionable(t)) task_mod.unblockTask(cur_idx);
    sched_mod.forceReschedule();
    sched_mod.repairCurrentAfterBlock();
    t.sleep_deadline_ns = 0;
    _ = @atomicRmw(u64, &sched_mod.sleep_bm, .And, ~bit, .seq_cst);
    _ = @atomicRmw(u64, &lock_waiter_bm, .And, ~bit, .seq_cst);
}

/// Wake every task parked in a blocking lock. Called after a lock is released.
fn wakeLockWaiters() void {
    var bm = @atomicLoad(u64, &lock_waiter_bm, .acquire);
    while (bm != 0) {
        const i: u6 = @intCast(@ctz(bm));
        bm &= ~(@as(u64, 1) << i);
        task_mod.unblockTask(i);
    }
}

/// Drop every lock this process holds on `inode` (fl_lock held).
fn dropOwned(inode: u64, owner: u16) void {
    var i: u32 = 0;
    while (i < lock_count) {
        if (locks[i].active and locks[i].inode == inode and locks[i].owner_pid == owner) {
            locks[i].active = false;
            var j = i;
            while (j + 1 < lock_count) : (j += 1) {
                locks[j] = locks[j + 1];
            }
            lock_count -= 1;
            continue;
        }
        i += 1;
    }
}

/// Drop every flock() lock on `inode`, whoever holds it. flock is tied to the
/// open file description, so the last close of it releases the lock even while
/// the process is still alive. fcntl locks stay: they belong to the process
/// and are released when it exits (releaseProcess).
pub fn releaseFlock(inode: u64) void {
    const flags = fl_lock.acquire();
    var i: u32 = 0;
    var dropped = false;
    while (i < lock_count) {
        if (locks[i].active and locks[i].inode == inode and locks[i].len == 0 and locks[i].start == 0 and locks[i].lock_type != 0) {
            // flock locks cover the whole file (start 0, len 0), and so does an
            // fcntl lock of the whole file — those two are not told apart here,
            // so a whole-file fcntl lock is released by the last close too.
            locks[i].active = false;
            var j = i;
            while (j + 1 < lock_count) : (j += 1) {
                locks[j] = locks[j + 1];
            }
            lock_count -= 1;
            dropped = true;
            continue;
        }
        i += 1;
    }
    fl_lock.release(flags);
    if (dropped) wakeLockWaiters();
}

/// Drop every fcntl lock held by a process that has just exited. flock locks
/// already went with the last close of their open file description, which the
/// exit path runs before this.
pub fn releaseProcess(pid: u32) void {
    const owner: u16 = @truncate(pid);
    const flags = fl_lock.acquire();
    var i: u32 = 0;
    var dropped = false;
    while (i < lock_count) {
        if (locks[i].active and locks[i].owner_pid == owner) {
            locks[i].active = false;
            var j = i;
            while (j + 1 < lock_count) : (j += 1) {
                locks[j] = locks[j + 1];
            }
            lock_count -= 1;
            dropped = true;
            continue;
        }
        i += 1;
    }
    fl_lock.release(flags);
    if (dropped) wakeLockWaiters();
}

/// flock(fd, operation) → 0/-errno
pub fn sysFlock(fd: u64, operation: u64) i64 {
    const sched_mod = @import("../proc/sched.zig");
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;
    const fd_u: u32 = @truncate(fd);
    const op: u8 = @truncate(operation);

    const inode = getInodeForFd(t.fd_table, fd_u) orelse return -9; // EBADF
    const is_nb = (op & LOCK_NB) != 0;
    const lock_type = op & (LOCK_SH | LOCK_EX | LOCK_UN);
    const owner = lockOwner(t);

    // LOCK_UN: release all locks held by this process on this inode
    if (lock_type == LOCK_UN) {
        const flags = fl_lock.acquire();
        dropOwned(inode, owner);
        fl_lock.release(flags);
        wakeLockWaiters();
        return 0;
    }

    while (true) {
        const flags = fl_lock.acquire();

        // Check for conflicts with other owners
        var has_conflict = false;
        for (0..lock_count) |i| {
            if (!locks[i].active) continue;
            if (locks[i].inode != inode) continue;
            if (locks[i].owner_pid == owner) continue;

            if (lock_type == LOCK_EX) {
                has_conflict = true;
                break;
            } else if (lock_type == LOCK_SH) {
                if (locks[i].lock_type == LOCK_EX) {
                    has_conflict = true;
                    break;
                }
            }
        }

        if (has_conflict) {
            fl_lock.release(flags);
            if (is_nb) return -11; // EAGAIN for non-blocking
            // Signal kick (sendSignal unblocks/yields us): die on a fatal
            // signal via the same exit-by-signal path the timer tick uses,
            // or report EINTR so the handler can run on return. This wait
            // links no wait node, so there is nothing to unlink.
            const sig_mod = @import("../proc/signal.zig");
            if (sig_mod.pendingFatal(t)) |sig| task_mod.exitTask(128 + @as(i32, @intCast(sig)));
            if (sig_mod.pendingActionable(t)) return -4; // -EINTR
            sleepForLock(t, cur_idx);
            continue;
        }

        // Upgrade/downgrade or add new lock for this owner
        var found_existing = false;
        for (0..lock_count) |i| {
            if (locks[i].active and locks[i].inode == inode and locks[i].owner_pid == owner) {
                locks[i].lock_type = lock_type;
                locks[i].start = 0;
                locks[i].len = 0;
                found_existing = true;
                break;
            }
        }
        if (found_existing) {
            fl_lock.release(flags);
            return 0;
        }

        // Add new lock
        if (lock_count >= locks.len) {
            fl_lock.release(flags);
            return -11; // EAGAIN
        }
        locks[lock_count] = .{
            .active = true,
            .inode = inode,
            .lock_type = lock_type,
            .owner_pid = owner,
            .start = 0,
            .len = 0,
        };
        lock_count += 1;
        fl_lock.release(flags);
        return 0;
    }
}

/// fcntl F_SETLK / F_SETLKW / F_GETLK (byte-range locks)
/// fd     — file descriptor
/// cmd    — 5=F_GETLK, 6=F_SETLK, 7=F_SETLKW
/// flock_ptr — user-space pointer to struct flock
pub fn setLock(fd: u64, cmd: u64, flock_ptr: u64) i64 {
    const sched_mod = @import("../proc/sched.zig");
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;
    const fd_u: u32 = @truncate(fd);

    // A bad pointer is EFAULT even for a descriptor that cannot be locked (a pipe, for instance): Linux checks the struct before it looks at the file.
    if (flock_ptr == 0 or flock_ptr >= 0x0000_8000_0000_0000) return -14; // EFAULT
    const copy = @import("../mm/copy_from_user.zig");
    var kbuf: [32]u8 = undefined;
    const copied = copy.copyFromUser(kbuf[0..], @ptrFromInt(flock_ptr), 32);
    if (copied < 28) return -14;

    const inode = getInodeForFd(t.fd_table, fd_u) orelse return -9; // EBADF

    const l_type: i16 = @bitCast(bo.readU16Le(kbuf[0..2]));
    _ = @as(i16, @bitCast(bo.readU16Le(kbuf[2..4]))); // l_whence
    const l_start: u64 = bo.readU64At(&kbuf, 8);
    const l_len: u64 = bo.readU64At(&kbuf, 16);

    const is_nb = (cmd != 7); // F_SETLKW = 7 is blocking
    const owner = lockOwner(t);

    // F_GETLK: check for conflicting lock (no retry needed)
    if (cmd == 5) {
        const flags = fl_lock.acquire();
        defer fl_lock.release(flags);
        for (0..lock_count) |i| {
            if (!locks[i].active) continue;
            if (locks[i].inode != inode) continue;
            if (locks[i].owner_pid == owner) continue;

            const range_overlap = (l_len == 0 or locks[i].len == 0 or
                (locks[i].start < l_start + l_len and locks[i].start + locks[i].len > l_start));
            if (!range_overlap) continue;

            var outbuf: [32]u8 = undefined;
            @memcpy(outbuf[0..32], kbuf[0..32]);
            outbuf[0] = locks[i].lock_type;
            outbuf[1] = 0;
            const pid_u16 = locks[i].owner_pid;
            outbuf[24] = @truncate(pid_u16);
            outbuf[25] = @truncate(pid_u16 >> 8);
            outbuf[26] = 0;
            outbuf[27] = 0;
            const copy_to = @import("../mm/copy_from_user.zig");
            return if (copy_to.copyToUser(@ptrFromInt(flock_ptr), outbuf[0..32], 32) == 32) 0 else -14;
        }
        var outbuf: [32]u8 = undefined;
        @memcpy(outbuf[0..32], kbuf[0..32]);
        outbuf[0] = F_UNLCK;
        outbuf[1] = 0;
        const copy_to = @import("../mm/copy_from_user.zig");
        return if (copy_to.copyToUser(@ptrFromInt(flock_ptr), outbuf[0..32], 32) == 32) 0 else -14;
    }

    // F_SETLK / F_SETLKW: set or clear a byte-range lock
    // F_UNLCK: release (no retry needed)
    if (l_type == F_UNLCK) {
        const flags = fl_lock.acquire();
        dropOwned(inode, owner);
        fl_lock.release(flags);
        wakeLockWaiters();
        return 0;
    }

    const req_lock_type: u8 = if (l_type == F_WRLCK) LOCK_EX else LOCK_SH;

    while (true) {
        const flags = fl_lock.acquire();

        // Check for conflicts with other owners
        var has_conflict = false;
        for (0..lock_count) |i| {
            if (!locks[i].active) continue;
            if (locks[i].inode != inode) continue;
            if (locks[i].owner_pid == owner) continue;

            const range_overlap = (l_len == 0 or locks[i].len == 0 or
                (locks[i].start < l_start + l_len and locks[i].start + locks[i].len > l_start));
            if (!range_overlap) continue;

            if (req_lock_type == LOCK_EX or locks[i].lock_type == LOCK_EX) {
                has_conflict = true;
                break;
            }
        }

        if (has_conflict) {
            fl_lock.release(flags);
            if (is_nb) return -11; // EAGAIN for non-blocking
            // Signal kick (sendSignal unblocks/yields us): die on a fatal
            // signal via the same exit-by-signal path the timer tick uses,
            // or report EINTR so the handler can run on return. This wait
            // links no wait node, so there is nothing to unlink.
            const sig_mod = @import("../proc/signal.zig");
            if (sig_mod.pendingFatal(t)) |sig| task_mod.exitTask(128 + @as(i32, @intCast(sig)));
            if (sig_mod.pendingActionable(t)) return -4; // -EINTR
            sleepForLock(t, cur_idx);
            continue;
        }

        // Update existing lock or add new one for this owner
        var found = false;
        for (0..lock_count) |i| {
            if (locks[i].active and locks[i].inode == inode and locks[i].owner_pid == owner) {
                locks[i].lock_type = req_lock_type;
                locks[i].start = l_start;
                locks[i].len = l_len;
                found = true;
                break;
            }
        }
        if (found) {
            fl_lock.release(flags);
            return 0;
        }

        if (lock_count >= locks.len) {
            fl_lock.release(flags);
            return -11;
        }
        locks[lock_count] = .{
            .active = true,
            .inode = inode,
            .lock_type = req_lock_type,
            .owner_pid = owner,
            .start = l_start,
            .len = l_len,
        };
        lock_count += 1;
        fl_lock.release(flags);
        return 0;
    }
}
