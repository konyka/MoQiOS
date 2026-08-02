/// File locking — flock() and fcntl() byte-range locks.
///
/// Implementation:
///   - Static table of 64 active locks
///   - Wait queue for F_SETLKW blocking (uses sched.waitOne/forceReschedule)
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

/// Get the inode identifier for an open fd.
fn getInodeForFd(fd_table: *vfs.FdTable, fd: u32) ?u64 {
    if (fd >= vfs.MAX_FDS) return null;
    const desc = &fd_table.fds[fd];
    if (desc.fd_type == .none) return null;
    return desc.inode_id;
}

/// flock(fd, operation) → 0/-errno
pub fn sysFlock(fd: u64, operation: u64) i64 {
    const sched_mod = @import("../proc/sched.zig");
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;
    const fd_u: u32 = @truncate(fd);
    const op: u8 = @truncate(operation);

    const inode = getInodeForFd(&t.fd_table, fd_u) orelse return -9; // EBADF
    const is_nb = (op & LOCK_NB) != 0;
    const lock_type = op & (LOCK_SH | LOCK_EX | LOCK_UN);

    // Retry loop for blocking mode
    var retry_count: u32 = 0;
    while (retry_count < 128) : (retry_count += 1) {
        const flags = fl_lock.acquire();

        // LOCK_UN: release all locks held by this process on this inode
        if (lock_type == LOCK_UN) {
            var i: u32 = 0;
            while (i < lock_count) {
                if (locks[i].active and locks[i].inode == inode and locks[i].owner_pid == @as(u16, @truncate(t.tid))) {
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
            fl_lock.release(flags);
            return 0;
        }

        // Check for conflicts with other owners
        var has_conflict = false;
        for (0..lock_count) |i| {
            if (!locks[i].active) continue;
            if (locks[i].inode != inode) continue;
            if (locks[i].owner_pid == @as(u16, @truncate(t.tid))) continue;

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
            // or report EINTR so the handler can run on return. This retry
            // loop links no wait node, so there is nothing to unlink.
            const sig_mod = @import("../proc/signal.zig");
            if (sig_mod.pendingFatal(t)) |sig| task_mod.exitTask(128 + @as(i32, @intCast(sig)));
            if (sig_mod.pendingActionable(t)) return -4; // -EINTR
            // Blocking: yield and retry
            sched_mod.forceReschedule();
            continue;
        }

        // Upgrade/downgrade or add new lock for this owner
        var found_existing = false;
        for (0..lock_count) |i| {
            if (locks[i].active and locks[i].inode == inode and locks[i].owner_pid == @as(u16, @truncate(t.tid))) {
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
            .owner_pid = @as(u16, @truncate(t.tid)),
            .start = 0,
            .len = 0,
        };
        lock_count += 1;
        fl_lock.release(flags);
        return 0;
    }
    return -11; // EAGAIN after max retries
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

    const inode = getInodeForFd(&t.fd_table, fd_u) orelse return -9; // EBADF

    // Read struct flock from user space (x86_64 layout, 32 bytes)
    if (flock_ptr == 0 or flock_ptr >= 0x0000_8000_0000_0000) return -14; // EFAULT
    const copy = @import("../mm/copy_from_user.zig");
    var kbuf: [32]u8 = undefined;
    const copied = copy.copyFromUser(kbuf[0..], @ptrFromInt(flock_ptr), 32);
    if (copied < 28) return -14;

    const l_type: i16 = @bitCast(bo.readU16Le(kbuf[0..2]));
    _ = @as(i16, @bitCast(bo.readU16Le(kbuf[2..4]))); // l_whence
    const l_start: u64 = bo.readU64At(&kbuf, 8);
    const l_len: u64 = bo.readU64At(&kbuf, 16);

    const is_nb = (cmd != 7); // F_SETLKW = 7 is blocking

    // F_GETLK: check for conflicting lock (no retry needed)
    if (cmd == 5) {
        const flags = fl_lock.acquire();
        defer fl_lock.release(flags);
        for (0..lock_count) |i| {
            if (!locks[i].active) continue;
            if (locks[i].inode != inode) continue;
            if (locks[i].owner_pid == @as(u16, @truncate(t.tid))) continue;

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
        defer fl_lock.release(flags);
        var i: u32 = 0;
        while (i < lock_count) {
            if (locks[i].active and locks[i].inode == inode and locks[i].owner_pid == @as(u16, @truncate(t.tid))) {
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
        return 0;
    }

    const req_lock_type: u8 = if (l_type == F_WRLCK) LOCK_EX else LOCK_SH;

    // Retry loop for blocking lock acquisition
    var retry_count: u32 = 0;
    while (retry_count < 128) : (retry_count += 1) {
        const flags = fl_lock.acquire();

        // Check for conflicts with other owners
        var has_conflict = false;
        for (0..lock_count) |i| {
            if (!locks[i].active) continue;
            if (locks[i].inode != inode) continue;
            if (locks[i].owner_pid == @as(u16, @truncate(t.tid))) continue;

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
            // or report EINTR so the handler can run on return. This retry
            // loop links no wait node, so there is nothing to unlink.
            const sig_mod = @import("../proc/signal.zig");
            if (sig_mod.pendingFatal(t)) |sig| task_mod.exitTask(128 + @as(i32, @intCast(sig)));
            if (sig_mod.pendingActionable(t)) return -4; // -EINTR
            sched_mod.forceReschedule();
            continue;
        }

        // Update existing lock or add new one for this owner
        var found = false;
        for (0..lock_count) |i| {
            if (locks[i].active and locks[i].inode == inode and locks[i].owner_pid == @as(u16, @truncate(t.tid))) {
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
            .owner_pid = @as(u16, @truncate(t.tid)),
            .start = l_start,
            .len = l_len,
        };
        lock_count += 1;
        fl_lock.release(flags);
        return 0;
    }
    return -11; // EAGAIN after max retries
}
