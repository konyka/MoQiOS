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
    const copied = copy.copyFromUser(path_buf[0..], @ptrFromInt(path_ptr), 255);
    if (copied == 0) return -1;
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

    // A target inside a mounted ext4/NTFS volume must exist and be a directory.
    if (vfs_mod.rofsRoute(out_buf[0..write_pos])) |route| {
        switch (@import("rofs.zig").open(route.slot, route.rest, true, .{ .euid = cur.euid, .egid = cur.egid, .cap_dac_override = cur.effective_caps.cap_dac_override })) {
            .err => |e| return e,
            .ok => |o| if (o.kind != .directory) return -20, // ENOTDIR
        }
    }

    @memcpy(cur.cwd[0..write_pos], out_buf[0..write_pos]);
    cur.cwd[write_pos] = 0;
    cur.cwd_len = @intCast(write_pos);
    return 0;
}

/// fchdir(fd) -> 0 or -errno. A descriptor naming a directory on a mounted
/// volume changes the working directory to it; a regular file is ENOTDIR.
/// For other filesystems the descriptor is only validated (unchanged).
pub fn fchdir(fd: u32) i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;
    if (fd >= vfs_mod.MAX_FDS or cur.fd_table.fds[fd].fd_type == .none) {
        return -9; // -EBADF
    }
    if (cur.fd_table.fds[fd].fd_type != .rofs_file) return 0;

    var pbuf: [256]u8 = undefined;
    const path = switch (at_path.dirFdPath(cur, fd, &pbuf)) {
        .ok => |p| p,
        .err => |e| return e,
    };
    // The mount target alone is what dirFdPath returns for the volume root.
    if (path.len == 0 or path.len >= cur.cwd.len) return -36;
    @memcpy(cur.cwd[0..path.len], path);
    cur.cwd[path.len] = 0;
    cur.cwd_len = @intCast(path.len);
    return 0;
}
