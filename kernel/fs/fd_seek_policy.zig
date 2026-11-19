//! Which descriptor kinds lseek() applies to (named by their FdType tag so the rule is host-testable
//! without the arch-bound vfs module).

const std = @import("std");

const UNSEEKABLE = [_][]const u8{
    "pipe_read", "pipe_write", "tcp_socket", "udp_socket", "unix_socket", "raw_socket",
    "epoll",     "eventfd",    "timerfd",    "inotify",    "pidfd",       "devfs_ctrl",
    // stdin/stdout/stderr are the console terminal, which has no position (tty_open: no_llseek).
    "special",
};

/// A devfs node seeks unless it is the console terminal (/dev/tty); /dev/null, /dev/zero and the rest keep noop_llseek.
pub fn devfsSeekable(is_console_tty: bool) bool {
    return !is_console_tty;
}

pub fn seekable(tag: []const u8) bool {
    for (UNSEEKABLE) |u| {
        if (std.mem.eql(u8, u, tag)) return false;
    }
    return true;
}
