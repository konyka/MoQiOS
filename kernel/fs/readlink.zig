/// readlink — symlink target resolution for ext2 symlinks, /proc/self/exe, and /proc/self/fd/N.
///
/// Extracted from syscall_entry.zig (v18.7). ext2 symlink support added v50.0.
const copy = @import("../mm/copy_from_user.zig");
const sched_mod = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const vfs_mod = @import("../fs/vfs.zig");
const ext2_mod = @import("../fs/ext2.zig");
const str = @import("../lib/str.zig");

/// readlink(path_ptr, buf_ptr, bufsiz) -> bytes written or -errno.
pub fn readlink(path_ptr: u64, buf_ptr: u64, bufsiz: u64) i64 {
    if (path_ptr == 0 or path_ptr >= 0x0000_8000_0000_0000 or
        buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000 or bufsiz == 0)
    {
        return -14; // -EFAULT
    }
    var name_buf: [256]u8 = undefined;
    const copied = copy.copyFromUser(name_buf[0..], @ptrFromInt(path_ptr), 255);
    if (copied == 0) return -14;
    name_buf[if (copied < 255) copied else 255] = 0;
    var len: usize = 0;
    while (len < 256 and name_buf[len] != 0) : (len += 1) {}
    const path = name_buf[0..len];

    // /proc/self/exe -> /bin/sh (or current executable)
    if (str.eql(path, "/proc/self/exe")) {
        const target = "/bin/sh";
        const tlen = @min(target.len, @as(usize, @intCast(bufsiz)));
        if (copy.copyToUser(@ptrFromInt(buf_ptr), target[0..tlen], tlen) != tlen) return -14;
        return @intCast(tlen);
    }

    // /proc/self/fd/N -> return the fd target or EINVAL
    if (path.len > 14 and str.startsWith(path, "/proc/self/fd/")) {
        const fd_start = 14;
        var fd_val: u32 = 0;
        var i: usize = fd_start;
        while (i < path.len and path[i] >= '0' and path[i] <= '9') : (i += 1) {
            fd_val = fd_val * 10 + @as(u32, path[i] - '0');
        }
        if (sched_mod.currentTaskIndex()) |idx| {
            if (task_mod.getTask(idx)) |t| {
                if (fd_val < vfs_mod.MAX_FDS and t.fd_table.fds[fd_val].fd_type != .none) {
                    const type_str = switch (t.fd_table.fds[fd_val].fd_type) {
                        .ramdisk_file, .fat32_file, .ext2_file, .tmpfs_file => "file",
                        .pipe_read, .pipe_write => "pipe",
                        .tcp_socket, .udp_socket, .unix_socket => "socket",
                        .epoll => "anon_inode:[eventpoll]",
                        .eventfd => "anon_inode:[eventfd]",
                        .timerfd => "anon_inode:[timerfd]",
                        .proc_file => "file",
                        .special => "file",
                        .devfs => "char",
                        else => "unknown",
                    };
                    const tlen = @min(type_str.len, @as(usize, @intCast(bufsiz)));
                    if (copy.copyToUser(@ptrFromInt(buf_ptr), type_str[0..tlen], tlen) != tlen) return -14;
                    return @intCast(tlen);
                }
            }
        }
        return -22; // -EINVAL
    }

    // v50.0: try ext2 symlink
    if (ext2_mod.readSymlinkByPath(path)) |target| {
        const tlen = @min(target.len, @as(usize, @intCast(bufsiz)));
        if (copy.copyToUser(@ptrFromInt(buf_ptr), target[0..tlen], tlen) != tlen) return -14;
        return @intCast(tlen);
    }

    return -2; // -ENOENT
}
