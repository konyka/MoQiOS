/// File locking — flock() and fcntl() record locks.
///
/// The table itself is lock_table.zig. Here each lock gets its file and its owner:
///   - the file is lockKey(), the same for every open of one file;
///   - a flock is owned by the open file description: its shared-offset slot (a descriptor is moved to a shared slot when it
///     takes a flock, so a later dup/fork keeps the owner), or the descriptor itself for kinds without a byte offset;
///   - an fcntl lock is owned by the descriptor table (Linux: current->files), so every thread sharing the table shares it.
/// Releasing (vfs.releaseOpenFile): any close drops the table's fcntl locks on that file; the last close of an open file
/// description drops its flock. A blocked flock/F_SETLKW parks the task (sleep_bm) and is woken when a lock is released, or by
/// the scheduler tick within 10 ms.
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const vfs = @import("vfs.zig");
const task_mod = @import("../proc/task.zig");
const bo = @import("../lib/byte_order.zig");
const lt = @import("lock_table.zig");

// flock() operation bits
pub const LOCK_SH = 1; // shared lock
pub const LOCK_EX = 2; // exclusive lock
pub const LOCK_NB = 4; // non-blocking
pub const LOCK_UN = 8; // unlock

// fcntl lock types
pub const F_RDLCK = 0;
pub const F_WRLCK = 1;
pub const F_UNLCK = 2;

const EBADF: i64 = -9;
const EAGAIN: i64 = -11;
const EFAULT: i64 = -14;
const EINVAL: i64 = -22;
const ENOLCK: i64 = -37;
const EOVERFLOW: i64 = -75;

var table: lt.Table(128) = .{};
var fl_lock: IrqSpinlock = .{};
/// Tasks parked in a blocking flock/F_SETLKW, by task index. Releasing a lock
/// unblocks them; the scheduler tick does too, so a missed wake still ends.
var lock_waiter_bm: u64 = 0;

/// How long a blocked lock sleeps before it looks again: one scheduler tick.
const LOCK_POLL_NS: u64 = 10_000_000;

/// The file a lock is keyed by: two opens of one file share a key and two files never do. tmpfs descriptors carry no inode_id,
/// and a FAT32 file is keyed by its open slot rather than its first cluster: a file that is empty on disk has no cluster (every
/// such file would share key 0) and gets one on its first write (the key would change under a held lock). The slot is stable
/// while any descriptor of the file is open, and a lock only lives that long. Null for a descriptor that cannot be locked.
pub fn lockKey(desc: *const vfs.FileDescriptor) ?u64 {
    return switch (desc.fd_type) {
        .none => null,
        .tmpfs_file => 0x1000_0000_0000_0000 + @as(u64, desc.tmpfs_idx),
        .fat32_file => 0x2800_0000_0000_0000 + @as(u64, desc.fat32_file_idx),
        else => if (desc.inode_id == 0) null else desc.inode_id,
    };
}

/// The process id a lock reports through F_GETLK (getpid()'s id: the thread group leader).
fn reportedPid(t: *task_mod.Task) u32 {
    return if (t.is_thread and t.parent_tid != 0) t.parent_tid else t.tid;
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
pub fn wakeLockWaiters() void {
    var bm = @atomicLoad(u64, &lock_waiter_bm, .acquire);
    while (bm != 0) {
        const i: u6 = @intCast(@ctz(bm));
        bm &= ~(@as(u64, 1) << i);
        task_mod.unblockTask(i);
    }
}

/// A conflict was found and the caller may wait: die on a fatal signal, report EINTR for a caught one, else sleep. Null means
/// "look again".
fn waitOrInterrupt(t: *task_mod.Task, cur_idx: u32) ?i64 {
    const sig_mod = @import("../proc/signal.zig");
    if (sig_mod.pendingFatal(t)) |sig| task_mod.exitTask(128 + @as(i32, @intCast(sig)));
    if (sig_mod.pendingActionable(t)) return -4; // EINTR
    sleepForLock(t, cur_idx);
    return null;
}

/// A descriptor of file `key` is closing (vfs.releaseOpenFile): drop the fcntl locks of `posix_owner` on the file, give back
/// the descriptor's share of offset slot `slot` with `release_slot`, and when that was the last share drop the flock of
/// `ofd_owner`. The slot is released under fl_lock: the slot number is the flock owner, and a new description that got the
/// freed slot first could otherwise lose its own flock here.
pub fn releaseOnClose(key: ?u64, posix_owner: ?u64, ofd_owner: ?u64, slot: u16, release_slot: *const fn (u16) bool) void {
    const flags = fl_lock.acquire();
    const last = release_slot(slot);
    var dropped = false;
    if (key) |k| {
        if (posix_owner) |po| dropped = table.dropOwner(k, .posix, po) or dropped;
        if (last) if (ofd_owner) |o| {
            dropped = table.dropFlock(k, o) or dropped;
        };
    }
    fl_lock.release(flags);
    if (dropped) wakeLockWaiters();
}

/// flock(fd, operation) → 0/-errno
pub fn sysFlock(fd: u64, operation: u64) i64 {
    const sched_mod = @import("../proc/sched.zig");
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;
    if (fd >= vfs.MAX_FDS) return EBADF;
    const fd_u: u32 = @intCast(fd);
    const op: u32 = @truncate(operation);
    const is_nb = (op & LOCK_NB) != 0;
    const what = op & ~@as(u32, LOCK_NB);
    if (what != LOCK_SH and what != LOCK_EX and what != LOCK_UN) return EINVAL;
    const fdt = t.fd_table;

    while (true) {
        // The hold keeps the descriptor (and so its open file description) from being torn down while the lock is set: a close
        // that races in finishes when the hold goes, and drops the lock taken here.
        if (!fdt.acquireTransferFd(fd_u)) return EBADF;
        const key = lockKey(&fdt.fds[fd_u]) orelse {
            fdt.releaseTransferFd(fd_u);
            return EBADF;
        };
        const owner = vfs.flockOwner(fdt, fd_u) orelse {
            fdt.releaseTransferFd(fd_u);
            return ENOLCK;
        };
        const flags = fl_lock.acquire();
        if (what == LOCK_UN) {
            const dropped = table.dropFlock(key, owner);
            fl_lock.release(flags);
            fdt.releaseTransferFd(fd_u);
            if (dropped) wakeLockWaiters();
            return 0;
        }
        const write = what == LOCK_EX;
        if (table.conflict(key, .flock, owner, write, 0, lt.OFFSET_MAX) == null) {
            const ok = table.setFlock(key, owner, reportedPid(t), write);
            fl_lock.release(flags);
            fdt.releaseTransferFd(fd_u);
            return if (ok) 0 else ENOLCK;
        }
        fl_lock.release(flags);
        fdt.releaseTransferFd(fd_u);
        if (is_nb) return EAGAIN;
        if (waitOrInterrupt(t, cur_idx)) |r| return r;
    }
}

/// struct flock (x86_64, 32 bytes): l_type@0 l_whence@2 l_start@8 l_len@16 l_pid@24.
fn writeBack(flock_ptr: u64, kbuf: *[32]u8, l_type: u8, l: ?lt.Lock) i64 {
    var out: [32]u8 = kbuf.*;
    bo.writeU16Le(out[0..2], l_type);
    if (l) |lk| {
        bo.writeU16Le(out[2..4], 0); // SEEK_SET
        bo.writeU64Le(out[8..16], lk.start);
        bo.writeU64Le(out[16..24], @bitCast(lt.lengthOf(&lk)));
        bo.writeU32Le(out[24..28], lk.pid);
    }
    const copy = @import("../mm/copy_from_user.zig");
    return if (copy.copyToUser(@ptrFromInt(flock_ptr), out[0..32], 32) == 32) 0 else EFAULT;
}

/// The size SEEK_END of an fcntl lock is relative to.
fn fileSize(desc: *vfs.FileDescriptor) u64 {
    return switch (desc.fd_type) {
        .tmpfs_file => @import("tmpfs.zig").tmpfsGetSize(@intCast(desc.tmpfs_idx)),
        .fat32_file => @import("fat32.zig").currentSize(desc.fat32_file_idx),
        .ext2_file => @import("ext2.zig").currentSize(desc.ext2_file_idx),
        else => desc.file_size,
    };
}

/// fcntl F_SETLK / F_SETLKW / F_GETLK (byte-range locks)
/// fd     — file descriptor
/// cmd    — 5=F_GETLK, 6=F_SETLK, 7=F_SETLKW
/// flock_ptr — user-space pointer to struct flock
pub fn setLock(fd: u64, cmd: u64, flock_ptr: u64) i64 {
    const sched_mod = @import("../proc/sched.zig");
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;

    // A bad pointer is EFAULT even for a descriptor that cannot be locked (a pipe, for instance): Linux checks the struct before it looks at the file.
    if (flock_ptr == 0 or flock_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    const copy = @import("../mm/copy_from_user.zig");
    var kbuf: [32]u8 = undefined;
    const copied = copy.copyFromUser(kbuf[0..], @ptrFromInt(flock_ptr), 32);
    if (copied < 28) return EFAULT;

    if (fd >= vfs.MAX_FDS) return EBADF;
    const fd_u: u32 = @intCast(fd);
    const l_type: i16 = @bitCast(bo.readU16Le(kbuf[0..2]));
    const l_whence: i16 = @bitCast(bo.readU16Le(kbuf[2..4]));
    const l_start: i64 = @bitCast(bo.readU64At(&kbuf, 8));
    const l_len: i64 = @bitCast(bo.readU64At(&kbuf, 16));
    if (l_type != F_RDLCK and l_type != F_WRLCK and l_type != F_UNLCK) return EINVAL;
    if (l_whence < 0 or l_whence > 2) return EINVAL;
    const fdt = t.fd_table;
    const owner = vfs.posixLockOwner(fdt);

    while (true) {
        if (!fdt.acquireTransferFd(fd_u)) return EBADF;
        const desc = &fdt.fds[fd_u];
        const key = lockKey(desc) orelse {
            fdt.releaseTransferFd(fd_u);
            return EBADF;
        };
        const base: i64 = switch (l_whence) {
            1 => @bitCast(vfs.offsetOf(desc)),
            2 => @bitCast(fileSize(desc)),
            else => 0,
        };
        const range = lt.rangeOf(base, l_start, l_len) catch |e| {
            fdt.releaseTransferFd(fd_u);
            return if (e == error.Overflow) EOVERFLOW else EINVAL;
        };
        const write = l_type == F_WRLCK;
        const flags = fl_lock.acquire();

        if (cmd == 5) { // F_GETLK
            const hit = if (l_type == F_UNLCK) null else table.conflict(key, .posix, owner, write, range.start, range.end);
            fl_lock.release(flags);
            fdt.releaseTransferFd(fd_u);
            if (l_type == F_UNLCK) return EINVAL;
            if (hit) |h| return writeBack(flock_ptr, &kbuf, if (h.write) F_WRLCK else F_RDLCK, h);
            return writeBack(flock_ptr, &kbuf, F_UNLCK, null);
        }

        if (l_type == F_UNLCK) {
            var changed = false;
            const ok = table.unlockPosix(key, owner, range.start, range.end, &changed);
            fl_lock.release(flags);
            fdt.releaseTransferFd(fd_u);
            if (changed) wakeLockWaiters();
            return if (ok) 0 else ENOLCK;
        }

        if (table.conflict(key, .posix, owner, write, range.start, range.end) == null) {
            const ok = table.setPosix(key, owner, reportedPid(t), write, range.start, range.end);
            fl_lock.release(flags);
            fdt.releaseTransferFd(fd_u);
            // Turning a write lock into a read lock can let readers in.
            if (ok) wakeLockWaiters();
            return if (ok) 0 else ENOLCK;
        }
        fl_lock.release(flags);
        fdt.releaseTransferFd(fd_u);
        if (cmd != 7) return EAGAIN;
        if (waitOrInterrupt(t, cur_idx)) |r| return r;
    }
}
