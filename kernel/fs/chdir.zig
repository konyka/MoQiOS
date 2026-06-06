/// chdir / fchdir — change working directory by path or fd.
///
/// Extracted from syscall_entry.zig (v18.8).
const copy = @import("../mm/copy_from_user.zig");
const sched_mod = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const vfs_mod = @import("../fs/vfs.zig");

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

    // Resolve path: if absolute, use as-is; if relative, append to cwd
    var resolved: [256]u8 = undefined;
    var resolved_len: usize = 0;

    if (path_buf[0] == '/') {
        @memcpy(resolved[0..path_len], path_buf[0..path_len]);
        resolved_len = path_len;
    } else {
        if (cur.cwd_len > 0) {
            @memcpy(resolved[0..cur.cwd_len], cur.cwd[0..cur.cwd_len]);
            resolved_len = cur.cwd_len;
        }
        if (resolved_len > 0 and resolved[resolved_len - 1] != '/') {
            if (resolved_len < 255) {
                resolved[resolved_len] = '/';
                resolved_len += 1;
            }
        }
        const to_copy = @min(path_len, 256 - resolved_len);
        @memcpy(resolved[resolved_len .. resolved_len + to_copy], path_buf[0..to_copy]);
        resolved_len += to_copy;
    }

    // Normalize: remove trailing slash (except root)
    while (resolved_len > 1 and resolved[resolved_len - 1] == '/') {
        resolved_len -= 1;
    }

    // Handle ".." components
    var pos: usize = 0;
    var write_pos: usize = 0;
    var out_buf: [256]u8 = undefined;

    while (pos < resolved_len) {
        while (pos < resolved_len and resolved[pos] == '/') : (pos += 1) {}
        if (pos >= resolved_len) break;
        const start = pos;
        while (pos < resolved_len and resolved[pos] != '/') : (pos += 1) {}
        const component = resolved[start..pos];

        if (component.len == 1 and component[0] == '.') {
            continue;
        } else if (component.len == 2 and component[0] == '.' and component[1] == '.') {
            if (write_pos > 1) {
                write_pos -= 1;
                while (write_pos > 0 and out_buf[write_pos - 1] != '/') : (write_pos -= 1) {}
            }
        } else {
            if (write_pos > 0 and out_buf[write_pos - 1] != '/') {
                out_buf[write_pos] = '/';
                write_pos += 1;
            } else if (write_pos == 0) {
                out_buf[write_pos] = '/';
                write_pos += 1;
            }
            @memcpy(out_buf[write_pos .. write_pos + component.len], component);
            write_pos += component.len;
        }
    }

    if (write_pos == 0) {
        out_buf[0] = '/';
        write_pos = 1;
    }

    @memcpy(cur.cwd[0..write_pos], out_buf[0..write_pos]);
    cur.cwd[write_pos] = 0;
    cur.cwd_len = @intCast(write_pos);
    return 0;
}

/// fchdir(fd) -> 0 or -errno.
pub fn fchdir(fd: u32) i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;
    if (fd >= vfs_mod.MAX_FDS or cur.fd_table.fds[fd].fd_type == .none) {
        return -9; // -EBADF
    }
    return 0;
}
