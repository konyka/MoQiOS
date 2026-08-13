/// fcntl — file control operations.
///
/// Provides:
///   - F_DUPFD: duplicate fd to lowest available >= arg
///   - F_GETFD / F_SETFD: get/set close-on-exec flag
///   - F_GETFL / F_SETFL: get/set file status flags (O_NONBLOCK, O_APPEND)
///   - F_DUPFD_CLOEXEC: duplicate fd with FD_CLOEXEC set
const vfs = @import("vfs.zig");

pub const F_DUPFD: u64 = 0;
pub const F_GETFD: u64 = 1;
pub const F_SETFD: u64 = 2;
pub const F_GETFL: u64 = 3;
pub const F_SETFL: u64 = 4;
pub const F_GETLK: u64 = 5;
pub const F_SETLK: u64 = 6;
pub const F_SETLKW: u64 = 7;
pub const F_DUPFD_CLOEXEC: u64 = 1030;

pub const FD_CLOEXEC: u32 = 1;

pub const O_NONBLOCK: u32 = 0x800;
pub const O_APPEND: u32 = 0x400;

/// Duplicate fd to lowest available slot >= min_fd, with given fd_flags.
/// Returns new fd or negative errno.
fn dupFd(fd_table: *vfs.FdTable, fd: u32, min_fd: u64, new_flags: u32) i64 {
    if (!@import("../proc/rlimit.zig").Policy.dupMinimumValid(fd_table.alloc_limit, min_fd, vfs.MAX_FDS)) return -22; // EINVAL
    const min_fd_u32: u32 = @intCast(min_fd);
    const slot = fd_table.allocFdAtLeast(min_fd_u32) orelse return -24; // EMFILE
    fd_table.fds[slot] = fd_table.fds[fd];
    fd_table.fds[slot].fd_flags = new_flags;
    // Increment pipe ref count if it's a pipe
    if (fd_table.fds[slot].fd_type == .pipe_read or fd_table.fds[slot].fd_type == .pipe_write) {
        if (fd_table.fds[slot].pipe_idx < 16) {
            _ = vfs.pipeRetain(fd_table.fds[slot].pipe_idx, fd_table.fds[slot].fd_type == .pipe_write);
        }
    }
    return @intCast(slot);
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
            t.fd_table.fds[fd].fd_flags = @truncate(arg);
            return 0;
        },
        F_GETFL => {
            return @intCast(t.fd_table.fds[fd].status_flags);
        },
        F_SETFL => {
            // Only O_NONBLOCK and O_APPEND can be modified via F_SETFL
            const allowed: u32 = O_NONBLOCK | O_APPEND;
            const new_flags: u32 = @as(u32, @truncate(arg)) & allowed;
            // Preserve non-modifiable bits
            t.fd_table.fds[fd].status_flags = (t.fd_table.fds[fd].status_flags & ~allowed) | new_flags;
            return 0;
        },
        F_DUPFD_CLOEXEC => {
            return dupFd(t.fd_table, fd, arg, FD_CLOEXEC);
        },
        F_GETLK, F_SETLK, F_SETLKW => {
            const file_lock = @import("file_lock.zig");
            return file_lock.setLock(fd_num, cmd, arg);
        },
        else => return -22, // EINVAL
    }
}
