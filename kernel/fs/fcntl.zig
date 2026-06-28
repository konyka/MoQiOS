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
fn dupFd(fd_table: *vfs.FdTable, fd: u32, min_fd: u32, new_flags: u32) i64 {
    if (min_fd >= vfs.MAX_FDS) return -22; // EINVAL
    // v53.50: Use free_bm bitmap — find first free slot >= min_fd (O(1)).
    // Previously used linear scan (fds[slot].fd_type == .none) which bypassed
    // the bitmap, causing allocFd() to later return the same slot.
    const min_shift: u6 = @intCast(min_fd);
    const mask: u64 = ~((@as(u64, 1) << min_shift) - 1);
    const avail = fd_table.free_bm & mask;
    if (avail == 0) return -24; // EMFILE
    const slot: u6 = @truncate(@ctz(avail));
    fd_table.free_bm &= ~(@as(u64, 1) << slot);
    fd_table.fds[slot] = fd_table.fds[fd];
    fd_table.fds[slot].fd_flags = new_flags;
    // Increment pipe ref count if it's a pipe
    if (fd_table.fds[slot].fd_type == .pipe_read or fd_table.fds[slot].fd_type == .pipe_write) {
        if (fd_table.fds[slot].pipe_idx < 16) {
            vfs.pipes[fd_table.fds[slot].pipe_idx].ref_count += 1;
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
    const fd: u32 = @truncate(fd_num);

    if (fd >= 32) return -9; // EBADF
    if (t.fd_table.fds[fd].fd_type == .none) return -9; // EBADF

    switch (cmd) {
        F_DUPFD => {
            const min_fd: u32 = @truncate(arg);
            return dupFd(&t.fd_table, fd, min_fd, 0);
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
            const min_fd: u32 = @truncate(arg);
            return dupFd(&t.fd_table, fd, min_fd, FD_CLOEXEC);
        },
        F_GETLK, F_SETLK, F_SETLKW => {
            const file_lock = @import("file_lock.zig");
            return file_lock.setLock(fd_num, cmd, arg);
        },
        else => return -22, // EINVAL
    }
}
