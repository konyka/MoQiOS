//! What descriptor N of a task is open on, as the text /proc/self/fd/N reads back as: the absolute path of a file, "pipe:[n]", "socket:[n]" or
//! "anon_inode:[kind]". Shared by readlink and by open("/proc/self/fd/N").

const std = @import("std");
const task_mod = @import("../proc/task.zig");
const vfs_mod = @import("vfs.zig");
const ext2_mod = @import("ext2.zig");
const readlink_policy = @import("readlink_policy.zig");

pub const Result = union(enum) { ok: usize, err: i64 };

/// Write the target of descriptor `fd_val` of task `t` into `text` and return its length, or a negative errno: ENOENT for a number that is not
/// an open descriptor (or a file that is gone), ENAMETOOLONG when the text does not fit.
pub fn describe(t: *task_mod.Task, fd_val: u32, text: *[256]u8) Result {
    if (fd_val >= vfs_mod.MAX_FDS or t.fd_table.fds[fd_val].fd_type == .none) return .{ .err = -2 };
    const d = &t.fd_table.fds[fd_val];
    switch (d.fd_type) {
        .tmpfs_file => switch (@import("tmpfs.zig").tmpfsEntryPath(d.tmpfs_idx, text)) {
            .ok => |p| return .{ .ok = p.len },
            .err => |e| return .{ .err = e },
        },
        .ext2_file => {
            const stored = ext2_mod.getOpenFilePath(d.ext2_file_idx) orelse return .{ .err = -2 };
            var w: usize = 0;
            if (stored[0] != '/') {
                text[0] = '/';
                w = 1;
            }
            if (w + stored.len > text.len) return .{ .err = -36 };
            @memcpy(text[w..][0..stored.len], stored);
            return .{ .ok = w + stored.len };
        },
        .fat32_file => {
            // A FAT32 file is an entry of the root directory.
            const nm = @import("fat32.zig").getFileName(d.fat32_file_idx) orelse return .{ .err = -2 };
            if (1 + nm.len > text.len) return .{ .err = -36 };
            text[0] = '/';
            @memcpy(text[1..][0..nm.len], nm);
            return .{ .ok = 1 + nm.len };
        },
        .pipe_read, .pipe_write => return wrap(readlink_policy.numberedLink("pipe", d.pipe_idx, text)),
        .tcp_socket => return wrap(readlink_policy.numberedLink("socket", d.tcb_idx, text)),
        .udp_socket => return wrap(readlink_policy.numberedLink("socket", d.udp_port, text)),
        .unix_socket => return wrap(readlink_policy.numberedLink("socket", d.unix_sock_idx, text)),
        .raw_socket => return wrap(readlink_policy.numberedLink("socket", fd_val, text)),
        .epoll => return wrap(readlink_policy.anonLink("anon_inode:[eventpoll]", text)),
        .eventfd => return wrap(readlink_policy.anonLink("anon_inode:[eventfd]", text)),
        .timerfd => return wrap(readlink_policy.anonLink("anon_inode:[timerfd]", text)),
        .inotify => return wrap(readlink_policy.anonLink("anon_inode:[inotify]", text)),
        .pidfd => return wrap(readlink_policy.anonLink("anon_inode:[pidfd]", text)),
        .devfs => {
            const dev = @import("devfs.zig");
            const prefix = "/dev";
            @memcpy(text[0..prefix.len], prefix);
            var n: usize = prefix.len;
            if (d.devfs_idx != dev.DIR_IDX) {
                const nm = dev.nameAt(d.devfs_idx) orelse return .{ .err = -2 };
                if (n + 1 + nm.len > text.len) return .{ .err = -36 };
                text[n] = '/';
                @memcpy(text[n + 1 ..][0..nm.len], nm);
                n += 1 + nm.len;
            }
            return .{ .ok = n };
        },
        else => return wrap(readlink_policy.anonLink("file", text)),
    }
}

fn wrap(n: ?usize) Result {
    return if (n) |len| .{ .ok = len } else .{ .err = -36 };
}

pub const Resolved = union(enum) {
    /// Not a /proc/self/fd/N name: use the name as given.
    same,
    /// The path descriptor N reads back as, inside the caller's buffer.
    path: []const u8,
    err: i64,
};

/// If `name` is "/proc/self/fd/N", the path descriptor N of `t` stands for (so open and stat act on the file it names, as Linux's magic link
/// does); otherwise `.same`. A name that is not a number is ENOENT, and a descriptor that has no path (a pipe, a socket, an event object)
/// is ENXIO: it cannot be opened or described through this name here.
pub fn resolveMagicLink(t: *task_mod.Task, name: []const u8, buf: *[256]u8) Resolved {
    const prefix = "/proc/self/fd/";
    if (name.len <= prefix.len or !std.mem.startsWith(u8, name, prefix)) return .same;
    const rest = name[prefix.len..];
    var fdn: u32 = 0;
    var digits: usize = 0;
    while (digits < rest.len and rest[digits] >= '0' and rest[digits] <= '9' and digits < 9) : (digits += 1) {
        fdn = fdn * 10 + (rest[digits] - '0');
    }
    if (digits == 0 or digits != rest.len) return .{ .err = -2 };
    switch (describe(t, fdn, buf)) {
        .err => |e| return .{ .err = e },
        .ok => |n| {
            if (n == 0 or buf[0] != '/') return .{ .err = -6 };
            return .{ .path = buf[0..n] };
        },
    }
}
