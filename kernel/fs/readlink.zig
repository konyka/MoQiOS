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
    const path_rc = @import("namespace_policy.zig").pathCopyErrno(name_buf[0..], copied, 255);
    if (path_rc != 0) return path_rc; // EFAULT or ENAMETOOLONG
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

    // /proc/self/fd/N -> what descriptor N is open on: the absolute path of a file, "pipe:[n]", "socket:[n]" or "anon_inode:[kind]". A number
    // that is not an open descriptor is ENOENT, as on Linux; a name that is not a number is EINVAL.
    if (path.len > 14 and str.startsWith(path, "/proc/self/fd/")) {
        // Linux: only an empty name is EINVAL (the link does not exist as a symlink); every other name that is not an open descriptor, a
        // non-number or a number too large for an int included, is ENOENT.
        const fd_val = readlink_policy.parseFdPrefix(path[14..]) orelse return -2;
        if (path[14] < '0' or path[14] > '9') return -2;
        const idx = sched_mod.currentTaskIndex() orelse return -22;
        const t = task_mod.getTask(idx) orelse return -22;
        if (fd_val >= vfs_mod.MAX_FDS or t.fd_table.fds[fd_val].fd_type == .none) return -2; // ENOENT
        const d = &t.fd_table.fds[fd_val];
        var text: [256]u8 = undefined;
        var tn: usize = 0;
        switch (d.fd_type) {
            .tmpfs_file => switch (@import("tmpfs.zig").tmpfsEntryPath(d.tmpfs_idx, &text)) {
                .ok => |p| tn = p.len,
                .err => |e| return e,
            },
            .ext2_file => {
                const stored = ext2_mod.getOpenFilePath(d.ext2_file_idx) orelse return -2;
                var w: usize = 0;
                if (stored[0] != '/') {
                    text[0] = '/';
                    w = 1;
                }
                if (w + stored.len > text.len) return -36;
                @memcpy(text[w..][0..stored.len], stored);
                tn = w + stored.len;
            },
            .pipe_read, .pipe_write => tn = readlink_policy.numberedLink("pipe", d.pipe_idx, &text) orelse return -36,
            .tcp_socket => tn = readlink_policy.numberedLink("socket", d.tcb_idx, &text) orelse return -36,
            .udp_socket => tn = readlink_policy.numberedLink("socket", d.udp_port, &text) orelse return -36,
            .unix_socket => tn = readlink_policy.numberedLink("socket", d.unix_sock_idx, &text) orelse return -36,
            .raw_socket => tn = readlink_policy.numberedLink("socket", fd_val, &text) orelse return -36,
            .epoll => tn = readlink_policy.anonLink("anon_inode:[eventpoll]", &text) orelse return -36,
            .eventfd => tn = readlink_policy.anonLink("anon_inode:[eventfd]", &text) orelse return -36,
            .timerfd => tn = readlink_policy.anonLink("anon_inode:[timerfd]", &text) orelse return -36,
            .inotify => tn = readlink_policy.anonLink("anon_inode:[inotify]", &text) orelse return -36,
            .pidfd => tn = readlink_policy.anonLink("anon_inode:[pidfd]", &text) orelse return -36,
            .devfs => {
                const dev = @import("devfs.zig");
                const prefix = "/dev";
                @memcpy(text[0..prefix.len], prefix);
                tn = prefix.len;
                if (d.devfs_idx != dev.DIR_IDX) {
                    const nm = dev.nameAt(d.devfs_idx) orelse return -2;
                    if (tn + 1 + nm.len > text.len) return -36;
                    text[tn] = '/';
                    @memcpy(text[tn + 1 ..][0..nm.len], nm);
                    tn += 1 + nm.len;
                }
            },
            else => tn = readlink_policy.anonLink("file", &text) orelse return -36,
        }
        const tlen = @min(tn, @as(usize, @intCast(bufsiz)));
        if (copy.copyToUser(@ptrFromInt(buf_ptr), text[0..tlen], tlen) != tlen) return -14;
        return @intCast(tlen);
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
    switch (ext2_mod.readlinkPath(path, &target_buf)) {
        .target => |target| {
            const tlen = @min(target.len, @as(usize, @intCast(bufsiz)));
            if (copy.copyToUser(@ptrFromInt(buf_ptr), target[0..tlen], tlen) != tlen) return -14;
            return @intCast(tlen);
        },
        .not_symlink => return -22, // EINVAL: it exists but is not a symbolic link
        .missing, .not_ext2 => {},
    }
    // tmpfs has no symbolic links: an existing entry is EINVAL, a missing one ENOENT.
    if (path.len >= 4 and path[0] == '/' and path[1] == 't' and path[2] == 'm' and path[3] == 'p' and (path.len == 4 or path[4] == '/')) {
        if (@import("tmpfs.zig").tmpfsMetadataByPath(path) != null) return -22;
    }

    return -2; // -ENOENT
}
