//! What open("/proc/self/fd/N") does for a descriptor that has no path to reopen (Linux, measured on the host): a pipe end
//! reopens as the end the new access mode asks for (O_WRONLY the write end, otherwise the read end), a socket is ENXIO, and an
//! anonymous inode (eventfd, epoll, timerfd, inotify, pidfd) is EACCES. Kept free of kernel state for the host tests.

pub const Kind = enum { pipe, socket, anon };

pub const Reopen = union(enum) {
    /// A new descriptor on the same pipe; `write_end` selects the end.
    pipe_end: bool,
    err: i64,
};

pub fn reopenObject(kind: Kind, flags: u32) Reopen {
    return switch (kind) {
        .pipe => .{ .pipe_end = (flags & 0x3) == 1 },
        .socket => .{ .err = -6 }, // ENXIO
        .anon => .{ .err = -13 }, // EACCES
    };
}

const std = @import("std");

test "a pipe reopens as the end the access mode asks for" {
    try std.testing.expectEqual(Reopen{ .pipe_end = false }, reopenObject(.pipe, 0));
    try std.testing.expectEqual(Reopen{ .pipe_end = true }, reopenObject(.pipe, 1));
    try std.testing.expectEqual(Reopen{ .pipe_end = false }, reopenObject(.pipe, 2));
}

test "a socket is ENXIO and an anonymous inode EACCES" {
    try std.testing.expectEqual(Reopen{ .err = -6 }, reopenObject(.socket, 2));
    try std.testing.expectEqual(Reopen{ .err = -13 }, reopenObject(.anon, 2));
}
