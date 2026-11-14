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

/// Linux mqueue FILENT_SIZE: the size an mq descriptor reports (fstat, SEEK_END) for its status line.
pub const FILENT_SIZE: u32 = 80;
/// poll bits (POLLIN, POLLOUT).
pub const POLLIN: u32 = 0x1;
pub const POLLOUT: u32 = 0x4;

pub const Operation = enum { send, receive };

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

/// F_GETFL of an mq descriptor (Linux f_flags as do_mq_open set them): the access mode, the O_NONBLOCK in force (F_SETFL and
/// mq_setattr change the same bit) and the O_CLOEXEC given at open. O_CREAT and O_EXCL are not kept.
pub fn reportedFlags(access: u32, status_flags: u32, opened_cloexec: bool) u32 {
    return (access & O_ACCMODE) | (status_flags & O_NONBLOCK) | (if (opened_cloexec) O_CLOEXEC else 0);
}

/// Linux mqueue_poll_file: readable while a message is queued, writable while there is room. The access mode does not matter.
pub fn pollEvents(count: u32, max_msg: u32) u32 {
    var ev: u32 = 0;
    if (count > 0) ev |= POLLIN;
    if (count < max_msg) ev |= POLLOUT;
    return ev;
}

/// The line read() returns from an mq descriptor (Linux mqueue_read_file): QSIZE is the byte total of the queued messages; NOTIFY,
/// SIGNO and NOTIFY_PID describe the mq_notify registration and are 0 without one (SIGNO only for SIGEV_SIGNAL).
pub fn statusLine(buf: *[FILENT_SIZE]u8, qsize: u64, registered: bool, kind: u32, signo: u32, owner_tgid: u32) []const u8 {
    const std = @import("std");
    const notify: u32 = if (registered) kind else 0;
    const sig: u32 = if (registered and kind == SIGEV_SIGNAL) signo else 0;
    const pid: u32 = if (registered) owner_tgid else 0;
    return std.fmt.bufPrint(buf, "QSIZE:{d: <10} NOTIFY:{d: <5} SIGNO:{d: <5} NOTIFY_PID:{d: <6}\n", .{ qsize, notify, sig, pid }) catch buf[0..0];
}

/// The name /proc/self/fd/N shows for an mq descriptor: the queue name with one leading '/' (Linux stores it without).
pub fn linkName(name: []const u8, out: []u8) ?usize {
    const lead: usize = if (name.len > 0 and name[0] == '/') 0 else 1;
    if (lead + name.len > out.len) return null;
    if (lead == 1) out[0] = '/';
    @memcpy(out[lead..][0..name.len], name);
    return lead + name.len;
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

/// The registration is owned by process `owner_tgid` (0: none): is the caller's process `caller_tgid` that owner? Linux
/// compares task_tgid in do_mq_notify (NULL removes it) and mqueue_flush_file (a close by the owner removes it).
pub fn notifyOwner(owner_tgid: u32, caller_tgid: u32) bool {
    return owner_tgid != 0 and owner_tgid == caller_tgid;
}

/// Does a task's exit drop its process's registrations? Only the process's own exit: a thread shares the descriptors and the
/// owner (the tgid) outlives it.
pub fn exitDropsNotify(exiting_is_thread: bool) bool {
    return !exiting_is_thread;
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
    try std.testing.expectEqual(@as(u32, 0x802), reportedFlags(O_RDWR, O_NONBLOCK, false));
    try std.testing.expectEqual(@as(u32, 0x80000), reportedFlags(O_RDONLY, 0, true));
    try std.testing.expectEqual(POLLOUT, pollEvents(0, 4));
    try std.testing.expectEqual(POLLIN | POLLOUT, pollEvents(1, 4));
    try std.testing.expectEqual(POLLIN, pollEvents(4, 4));
    var line: [FILENT_SIZE]u8 = undefined;
    try std.testing.expectEqualStrings("QSIZE:3          NOTIFY:0     SIGNO:0     NOTIFY_PID:0     \n", statusLine(&line, 3, false, 0, 10, 9));
    try std.testing.expectEqual(@as(usize, 60), statusLine(&line, 0, true, SIGEV_SIGNAL, 10, 123).len);
    var nm: [8]u8 = undefined;
    try std.testing.expectEqualStrings("/q", nm[0..linkName("q", &nm).?]);
    try std.testing.expectEqualStrings("/q", nm[0..linkName("/q", &nm).?]);
    try std.testing.expect(sigevNotifyValid(SIGEV_SIGNAL));
    try std.testing.expect(sigevNotifyValid(SIGEV_NONE));
    try std.testing.expect(!sigevNotifyValid(SIGEV_THREAD));
    try std.testing.expect(notifyUnregister(true) == .removed);
    try std.testing.expect(notifyOwner(41, 41));
    try std.testing.expect(!notifyOwner(41, 42));
    try std.testing.expect(!notifyOwner(0, 0));
    try std.testing.expect(exitDropsNotify(false));
    try std.testing.expect(!exitDropsNotify(true));
    try std.testing.expect(notifyUnregister(false) == .kept);
    try std.testing.expect(notifySends(SIGEV_SIGNAL, 10));
    try std.testing.expect(!notifySends(SIGEV_SIGNAL, 0));
    try std.testing.expect(!notifySends(SIGEV_NONE, 10));
}
