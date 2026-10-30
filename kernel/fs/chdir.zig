/// chdir / fchdir — change working directory by path or fd.
///
/// Extracted from syscall_entry.zig (v18.8).
const copy = @import("../mm/copy_from_user.zig");
const sched_mod = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const vfs_mod = @import("../fs/vfs.zig");
const chdir_policy = @import("chdir_policy.zig");
const at_path = @import("at_path.zig");

/// chdir(path_ptr) -> 0 or -errno.
pub fn chdir(path_ptr: u64) i64 {
    if (path_ptr == 0 or path_ptr >= 0x0000_8000_0000_0000) return -1;

    var path_buf: [256]u8 = undefined;
    const copied = copy.copyPathFromUser(path_buf[0..], path_ptr, 255);
    const path_rc = @import("namespace_policy.zig").pathCopyErrno(path_buf[0..], copied, 255);
    if (path_rc != 0) return path_rc; // EFAULT or ENAMETOOLONG
    path_buf[if (copied < 255) copied else 255] = 0;
    var path_len: usize = 0;
    while (path_len < copied and path_buf[path_len] != 0) : (path_len += 1) {}

    if (path_len == 0 or path_len >= 256) return -1;

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    // Resolve path (absolute used as-is, relative joined onto cwd) and
    // normalize "." / ".." / slashes. The result must fit alongside its NUL
    // terminator in Task.cwd — reject instead of truncating or writing the
    // NUL one byte past the array.
    var out_buf: [256]u8 = undefined;
    const write_pos = chdir_policy.resolve(cur.cwd[0..cur.cwd_len], path_buf[0..path_len], &out_buf) catch return -36; // ENAMETOOLONG

    const rc = checkDirectory(cur, out_buf[0..write_pos]);
    if (rc != 0) return rc;

    @memcpy(cur.cwd[0..write_pos], out_buf[0..write_pos]);
    cur.cwd[write_pos] = 0;
    cur.cwd_len = @intCast(write_pos);
    return 0;
}

/// The target of chdir must exist, be a directory and be searchable, on
/// whichever filesystem holds it. "/" and the directories leading to a mount
/// point always qualify; /proc is not checked (it has no directory model).
fn checkDirectory(cur: *task_mod.Task, path: []const u8) i64 {
    if (path.len == 1 and path[0] == '/') return 0;
    // A target inside a mounted ext4/NTFS volume.
    if (vfs_mod.rofsRoute(path)) |route| {
        switch (@import("rofs.zig").open(route.slot, route.rest, true, .{ .euid = cur.euid, .egid = cur.egid, .cap_dac_override = cur.effective_caps.cap_dac_override, .groups = cur.groups[0..cur.ngroups] })) {
            .err => |e| return e,
            .ok => |o| return if (o.kind != .directory) -20 else 0, // ENOTDIR
        }
    }
    if (vfs_mod.isMountAncestor(path)) return 0;
    const policy = @import("at_join_policy.zig");
    const tree = path[1..];
    if (policy.namesRootTree(tree)) {
        if (tree[0] == 'p') return 0; // /proc
        if (tree[0] == 'd') return if (tree.len == 3) 0 else if (@import("devfs.zig").lookup(tree[4..]) != null) -20 else -2;
        return tmpfsDirectory(cur, path);
    }
    const ext2 = @import("ext2.zig");
    if (!ext2.isActive()) return 0;
    return ext2.dirCheckAs(path, .{ .euid = cur.euid, .egid = cur.egid, .cap_dac_override = cur.effective_caps.cap_dac_override, .groups = cur.groups[0..cur.ngroups] });
}

fn tmpfsDirectory(cur: *task_mod.Task, path: []const u8) i64 {
    const tmpfs = @import("tmpfs.zig");
    const r = tmpfs.tmpfsOpenAuthorized(path, false, false, cur.euid, cur.egid, cur.effective_caps, 0, null, cur.umask_val);
    if (r < 0) return if (r == -13) -13 else -2;
    const idx: u8 = @intCast(r);
    defer tmpfs.tmpfsClose(idx);
    const meta = tmpfs.tmpfsGetMetadata(idx) orelse return -2;
    if (!meta.is_dir) return -20;
    const dac = @import("dac.zig");
    if (!dac.allows(.{ .mode = meta.mode, .uid = meta.uid, .gid = meta.gid }, .{ .euid = cur.euid, .egid = cur.egid, .cap_dac_override = cur.effective_caps.cap_dac_override, .groups = cur.groups[0..cur.ngroups] }, dac.Access.search)) return -13;
    return 0;
}

/// fchdir(fd) -> 0 or -errno. A descriptor naming a directory (on a volume,
/// the ext2 root disk, tmpfs or /dev) makes it the working directory;
/// anything else is ENOTDIR.
pub fn fchdir(fd: u32) i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;
    if (fd >= vfs_mod.MAX_FDS or cur.fd_table.fds[fd].fd_type == .none) {
        return -9; // -EBADF
    }
    var pbuf: [256]u8 = undefined;
    const path = switch (at_path.dirFdBase(cur, fd, &pbuf)) {
        .ok => |p| p,
        .err => |e| return e,
    };
    if (path.len == 0 or path.len >= cur.cwd.len) return -36;
    @memcpy(cur.cwd[0..path.len], path);
    cur.cwd[path.len] = 0;
    cur.cwd_len = @intCast(path.len);
    return 0;
}
