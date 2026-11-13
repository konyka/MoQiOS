//! Pure contracts for POSIX MQ descriptor validation.

pub const O_RDONLY: u32 = 0;
pub const O_WRONLY: u32 = 1;
pub const O_RDWR: u32 = 2;
pub const O_NONBLOCK: u32 = 0o4000;
pub const O_CLOEXEC: u32 = 0o2000000;
pub const SIGEV_SIGNAL: u32 = 0;
pub const SIGEV_NONE: u32 = 1;
pub const SIGEV_THREAD: u32 = 2;
pub const ACCESS_MASK: u32 = 3;
pub const O_ACCMODE: u32 = ACCESS_MASK;
pub const O_CREAT: u32 = 0o100;
pub const O_EXCL: u32 = 0o200;
pub const KNOWN_FLAGS: u32 = ACCESS_MASK | O_NONBLOCK | O_CLOEXEC | 0o100 | 0o200;

/// Per-task descriptor slots. A descriptor value is `DESCRIPTOR_BASE + slot`,
/// which keeps MQ descriptors disjoint from the fd table numbering.
pub const MAX_DESCRIPTORS: u32 = 32;
pub const DESCRIPTOR_BASE: u32 = 300;

pub const Operation = enum { send, receive };

pub fn tokenValue(slot: u32) u32 {
    return DESCRIPTOR_BASE + slot;
}

pub fn decodeToken(mqd: u32) ?u32 {
    if (mqd < DESCRIPTOR_BASE or mqd - DESCRIPTOR_BASE >= MAX_DESCRIPTORS) return null;
    return mqd - DESCRIPTOR_BASE;
}

pub fn flagsValid(flags: u32) bool {
    return (flags & ~KNOWN_FLAGS) == 0 and (flags & ACCESS_MASK) != 3;
}

pub fn canSend(access: u32) bool {
    return access == O_WRONLY or access == O_RDWR;
}

pub fn canReceive(access: u32) bool {
    return access == O_RDONLY or access == O_RDWR;
}

pub fn accessAllows(access: u32, operation: Operation) bool {
    return switch (operation) {
        .send => canSend(access),
        .receive => canReceive(access),
    };
}

pub fn statusFlags(flags: u32) u32 {
    return flags & O_NONBLOCK;
}

pub fn survivesExec(cloexec: bool) bool {
    return !cloexec;
}

/// SIGEV_THREAD needs a netlink socket this kernel has no path for, so it stays rejected. SIGEV_NONE is a real registration
/// that simply sends nothing (Linux do_mq_notify).
pub fn sigevNotifyValid(kind: u32) bool {
    return kind == SIGEV_SIGNAL or kind == SIGEV_NONE;
}

/// Linux do_mq_notify: a NULL notification removes the registration only when the caller owns it, and returns success either way.
/// Replacing someone else's registration is EBUSY.
pub fn notifyUnregister(caller_owns: bool) enum { removed, kept } {
    return if (caller_owns) .removed else .kept;
}

/// Linux __do_notify: SIGEV_NONE sends nothing, and SIGEV_SIGNAL with signo 0 is accepted (valid_signal allows 0) but skipped at
/// delivery. Either way the first message consumes the registration.
pub fn notifySends(kind: u32, signo: i32) bool {
    return kind == SIGEV_SIGNAL and signo > 0;
}

test "MQ descriptor policy isolates access and exec flags" {
    const std = @import("std");
    try std.testing.expect(flagsValid(O_RDONLY | O_NONBLOCK));
    try std.testing.expect(!flagsValid(3));
    try std.testing.expect(!flagsValid(0x400));
    try std.testing.expect(canSend(O_WRONLY));
    try std.testing.expect(!canSend(O_RDONLY));
    try std.testing.expect(canReceive(O_RDONLY));
    try std.testing.expect(!canReceive(O_WRONLY));
    try std.testing.expect(survivesExec(false));
    try std.testing.expect(!survivesExec(true));
    try std.testing.expect(sigevNotifyValid(SIGEV_SIGNAL));
    try std.testing.expect(sigevNotifyValid(SIGEV_NONE));
    try std.testing.expect(!sigevNotifyValid(SIGEV_THREAD));
    try std.testing.expect(notifyUnregister(true) == .removed);
    try std.testing.expect(notifyUnregister(false) == .kept);
    try std.testing.expect(notifySends(SIGEV_SIGNAL, 10));
    try std.testing.expect(!notifySends(SIGEV_SIGNAL, 0));
    try std.testing.expect(!notifySends(SIGEV_NONE, 10));
}
