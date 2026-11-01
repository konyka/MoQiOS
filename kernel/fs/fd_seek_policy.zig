//! Which descriptor kinds lseek() applies to (named by their FdType tag so the rule is host-testable
//! without the arch-bound vfs module).

const std = @import("std");

const UNSEEKABLE = [_][]const u8{
    "pipe_read", "pipe_write", "tcp_socket", "udp_socket", "unix_socket", "raw_socket",
    "epoll",     "eventfd",    "timerfd",    "inotify",    "pidfd",       "devfs_ctrl",
};

pub fn seekable(tag: []const u8) bool {
    for (UNSEEKABLE) |u| {
        if (std.mem.eql(u8, u, tag)) return false;
    }
    return true;
}
