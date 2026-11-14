/// fcntl — file control operations.
///
/// Provides:
///   - F_DUPFD: duplicate fd to lowest available >= arg
///   - F_GETFD / F_SETFD: get/set close-on-exec flag
///   - F_GETFL / F_SETFL: get/set file status flags (O_NONBLOCK, O_APPEND)
///   - F_DUPFD_CLOEXEC: duplicate fd with FD_CLOEXEC set
///   - F_SETLEASE / F_GETLEASE: file leases (file_lock.zig, lease_policy.zig)
///   - F_SETOWN / F_GETOWN / F_SETSIG / F_GETSIG: who a lease break or O_ASYNC signals, and with which signal (per open file description)
///   - F_SETOWN_EX / F_GETOWN_EX: the owner with its type (a thread, a process or a process group)
const std = @import("std");
const vfs = @import("vfs.zig");
const policy = @import("fcntl_policy.zig");

pub const F_DUPFD: u64 = 0;
pub const F_GETFD: u64 = 1;
pub const F_SETFD: u64 = 2;
pub const F_GETFL: u64 = 3;
pub const F_SETFL: u64 = 4;
pub const F_GETLK: u64 = 5;
pub const F_SETLK: u64 = 6;
pub const F_SETLKW: u64 = 7;
pub const F_SETOWN: u64 = 8;
pub const F_GETOWN: u64 = 9;
pub const F_SETSIG: u64 = 10;
pub const F_GETSIG: u64 = 11;
pub const F_SETOWN_EX: u64 = 15;
pub const F_GETOWN_EX: u64 = 16;
pub const F_OFD_GETLK: u64 = 36;
pub const F_OFD_SETLK: u64 = 37;
pub const F_OFD_SETLKW: u64 = 38;
pub const F_SETLEASE: u64 = 1024;
pub const F_GETLEASE: u64 = 1025;
pub const F_DUPFD_CLOEXEC: u64 = 1030;
pub const F_SETPIPE_SZ: u64 = 1031;
pub const F_GETPIPE_SZ: u64 = 1032;
pub const F_ADD_SEALS: u64 = 1033;
pub const F_GET_SEALS: u64 = 1034;

pub const FD_CLOEXEC: u32 = 1;

pub const O_NONBLOCK: u32 = 0x800;
pub const O_APPEND: u32 = 0x400;

/// Duplicate fd to lowest available slot >= min_fd, with given fd_flags.
/// Returns new fd or negative errno.
fn dupFd(fd_table: *vfs.FdTable, fd: u32, min_fd: u64, new_flags: u32) i64 {
    if (!@import("../proc/rlimit.zig").Policy.dupMinimumValid(fd_table.alloc_limit, min_fd, vfs.MAX_FDS)) return -22; // EINVAL
    return fd_table.dupFdAtLeast(fd, @intCast(min_fd), new_flags);
}

/// fcntl syscall implementation.
/// Returns 0 or a positive value on success, negative errno on failure.
pub fn sysFcntl(fd_num: u64, cmd: u64, arg: u64) i64 {
    const sched_mod = @import("../proc/sched.zig");
    const task_mod = @import("../proc/task.zig");
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;
    if (fd_num >= vfs.MAX_FDS) return -9; // EBADF
    const fd: u32 = @intCast(fd_num);
    if (t.fd_table.fds[fd].fd_type == .none) return -9; // EBADF

    switch (cmd) {
        F_DUPFD => {
            return dupFd(t.fd_table, fd, arg, 0);
        },
        F_GETFD => {
            return @intCast(t.fd_table.fds[fd].fd_flags);
        },
        F_SETFD => {
            t.fd_table.fds[fd].fd_flags = policy.fdFlagsFromSetfd(arg);
            return 0;
        },
        F_GETFL => {
            const d = &t.fd_table.fds[fd];
            return @intCast(policy.reportedFlags(@tagName(d.fd_type), vfs.statusFlagsOf(d)));
        },
        F_SETFL => {
            const d = &t.fd_table.fds[fd];
            const cur_flags = vfs.statusFlagsOf(d);
            var next = policy.applySetfl(cur_flags & ~policy.O_ASYNC, arg);
            // O_ASYNC is kept only where the file can act on it (Linux setfl → f_op->fasync); elsewhere F_SETFL still succeeds.
            if (policy.keepsAsync(@tagName(d.fd_type))) {
                const want = @as(u32, @truncate(arg)) & policy.O_ASYNC;
                if (want != cur_flags & policy.O_ASYNC and !vfs.setPipeAsync(t.fd_table, @intCast(fd), want != 0)) return -12; // ENOMEM
                next |= want;
            }
            vfs.setStatusFlags(d, next);
            return 0;
        },
        F_GETOWN => return vfs.fownOf(&t.fd_table.fds[fd]).owner,
        F_GETSIG => return vfs.fownOf(&t.fd_table.fds[fd]).sig,
        F_SETOWN => {
            const who = policy.setownArg(arg) orelse return -22;
            if (who != 0 and !ownerExists(who)) return -3; // ESRCH
            vfs.setFownOf(&t.fd_table.fds[fd], who, null, false);
            return 0;
        },
        F_GETOWN_EX => {
            const fo = vfs.fownOf(&t.fd_table.fds[fd]);
            const ex = policy.getownEx(fo.owner, fo.kind);
            var out: [8]u8 = undefined;
            std.mem.writeInt(i32, out[0..4], ex.type, .little);
            std.mem.writeInt(i32, out[4..8], ex.pid, .little);
            const copy = @import("../mm/copy_from_user.zig");
            if (arg == 0 or arg >= 0x0000_8000_0000_0000) return -14;
            return if (copy.copyToUser(@ptrFromInt(arg), out[0..], 8) == 8) 0 else -14; // EFAULT
        },
        F_SETOWN_EX => {
            const copy = @import("../mm/copy_from_user.zig");
            if (arg == 0 or arg >= 0x0000_8000_0000_0000) return -14;
            var in: [8]u8 = undefined;
            if (copy.copyFromUser(in[0..], @ptrFromInt(arg), 8) != 8) return -14; // EFAULT
            const kind = std.mem.readInt(i32, in[0..4], .little);
            const pid = std.mem.readInt(i32, in[4..8], .little);
            const ex = policy.setownEx(kind, pid) catch |e| return switch (e) {
                error.InvalidType => -22, // EINVAL
                error.NoSuchOwner => -3, // ESRCH
            };
            if (ex.owner != 0 and !ownerExists(ex.owner)) return -3; // ESRCH
            vfs.setOwnerEx(&t.fd_table.fds[fd], ex.owner, ex.kind);
            return 0;
        },
        F_SETSIG => {
            const s = policy.setsigArg(arg) orelse return -22;
            vfs.setFownOf(&t.fd_table.fds[fd], null, @intCast(s), false);
            return 0;
        },
        F_SETLEASE => return @import("file_lock.zig").setLease(fd_num, arg),
        F_GETLEASE => return @import("file_lock.zig").getLease(fd_num),
        F_GETPIPE_SZ, F_SETPIPE_SZ => {
            switch (t.fd_table.fds[fd].fd_type) {
                .pipe_read, .pipe_write => {},
                else => return -9, // EBADF: not a pipe
            }
            return if (cmd == F_GETPIPE_SZ) @as(i64, policy.PIPE_SIZE) else policy.setPipeSize(arg);
        },
        F_DUPFD_CLOEXEC => {
            return dupFd(t.fd_table, fd, arg, FD_CLOEXEC);
        },
        F_ADD_SEALS, F_GET_SEALS => {
            // Seals live on tmpfs files (memfds are tmpfs files); every
            // other file type is EINVAL, as on Linux.
            if (t.fd_table.fds[fd].fd_type != .tmpfs_file) return -22;
            const tmpfs = @import("tmpfs.zig");
            const idx: u16 = @intCast(t.fd_table.fds[fd].tmpfs_idx);
            if (cmd == F_GET_SEALS) return @intCast(tmpfs.tmpfsGetSeals(idx) orelse return -22);
            // Linux: adding seals needs a writable descriptor.
            if (!t.fd_table.fds[fd].writable) return -1;
            const maps = @import("../proc/task.zig").countSharedWritableTmpfsMaps(idx, tmpfs.tmpfsGetCtime(idx));
            return tmpfs.tmpfsAddSeals(idx, @truncate(arg), maps);
        },
        F_GETLK, F_SETLK, F_SETLKW, F_OFD_GETLK, F_OFD_SETLK, F_OFD_SETLKW => {
            const file_lock = @import("file_lock.zig");
            return file_lock.setLock(fd_num, cmd, arg);
        },
        else => return -22, // EINVAL
    }
}

/// F_SETOWN's target exists: a live task with that pid (> 0), or a live member of process group -who (< 0).
fn ownerExists(who: i32) bool {
    const task_mod = @import("../proc/task.zig");
    for (0..task_mod.MAX_TASKS) |i| {
        const t = task_mod.getTask(@intCast(i)) orelse continue;
        if (t.state == .zombie) continue;
        if (who > 0 and t.tid == @as(u32, @intCast(who))) return true;
        if (who < 0 and @as(i64, t.pgid) == -@as(i64, who)) return true;
    }
    return false;
}
