//! Pure pidfd rules (Linux kernel/pid.c pidfd_open, kernel/signal.c sys_pidfd_send_signal, fs/pidfs.c pidfd_poll).

/// PIDFD_NONBLOCK (O_NONBLOCK) and PIDFD_THREAD (O_EXCL) are the only pidfd_open flags; anything else is EINVAL.
pub const PIDFD_NONBLOCK: u32 = 0x800;
pub const PIDFD_THREAD: u32 = 0x80;

pub fn flagsValid(flags: u32) bool {
    return flags & ~(PIDFD_NONBLOCK | PIDFD_THREAD) == 0;
}

/// The file status flags a new pidfd carries (F_GETFL reads them; pidfd_open opens with O_RDWR | flags).
pub fn statusFlags(flags: u32) u32 {
    return 2 | (flags & (PIDFD_NONBLOCK | PIDFD_THREAD));
}

/// The special pidfd values of pidfd_send_signal: the calling thread and its thread group.
pub const PIDFD_SELF_THREAD: i32 = -10000;
pub const PIDFD_SELF_THREAD_GROUP: i32 = -10001;

pub const Self_ = enum { none, thread, group };

pub fn selfValue(pidfd: i32) Self_ {
    return switch (pidfd) {
        PIDFD_SELF_THREAD => .thread,
        PIDFD_SELF_THREAD_GROUP => .group,
        else => .none,
    };
}

/// pidfd_poll: POLLIN once the task has exited (a zombie, or gone); POLLHUP too once it is reaped or gone.
pub fn pollEvents(exists: bool, zombie: bool) u32 {
    if (!exists) return 0x1 | 0x10;
    return if (zombie) 0x1 else 0;
}

test "pidfd_open takes PIDFD_NONBLOCK and PIDFD_THREAD only" {
    const std = @import("std");
    try std.testing.expect(flagsValid(0));
    try std.testing.expect(flagsValid(PIDFD_NONBLOCK | PIDFD_THREAD));
    try std.testing.expect(!flagsValid(1));
    try std.testing.expect(!flagsValid(2));
    try std.testing.expect(!flagsValid(0x80000));
    try std.testing.expectEqual(@as(u32, 0x802), statusFlags(PIDFD_NONBLOCK));
    try std.testing.expectEqual(@as(u32, 0x82), statusFlags(PIDFD_THREAD));
    try std.testing.expectEqual(Self_.thread, selfValue(-10000));
    try std.testing.expectEqual(Self_.group, selfValue(-10001));
    try std.testing.expectEqual(Self_.none, selfValue(-10002));
    try std.testing.expectEqual(@as(u32, 0), pollEvents(true, false));
    try std.testing.expectEqual(@as(u32, 1), pollEvents(true, true));
    try std.testing.expectEqual(@as(u32, 0x11), pollEvents(false, false));
}

/// exec_update_lock as a sequence count: execve makes it odd before it closes the close-on-exec descriptors and even again once
/// the new image is committed. pidfd_getfd copies a descriptor only while it is even and keeps the copy only when it did not move.
pub const ExecRead = enum { wait, retry, ok };

pub fn execRead(before: u32, after: u32) ExecRead {
    if (before & 1 != 0) return .wait;
    return if (after == before) .ok else .retry;
}

test "pidfd_getfd waits out an exec and retries a copy an exec overlapped" {
    const std = @import("std");
    try std.testing.expectEqual(ExecRead.wait, execRead(1, 1));
    try std.testing.expectEqual(ExecRead.retry, execRead(2, 3));
    try std.testing.expectEqual(ExecRead.retry, execRead(2, 4));
    try std.testing.expectEqual(ExecRead.ok, execRead(4, 4));
}
