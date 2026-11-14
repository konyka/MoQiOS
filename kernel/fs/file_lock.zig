/// File locking — flock() and fcntl() record locks.
///
/// The table itself is lock_table.zig. Here each lock gets its file and its owner:
///   - the file is lockKey(), the same for every open of one file;
///   - a flock is owned by the open file description: its shared-offset slot (a descriptor is moved to a shared slot when it
///     takes a flock, so a later dup/fork keeps the owner), or the descriptor itself for kinds without a byte offset;
///   - an fcntl lock is owned by the descriptor table (Linux: current->files), so every thread sharing the table shares it;
///   - an OFD lock (F_OFD_GETLK/SETLK/SETLKW) is a byte-range lock like an fcntl lock, in the same range space, but owned by the
///     open file description (the flock owner), and reports l_pid -1.
/// Releasing (vfs.releaseOpenFile): any close drops the table's fcntl locks on that file; the last close of an open file
/// description drops its flock, its OFD locks and its lease. A blocked flock/F_SETLKW parks the task (sleep_bm) and is woken when a lock is released, or by
/// the scheduler tick within 10 ms.
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const vfs = @import("vfs.zig");
const task_mod = @import("../proc/task.zig");
const bo = @import("../lib/byte_order.zig");
const lt = @import("lock_table.zig");
const lp = @import("lease_policy.zig");

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
const EDEADLK: i64 = -35;

var table: lt.Table(128) = .{};
var fl_lock: IrqSpinlock = .{};
/// File leases (F_SETLEASE), under fl_lock.
var leases: lp.Table(32) = .{};
/// Set once any lease has been taken, so an open of a system that never used leases does not take fl_lock.
var leases_used: bool = false;
/// Tasks parked in a blocking flock/F_SETLKW, by task index. Releasing a lock
/// unblocks them; the scheduler tick does too, so a missed wake still ends.
var lock_waiter_bm: u64 = 0;

/// What each task blocked in F_SETLKW is waiting for, by task index (under fl_lock), for the EDEADLK check.
var waits: [64]lt.Wait = @splat(.{});

fn clearWait(cur_idx: u32) void {
    if (cur_idx >= waits.len) return;
    const flags = fl_lock.acquire();
    waits[cur_idx] = .{};
    fl_lock.release(flags);
    @atomicStore(u64, &breakers[cur_idx], 0, .release);
}

/// The open file description each task index is breaking leases for (0: none). Linux breaks leases before the open takes its
/// share of the file's open counts, so such an open is not yet one that refuses a lease (countOpens skips it).
var breakers: [64]u64 = @splat(0);

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
    if (sig_mod.pendingFatal(t)) |sig| {
        clearWait(cur_idx); // exitTask does not return, so setLock's defer would not run
        task_mod.exitTask(128 + @as(i32, @intCast(sig)));
    }
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
            dropped = table.dropOwner(k, .posix, o) or dropped;
            dropped = leases.dropOwner(o) or dropped;
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

/// F_GETLK/F_SETLK/F_SETLKW and their open file description forms.
pub const F_OFD_GETLK: u64 = 36;
pub const F_OFD_SETLK: u64 = 37;
pub const F_OFD_SETLKW: u64 = 38;
/// The l_pid an OFD lock reports: it belongs to no process (Linux locks_translate_pid).
const OFD_PID: u32 = 0xffff_ffff;

/// fcntl F_SETLK / F_SETLKW / F_GETLK (byte-range locks)
/// fd     — file descriptor
/// cmd    — 5=F_GETLK, 6=F_SETLK, 7=F_SETLKW; 36/37/38 the same for a lock owned by the open file description, whose l_pid must be 0
/// flock_ptr — user-space pointer to struct flock
pub fn setLock(fd: u64, cmd_in: u64, flock_ptr: u64) i64 {
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
    const ofd = cmd_in == F_OFD_GETLK or cmd_in == F_OFD_SETLK or cmd_in == F_OFD_SETLKW;
    if (ofd and bo.readU32Le(kbuf[24..28]) != 0) return EINVAL;
    const cmd: u64 = if (ofd) cmd_in - 31 else cmd_in;
    const fdt = t.fd_table;
    // Every way out of a blocking F_SETLKW (lock taken, EDEADLK, EINTR, a descriptor closed under the wait) ends the wait.
    defer if (cmd == 7) clearWait(cur_idx);

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
        const owner = if (ofd) vfs.flockOwner(fdt, fd_u) orelse {
            fdt.releaseTransferFd(fd_u);
            return ENOLCK;
        } else vfs.posixLockOwner(fdt);
        const pid = if (ofd) OFD_PID else reportedPid(t);
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

        const hit = table.conflict(key, .posix, owner, write, range.start, range.end) orelse {
            if (cur_idx < waits.len) waits[cur_idx] = .{};
            const ok = table.setPosix(key, owner, pid, write, range.start, range.end);
            fl_lock.release(flags);
            fdt.releaseTransferFd(fd_u);
            // Turning a write lock into a read lock can let readers in.
            if (ok) wakeLockWaiters();
            return if (ok) 0 else ENOLCK;
        };
        if (cmd != 7) {
            fl_lock.release(flags);
            fdt.releaseTransferFd(fd_u);
            return EAGAIN;
        }
        // Waiting for `hit`'s owner, who may itself be waiting (in a chain) for us: report that instead of sleeping forever. An
        // OFD lock belongs to no process, so its waits are neither checked nor recorded (Linux posix_locks_deadlock).
        if (ofd) {
            fl_lock.release(flags);
            fdt.releaseTransferFd(fd_u);
            if (waitOrInterrupt(t, cur_idx)) |r| return r;
            continue;
        }
        if (lt.wouldDeadlock(owner, hit.owner, &waits)) {
            if (cur_idx < waits.len) waits[cur_idx] = .{};
            fl_lock.release(flags);
            fdt.releaseTransferFd(fd_u);
            return EDEADLK;
        }
        if (cur_idx < waits.len) waits[cur_idx] = .{ .owner = owner, .waits_for = hit.owner };
        fl_lock.release(flags);
        fdt.releaseTransferFd(fd_u);
        if (waitOrInterrupt(t, cur_idx)) |r| return r;
    }
}

/// Signal the owners of the broken leases (Linux lease_break_callback → kill_fasync → send_sigio): each lease's description
/// names the owner (F_SETOWN: a pid, -pgrp, or 0 for nobody) and the signal (F_SETSIG; 0 is a plain SIGIO). A standard signal
/// goes to an owner once (it would coalesce anyway); a real-time one is queued per lease, each with its own si_fd.
fn signalBreak(notify: *const lp.Notify) void {
    const sig_mod = @import("../proc/signal.zig");
    const fp = @import("fcntl_policy.zig");
    var done: [8]struct { owner: i32, signo: u32 } = undefined;
    var nd: usize = 0;
    outer: for (notify.entries[0..notify.n]) |e| {
        const fo: vfs.Fown = vfs.fownOfDescription(e.owner) orelse .{ .owner = @intCast(e.tgid), .sig = 0 };
        if (fo.owner == 0) continue;
        const s = fp.leaseBreakSignal(fo.sig, e.fd);
        if (s.signo < 32) {
            for (done[0..nd]) |d| if (d.owner == fo.owner and d.signo == s.signo) continue :outer;
            done[nd] = .{ .owner = fo.owner, .signo = s.signo };
            nd += 1;
        }
        if (fo.owner > 0) {
            _ = sig_mod.sendSignalInfo(@intCast(fo.owner), s.signo, s.info);
        } else if (-fo.owner <= 0xffff) {
            _ = sig_mod.sendSignalToPgrpInfo(@intCast(-fo.owner), s.signo, null, s.info);
        }
    }
}

fn nowNs() u64 {
    return @import("../arch/arch.zig").tsc.nanos();
}

/// Leases are taken on regular files of the writable filesystems only (Linux generic_setlease: S_ISREG).
fn leaseable(desc: *const vfs.FileDescriptor) bool {
    return switch (desc.fd_type) {
        .ramdisk_file => true,
        .tmpfs_file => if (@import("tmpfs.zig").tmpfsGetMetadata(@intCast(desc.tmpfs_idx))) |m| !m.is_dir else false,
        .fat32_file => !@import("fat32.zig").openIsDir(desc.fat32_file_idx),
        .ext2_file => @import("ext2.zig").openFileIsDir(desc.ext2_file_idx) == false,
        else => false,
    };
}

fn leaseIsDir(desc: *const vfs.FileDescriptor) bool {
    return switch (desc.fd_type) {
        .tmpfs_file => if (@import("tmpfs.zig").tmpfsGetMetadata(@intCast(desc.tmpfs_idx))) |m| m.is_dir else false,
        .fat32_file => @import("fat32.zig").openIsDir(desc.fat32_file_idx),
        .ext2_file => @import("ext2.zig").openFileIsDir(desc.ext2_file_idx) orelse false,
        else => false,
    };
}

/// The uid vfs_setlease compares with the caller's: the owner fstat reports. Ramdisk and FAT32 files, devices and anonymous
/// inodes (eventfd, timerfd, epoll, ...) belong to root. Pipes, sockets and procfs have no owner modeled here and stay EINVAL.
fn leaseOwnerUid(desc: *const vfs.FileDescriptor) ?u32 {
    return switch (desc.fd_type) {
        .tmpfs_file => if (@import("tmpfs.zig").tmpfsGetMetadata(@intCast(desc.tmpfs_idx))) |m| m.uid else null,
        .ext2_file => blk: {
            var info: @import("stat_info.zig").StatInfo = .{};
            break :blk if (@import("ext2.zig").statInode(desc.ext2_file_idx, &info)) info.uid else null;
        },
        .ramdisk_file, .fat32_file, .special, .devfs, .devfs_ctrl, .eventfd, .timerfd, .epoll, .inotify, .pidfd => 0,
        else => null,
    };
}

fn isBreaker(owner: u64) bool {
    for (&breakers) |*b| if (@atomicLoad(u64, b, .acquire) == owner) return true;
    return false;
}

/// The open file descriptions of file `key` across every descriptor table, split into those open for writing and those open
/// read-only (Linux i_writecount / i_readcount), skipping opens still breaking a lease. Scanned outside fl_lock: the slot locks
/// are taken under it nowhere else.
fn countOpens(key: u64, self_writable: bool) lp.Opens {
    var owners: [64]u64 = undefined;
    var n: usize = 0;
    var opens: lp.Opens = .{ .writers = 0, .readers = 0, .self_writable = self_writable };
    for (0..vfs.MAX_FD_TABLES) |slot| {
        const pinned = vfs.pinLiveTableSlot(@intCast(slot)) orelse continue;
        defer vfs.unpinFdTable(pinned.table);
        for (0..vfs.MAX_FDS) |i| {
            const id = pinned.table.snapshotFdIdentity(@intCast(i)) orelse continue;
            if (!leaseable(&id.desc) or (lockKey(&id.desc) orelse continue) != key) continue;
            const owner = vfs.descriptionOwner(pinned.table, @intCast(i), &id.desc);
            if (isBreaker(owner)) continue;
            const seen = for (owners[0..n]) |o| {
                if (o == owner) break true;
            } else false;
            if (seen) continue;
            if (n < owners.len) {
                owners[n] = owner;
                n += 1;
            }
            if (id.desc.writable) opens.writers += 1 else opens.readers += 1;
        }
    }
    return opens;
}

/// fcntl(fd, F_SETLEASE, arg): F_RDLCK / F_WRLCK / F_UNLCK on the open file description of `fd`.
pub fn setLease(fd: u64, arg: u64) i64 {
    const sched_mod = @import("../proc/sched.zig");
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;
    if (fd >= vfs.MAX_FDS) return EBADF;
    const fd_u: u32 = @intCast(fd);
    const fdt = t.fd_table;
    if (!fdt.acquireTransferFd(fd_u)) return EBADF;
    defer fdt.releaseTransferFd(fd_u);
    const desc = &fdt.fds[fd_u];
    // Linux order: fcntl_setlease's S_ISDIR, lease_alloc's type check, vfs_setlease's owner check, then the filesystem's support.
    if (@import("dir_ops.zig").descriptorKind(desc) == .directory or leaseIsDir(desc)) return EINVAL;
    if (arg != lp.RDLCK and arg != lp.WRLCK and arg != lp.UNLCK) return EINVAL;
    const file_uid = leaseOwnerUid(desc) orelse return EINVAL;
    const may = lp.mayLease(file_uid, t.euid, t.effective_caps.cap_lease);
    if (may != 0) return may;
    if (!leaseable(desc)) return EINVAL;
    const key = lockKey(desc) orelse return EINVAL;
    var rc: i64 = undefined;
    if (arg == lp.UNLCK) {
        const owner = vfs.descriptionOwner(fdt, fd_u, desc);
        const flags = fl_lock.acquire();
        rc = leases.unlock(key, owner, nowNs());
        fl_lock.release(flags);
        // Linux lease_modify(F_UNLCK): f_delown and signum = 0.
        if (rc == 0) vfs.setFownOf(desc, 0, 0, false);
    } else {
        const owner = vfs.flockOwner(fdt, fd_u) orelse return ENOLCK;
        const opens = countOpens(key, desc.writable);
        const flags = fl_lock.acquire();
        @atomicStore(bool, &leases_used, true, .release);
        rc = leases.set(key, owner, reportedPid(t), arg, opens, nowNs());
        if (rc == 0) leases.noteFd(key, owner, fd_u);
        fl_lock.release(flags);
        // Linux lease_setup: the caller becomes the owner unless the description already has one.
        if (rc == 0) vfs.setFownOf(desc, @intCast(reportedPid(t)), null, true);
    }
    // Giving a lease up or downgrading it lets a blocked opener go on.
    wakeLockWaiters();
    return rc;
}

/// fcntl(fd, F_GETLEASE): the type the description's lease is (or is on its way to), F_UNLCK for none.
pub fn getLease(fd: u64) i64 {
    const sched_mod = @import("../proc/sched.zig");
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;
    if (fd >= vfs.MAX_FDS) return EBADF;
    const fd_u: u32 = @intCast(fd);
    const fdt = t.fd_table;
    if (!fdt.acquireTransferFd(fd_u)) return EBADF;
    defer fdt.releaseTransferFd(fd_u);
    const desc = &fdt.fds[fd_u];
    if (!@atomicLoad(bool, &leases_used, .acquire) or !leaseable(desc)) return @intCast(lp.UNLCK);
    const key = lockKey(desc) orelse return @intCast(lp.UNLCK);
    const owner = vfs.descriptionOwner(fdt, fd_u, desc);
    const flags = fl_lock.acquire();
    const r = leases.get(key, owner, nowNs());
    fl_lock.release(flags);
    return @intCast(r);
}

/// Descriptor `fd` of `fdt` was just opened (`write`: for writing, or for a truncate): break the leases it conflicts with
/// (Linux __break_lease). Each holder gets SIGIO; a non-blocking open is then EAGAIN, a blocking one waits until no conflicting
/// lease is left (the holder gives it up or downgrades it, or its break time runs out) and is EINTR on a caught signal.
pub fn breakLease(fdt: *vfs.FdTable, fd: u32, write: bool, nonblock: bool) i64 {
    if (!@atomicLoad(bool, &leases_used, .acquire)) return 0;
    const sched_mod = @import("../proc/sched.zig");
    const cur_idx = sched_mod.currentTaskIndex() orelse return 0;
    const t = task_mod.getTask(cur_idx) orelse return 0;
    const id = fdt.snapshotFdIdentity(fd) orelse return 0;
    if (!leaseable(&id.desc)) return 0;
    const key = lockKey(&id.desc) orelse return 0;
    if (cur_idx < breakers.len) @atomicStore(u64, &breakers[cur_idx], vfs.descriptionOwner(fdt, fd, &id.desc), .release);
    defer clearWait(cur_idx);
    var notify = lp.Notify{};
    var flags = fl_lock.acquire();
    const any = leases.breakFor(key, write, nowNs(), &notify);
    fl_lock.release(flags);
    if (!any) return 0;
    signalBreak(&notify);
    if (nonblock) return EAGAIN;
    while (true) {
        flags = fl_lock.acquire();
        const c = leases.conflicts(key, write, nowNs());
        fl_lock.release(flags);
        if (!c) return 0;
        if (waitOrInterrupt(t, cur_idx)) |r| return r;
    }
}
