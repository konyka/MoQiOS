/// readlink — symlink target resolution for ext2 symlinks, /proc/self/exe, and /proc/self/fd/N.
///
/// Extracted from syscall_entry.zig (v18.7). ext2 symlink support added v50.0.
const copy = @import("../mm/copy_from_user.zig");
const sched_mod = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const vfs_mod = @import("../fs/vfs.zig");
const ext2_mod = @import("../fs/ext2.zig");
const str = @import("../lib/str.zig");
const readlink_policy = @import("readlink_policy.zig");
const at_path = @import("at_path.zig");

/// readlink(path_ptr, buf_ptr, bufsiz) -> bytes written or -errno.
pub fn readlink(path_ptr: u64, buf_ptr: u64, bufsiz: u64) i64 {
    return readlinkAt(at_path.AT_FDCWD, path_ptr, buf_ptr, bufsiz);
}

/// readlinkat(dirfd, path, buf, bufsiz).
pub fn readlinkAt(dirfd: i64, path_ptr: u64, buf_ptr: u64, bufsiz: u64) i64 {
    if (path_ptr == 0 or path_ptr >= 0x0000_8000_0000_0000 or
        buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000 or bufsiz == 0)
    {
        return -14; // -EFAULT
    }
    var name_buf: [256]u8 = undefined;
    const copied = copy.copyPathFromUser(name_buf[0..], path_ptr, 255);
    if (copied == 0) return -14;
    name_buf[if (copied < 255) copied else 255] = 0;
    var len: usize = 0;
    while (len < 256 and name_buf[len] != 0) : (len += 1) {}
    var path: []const u8 = name_buf[0..len];
    var joined: [256]u8 = undefined;
    if (sched_mod.currentTask()) |ct| {
        switch (at_path.resolve(ct, dirfd, path, &joined)) {
            .keep => {},
            .path => |p| path = p,
            .err => |e| return e,
        }
    }

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
        const fd_val = readlink_policy.parseFdPrefix(path[fd_start..]) orelse return -22;
        if (sched_mod.currentTaskIndex()) |idx| {
            if (task_mod.getTask(idx)) |t| {
                if (fd_val < vfs_mod.MAX_FDS and t.fd_table.fds[fd_val].fd_type != .none) {
                    const type_str = switch (t.fd_table.fds[fd_val].fd_type) {
                        .ramdisk_file, .fat32_file, .ext2_file, .tmpfs_file, .rofs_file => "file",
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

    // ext4 / NTFS symlink: resolve the path without following the last component.
    {
        var norm: [256]u8 = undefined;
        if (vfs_mod.normalizeAbs(path, &norm)) |abs| {
            if (vfs_mod.rofsRoute(abs)) |route| {
                const rofs = @import("rofs.zig");
                const cur_task = sched_mod.currentTask();
                const creds: rofs.Creds = if (cur_task) |ct| .{ .euid = ct.euid, .egid = ct.egid, .cap_dac_override = ct.effective_caps.cap_dac_override, .groups = ct.groups[0..ct.ngroups] } else .{ .euid = 0, .egid = 0, .cap_dac_override = true };
                switch (rofs.open(route.slot, route.rest, false, creds)) {
                    .err => |e| return e,
                    .ok => |o| {
                        if (o.kind != .symlink) return -22; // EINVAL: not a symlink
                        var tmp: [512]u8 = undefined;
                        const n = rofs.readLink(route.slot, o.gen, o.ref, &tmp);
                        if (n < 0) return n;
                        const tlen = @min(@as(usize, @intCast(n)), @as(usize, @intCast(bufsiz)));
                        if (copy.copyToUser(@ptrFromInt(buf_ptr), tmp[0..tlen], tlen) != tlen) return -14;
                        return @intCast(tlen);
                    },
                }
            }
        }
    }

    // v50.0: try ext2 symlink
    var target_buf: [256]u8 = undefined;
    if (ext2_mod.readSymlinkByPath(path, &target_buf)) |target| {
        const tlen = @min(target.len, @as(usize, @intCast(bufsiz)));
        if (copy.copyToUser(@ptrFromInt(buf_ptr), target[0..tlen], tlen) != tlen) return -14;
        return @intCast(tlen);
    }

    return -2; // -ENOENT
}
