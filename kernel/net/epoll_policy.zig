//! Validation for the epoll_create1 flags supported by the kernel.
const std = @import("std");
const errno = @import("../lib/errno.zig");

pub const EPOLL_CLOEXEC: u32 = 0x80000;
pub const SIGSET_SIZE: u64 = 8;
pub const SIGKILL_BIT: u64 = @as(u64, 1) << 8;
pub const SIGSTOP_BIT: u64 = @as(u64, 1) << 18;
pub const UNBLOCKABLE_MASK: u64 = SIGKILL_BIT | SIGSTOP_BIT;

pub fn validate(flags: u32) i64 {
    return if (flags & ~EPOLL_CLOEXEC == 0) 0 else errno.EINVAL;
}

pub fn validateSigsetSize(size: u64) i64 {
    return if (size == SIGSET_SIZE) 0 else errno.EINVAL;
}

pub fn validateTemporaryMask(sigmask_ptr: u64, sigsetsize: u64) i64 {
    return if (sigmask_ptr == 0) 0 else validateSigsetSize(sigsetsize);
}

pub fn temporaryMask(mask: u64) u64 {
    return mask & ~UNBLOCKABLE_MASK;
}

/// Absolute monotonic deadline of a positive epoll_wait timeout; null for
/// 0 (poll) and negative (infinite). Saturates instead of wrapping.
pub fn timeoutDeadlineNs(now_ns: u64, timeout_ms: i32) ?u64 {
    if (timeout_ms <= 0) return null;
    return now_ns +| @as(u64, @intCast(timeout_ms)) * std.time.ns_per_ms;
}

pub const TimespecResult = union(enum) {
    milliseconds: i32,
    invalid,
};

/// Convert a non-negative Linux timespec to epoll's bounded millisecond API.
pub fn timeoutMilliseconds(tv_sec: i64, tv_nsec: i64) TimespecResult {
    if (tv_sec < 0 or tv_nsec < 0 or tv_nsec > 999_999_999) return .invalid;
    const max_ms: u64 = 0x7fffffff;
    const sec: u64 = @intCast(tv_sec);
    if (sec > max_ms / 1000) return .{ .milliseconds = @intCast(max_ms) };
    const whole_ms = sec * 1000;
    const nsec_ms = @as(u64, @intCast(@divTrunc(tv_nsec, 1_000_000)));
    const rounded_ms = if (tv_nsec != 0 and nsec_ms == 0) @as(u64, 1) else nsec_ms;
    const with_nsec = whole_ms + rounded_ms;
    return .{ .milliseconds = @intCast(@min(with_nsec, max_ms)) };
}

/// `struct epoll_event` as the x86_64 Linux ABI lays it out: `events` at offset 0, `data` at offset 4,
/// 12 bytes in all (the structure is packed on this architecture only).
pub const EVENT_SIZE: usize = 12;
pub const EVENT_DATA_OFFSET: usize = 4;

/// Largest `maxevents` epoll_wait accepts (Linux: INT_MAX / sizeof(struct epoll_event)).
pub const MAX_WAIT_EVENTS: i32 = 0x7fffffff / @as(i32, EVENT_SIZE);
pub const USER_LIMIT: u64 = 0x0000_8000_0000_0000;

pub const CTL_ADD: i32 = 1;
pub const CTL_DEL: i32 = 2;
pub const CTL_MOD: i32 = 3;

pub const EPOLLIN: u32 = 0x001;
pub const EPOLLOUT: u32 = 0x004;
pub const EPOLLERR: u32 = 0x008;
pub const EPOLLHUP: u32 = 0x010;
pub const EPOLLWAKEUP: u32 = 0x20000000;
pub const EPOLLEXCLUSIVE: u32 = 0x10000000;
pub const EPOLLET: u32 = 0x80000000;

/// Events epoll reports whether or not the registration asked for them (Linux: EPOLLERR and EPOLLHUP are always reported).
pub const ALWAYS_REPORTED: u32 = EPOLLERR | EPOLLHUP;

/// Which of the `ready` bits make a registration with interest `interest` ready: the bits it asked for plus the always-reported ones.
pub fn notifyMatch(ready: u32, interest: u32) u32 {
    return ready & (interest | ALWAYS_REPORTED);
}

/// Bits EPOLLEXCLUSIVE may be combined with (Linux EPOLLEXCLUSIVE_OK_BITS).
pub const EXCLUSIVE_OK_BITS: u32 = EPOLLIN | EPOLLOUT | EPOLLERR | EPOLLHUP | EPOLLWAKEUP | EPOLLET | EPOLLEXCLUSIVE;

/// What an epoll descriptor number refers to.
pub const Epfd = union(enum) {
    closed,
    not_epoll,
    epoll: u32,
};

/// Descriptor kinds with no poll operation (regular files and directories, named by their FdType tag
/// so the rule is host-testable without the arch-bound vfs module): epoll_ctl refuses them with EPERM.
const NOT_POLLABLE = [_][]const u8{ "ramdisk_file", "fat32_file", "ext2_file", "tmpfs_file", "proc_file", "rofs_file" };

pub fn pollable(tag: []const u8) bool {
    for (NOT_POLLABLE) |n| {
        if (std.mem.eql(u8, n, tag)) return false;
    }
    return true;
}

/// EPOLL_CTL_ADD and EPOLL_CTL_MOD (and any unknown op) carry a struct epoll_event; only DEL does not.
pub fn ctlHasEvent(op: i32) bool {
    return op != CTL_DEL;
}

pub const CtlFacts = struct {
    op: i32,
    /// The event structure could be read (irrelevant when the op carries none).
    event_readable: bool,
    events: u32,
    epfd: Epfd,
    target_open: bool,
    target_pollable: bool,
    target_is_epoll: bool,
    /// The target is the epoll instance itself (itself, or a duplicate of it).
    same_file: bool,
};

/// The checks Linux's epoll_ctl makes before it looks at the registration itself, in Linux's order:
/// EFAULT (event), EBADF (epfd, target), EPERM (target cannot poll), EINVAL (self / epfd is not epoll /
/// EPOLLEXCLUSIVE misuse). 0 means go on to the loop check and the registration.
pub fn ctlPrecheck(f: CtlFacts) i64 {
    if (ctlHasEvent(f.op) and !f.event_readable) return errno.EFAULT;
    if (f.epfd == .closed) return errno.EBADF;
    if (!f.target_open) return errno.EBADF;
    if (!f.target_pollable) return errno.EPERM;
    if (f.same_file or f.epfd == .not_epoll) return errno.EINVAL;
    if (ctlHasEvent(f.op) and (f.events & EPOLLEXCLUSIVE) != 0) {
        if (f.op == CTL_MOD) return errno.EINVAL;
        if (f.op == CTL_ADD and (f.target_is_epoll or (f.events & ~EXCLUSIVE_OK_BITS) != 0)) return errno.EINVAL;
    }
    return 0;
}

/// The checks Linux's epoll_wait makes before it waits: EBADF (epfd), EINVAL (maxevents), EFAULT (the
/// buffer would leave user space), EINVAL (epfd is not an epoll descriptor). Note the buffer is only
/// range-checked here, not touched.
pub fn waitErrno(epfd: Epfd, maxevents: i32, events_ptr: u64) i64 {
    if (epfd == .closed) return errno.EBADF;
    if (maxevents <= 0 or maxevents > MAX_WAIT_EVENTS) return errno.EINVAL;
    const bytes: u64 = @as(u64, @intCast(maxevents)) * EVENT_SIZE;
    if (events_ptr >= USER_LIMIT or bytes > USER_LIMIT - events_ptr) return errno.EFAULT;
    if (epfd == .not_epoll) return errno.EINVAL;
    return 0;
}

test "epoll_create1 accepts zero and EPOLL_CLOEXEC" {
    try std.testing.expectEqual(@as(i64, 0), validate(0));
    try std.testing.expectEqual(@as(i64, 0), validate(EPOLL_CLOEXEC));
    try std.testing.expectEqual(errno.EINVAL, validate(1));
}

test "epoll temporary mask policy validates size and excludes unblockable signals" {
    try std.testing.expectEqual(@as(i64, 0), validateTemporaryMask(0, 4));
    try std.testing.expectEqual(errno.EINVAL, validateTemporaryMask(1, 4));
    try std.testing.expectEqual(@as(i64, 0), validateSigsetSize(SIGSET_SIZE));
    try std.testing.expectEqual(errno.EINVAL, validateSigsetSize(4));
    try std.testing.expectEqual(errno.EINVAL, validateSigsetSize(16));
    try std.testing.expectEqual(@as(u64, 0x21), temporaryMask(0x21 | SIGKILL_BIT | SIGSTOP_BIT));
}

test "epoll_pwait2 timeout policy handles null-style infinity and overflow" {
    try std.testing.expectEqual(@as(i32, 0), timeoutMilliseconds(0, 0).milliseconds);
    try std.testing.expectEqual(@as(i32, 1), timeoutMilliseconds(0, 1).milliseconds);
    try std.testing.expectEqual(@as(i32, 1), timeoutMilliseconds(0, 999_999).milliseconds);
    try std.testing.expectEqual(@as(i32, 1_000_001), timeoutMilliseconds(1000, 1).milliseconds);
    try std.testing.expectEqual(@as(i32, 1500), timeoutMilliseconds(1, 500_000_000).milliseconds);
    try std.testing.expectEqual(@as(i32, 0x7fffffff), timeoutMilliseconds(std.math.maxInt(i64), 0).milliseconds);
    try std.testing.expect(timeoutMilliseconds(-1, 0) == .invalid);
    try std.testing.expect(timeoutMilliseconds(0, -1) == .invalid);
    try std.testing.expect(timeoutMilliseconds(0, 1_000_000_000) == .invalid);
}

test "an EPOLLIN-only registration is still made ready by a hang-up or an error" {
    try std.testing.expectEqual(@as(u32, EPOLLHUP), notifyMatch(EPOLLHUP, EPOLLIN));
    try std.testing.expectEqual(@as(u32, EPOLLERR), notifyMatch(EPOLLERR, EPOLLOUT));
    try std.testing.expectEqual(@as(u32, EPOLLHUP | EPOLLIN), notifyMatch(EPOLLHUP | EPOLLIN, EPOLLIN));
}

test "bits the registration did not ask for, other than ERR and HUP, do not make it ready" {
    try std.testing.expectEqual(@as(u32, 0), notifyMatch(EPOLLOUT, EPOLLIN));
    try std.testing.expectEqual(@as(u32, 0), notifyMatch(EPOLLIN, EPOLLOUT));
    try std.testing.expectEqual(@as(u32, EPOLLIN), notifyMatch(EPOLLIN | EPOLLOUT, EPOLLIN));
}

/// Linux EP_MAX_NESTS: the longest chain of epoll-in-epoll registrations. Adding epoll B to epoll A is ELOOP when
/// (levels below B) + 1 + (levels above A) would exceed it.
pub const EP_MAX_NESTS: u32 = 4;

pub fn nestDepthExceeded(levels_below_added: u32, levels_above_receiver: u32) bool {
    return levels_below_added + 1 + levels_above_receiver > EP_MAX_NESTS;
}

