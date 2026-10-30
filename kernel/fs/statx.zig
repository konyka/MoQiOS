/// statx — extended file stat (Linux syscall #332).
///
/// Extracted from syscall_entry.zig (v18.8).
const copy = @import("../mm/copy_from_user.zig");
const sched_mod = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const bo = @import("../lib/byte_order.zig");
const at_path = @import("at_path.zig");

/// statx(dirfd, pathname_ptr, flags, mask, statxbuf_ptr) -> 0 or -errno.
/// AT_EMPTY_PATH with an empty name describes `dirfd` itself. Timestamps and
/// block counts are reported only for filesystems that keep them (ext2, the
/// read-only volumes, FAT32's write time); the mask says which fields are valid.
pub fn statx(dirfd: i64, pathname_ptr: u64, flags: u32, mask: u32, statxbuf_ptr: u64) i64 {
    const si = @import("stat_info.zig");
    // Validate the full destination before opening a temporary fd; this keeps
    // bad output pointers from causing needless fd-table mutation.
    if (!copy.validateUserBufferWritable(statxbuf_ptr, 144)) return -14; // EFAULT
    const args = si.checkStatxArgs(flags, mask);
    if (args.err != 0) return args.err;

    var name_buf: [256]u8 = undefined;
    if (pathname_ptr == 0 or pathname_ptr >= 0x0000_8000_0000_0000) return -14; // EFAULT
    const copied = copy.copyPathFromUser(&name_buf, pathname_ptr, 255);
    if (copied == 0) return -14;
    var len: usize = 0;
    while (len < copied and name_buf[len] != 0) : (len += 1) {}
    const name = name_buf[0..len];

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    var out: [144]u8 = undefined;
    // AT_EMPTY_PATH with an empty name: stat the descriptor itself.
    if (len == 0) {
        if (!args.empty_path) return -2;
        if (dirfd < 0 or dirfd >= @import("vfs.zig").MAX_FDS) return -9;
        const d = &cur.fd_table.fds[@intCast(dirfd)];
        if (d.fd_type == .none) return -9;
        const common = describe(d, @intCast(dirfd)) orelse return -2;
        si.packStatx(&out, common);
        return if (copy.copyToUser(@ptrFromInt(statxbuf_ptr), &out, out.len) != out.len) -14 else 0;
    }

    var joined: [256]u8 = undefined;
    const use_name = switch (at_path.resolve(cur, dirfd, name, &joined)) {
        .keep => name,
        .path => |p| p,
        .err => |e| return e,
    };
    // AT_SYMLINK_NOFOLLOW on an ext2 symlink: describe the link inode itself
    // (a normal open would follow it).
    if (!args.follow) {
        const ext2 = @import("ext2.zig");
        if (ext2.isActive() and !isSpecialTree(use_name)) {
            if (ext2.statPathNoFollow(use_name, .{ .euid = cur.euid, .egid = cur.egid, .cap_dac_override = cur.effective_caps.cap_dac_override, .groups = cur.groups[0..cur.ngroups] })) |r| {
                switch (r) {
                    .ok => |info| {
                        si.packStatx(&out, .{ .mode = info.mode, .nlink = info.nlink, .uid = info.uid, .gid = info.gid, .ino = info.ino, .size = info.size, .blocks = info.blocks, .times = .{ .atime = info.atime, .mtime = info.mtime, .ctime = info.ctime } });
                        return if (copy.copyToUser(@ptrFromInt(statxbuf_ptr), &out, out.len) != out.len) -14 else 0;
                    },
                    .err => |e| return e,
                }
            }
        }
    }
    const open_flags: u32 = 0;
    const fd_result = cur.fd_table.openWithCredentials(use_name, open_flags, cur.euid, cur.egid, cur.effective_caps);
    if (fd_result < 0) {
        // A directory on the path that denies search is EACCES, not ENOENT.
        return if (fd_result == -13) -13 else -2;
    }
    const fd: u32 = @intCast(fd_result);
    const common = describe(&cur.fd_table.fds[fd], fd);
    _ = cur.fd_table.close(fd);
    si.packStatx(&out, common orelse return -2);
    return if (copy.copyToUser(@ptrFromInt(statxbuf_ptr), &out, out.len) != out.len) -14 else 0;
}

/// /tmp, /dev, /proc and mounted volumes are not ext2 paths.
fn isSpecialTree(name: []const u8) bool {
    const policy = @import("at_join_policy.zig");
    const rel = if (name.len > 0 and name[0] == '/') name[1..] else name;
    if (policy.namesRootTree(rel)) return true;
    var norm: [256]u8 = undefined;
    const vfs = @import("vfs.zig");
    const abs = vfs.normalizeAbs(if (name.len > 0 and name[0] == '/') name else "/", &norm) orelse return false;
    return vfs.rofsRoute(abs) != null;
}

fn describe(d: *const @import("vfs.zig").FileDescriptor, fd: u32) ?@import("stat_info.zig").Common {
    const si = @import("stat_info.zig");
    var c: si.Common = .{ .mode = if (d.fd_type == .tcp_socket) 0o140777 else 0o100644, .ino = fd, .size = d.file_size };
    switch (d.fd_type) {
        .tmpfs_file => {
            const m = @import("tmpfs.zig").tmpfsGetMetadata(@intCast(d.tmpfs_idx)) orelse return null;
            c.uid = m.uid;
            c.gid = m.gid;
            c.mode = (if (m.is_dir) @as(u32, 0o040000) else 0o100000) | (m.mode & 0o7777); // incl. setuid/setgid/sticky
        },
        .rofs_file => switch (@import("rofs.zig").statRef(d.rofs_mount, d.rofs_gen, d.rofs_ref)) {
            .ok => |o| {
                c = .{ .mode = o.stat.mode, .nlink = o.stat.nlink, .uid = o.stat.uid, .gid = o.stat.gid, .ino = o.stat.ino, .size = o.stat.size, .blocks = o.stat.blocks, .times = .{ .atime = o.stat.atime, .mtime = o.stat.mtime, .ctime = o.stat.ctime } };
            },
            .err => return null,
        },
        .ext2_file => {
            var info: si.StatInfo = .{};
            if (!@import("ext2.zig").statInode(d.ext2_file_idx, &info)) return null;
            c = .{ .mode = info.mode, .nlink = info.nlink, .uid = info.uid, .gid = info.gid, .ino = info.ino, .size = @max(info.size, d.file_size), .blocks = info.blocks, .times = .{ .atime = info.atime, .mtime = info.mtime, .ctime = info.ctime } };
        },
        .fat32_file => {
            const mt = @import("fat32.zig").getMtime(d.fat32_file_idx);
            c.blocks = (d.file_size + 511) / 512;
            c.times = .{ .atime = mt, .mtime = mt, .ctime = mt }; // FAT keeps one write time
        },
        else => {},
    }
    return c;
}
