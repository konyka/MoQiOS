//! Pure poll(2) / select(2) argument and readiness rules.
//!
//! poll: timeout is a C int in milliseconds (negative = wait forever);
//! nfds is bounded by the open-file limit; revents always carries
//! POLLERR/POLLHUP/POLLNVAL whether or not they were requested.
//! select: a NULL timeval waits forever, {0,0} polls once, a negative or
//! out-of-range field is EINVAL, a set bit naming a closed fd is EBADF.

const std = @import("std");

pub const POLLIN: u32 = 0x001;
pub const POLLOUT: u32 = 0x004;
pub const POLLERR: u32 = 0x008;
pub const POLLHUP: u32 = 0x010;
pub const POLLNVAL: u32 = 0x020;
pub const POLLRDNORM: u32 = 0x040;
pub const POLLWRNORM: u32 = 0x100;

pub const Wait = union(enum) {
    forever,
    /// Milliseconds; 0 means "poll once and return".
    ms: u64,
};

/// The timeout argument of poll(2): the low 32 bits as a signed int.
pub fn pollTimeout(raw: u64) Wait {
    const t: i32 = @bitCast(@as(u32, @truncate(raw)));
    if (t < 0) return .forever;
    return .{ .ms = @intCast(t) };
}

/// A struct timeval from select(2); null = no timeout. Fractions of a
/// millisecond round up so a non-zero timeout never degenerates into a poll.
pub fn selectTimeout(sec: i64, usec: i64) ?Wait {
    if (sec < 0 or usec < 0 or usec >= 1_000_000) return null;
    const whole = std.math.mul(u64, @intCast(sec), 1000) catch return .forever;
    const ms = whole +| (@as(u64, @intCast(usec)) + 999) / 1000;
    return .{ .ms = ms };
}

pub fn nfdsValid(nfds: u64, nofile_limit: u64) bool {
    return nfds <= nofile_limit;
}

/// Events requested by `events`, with the POLLRDNORM/POLLWRNORM aliases
/// folded onto POLLIN/POLLOUT.
pub fn requested(events: u32) u32 {
    var r = events;
    if (r & POLLRDNORM != 0) r |= POLLIN;
    if (r & POLLWRNORM != 0) r |= POLLOUT;
    return r;
}

/// revents for a descriptor whose current readiness is `current`.
pub fn revents(current: u32, events: u32) u32 {
    const want = requested(events);
    var out = (current & want) | (current & (POLLERR | POLLHUP));
    if (out & POLLIN != 0 and events & POLLRDNORM != 0) out |= POLLRDNORM;
    if (out & POLLOUT != 0 and events & POLLWRNORM != 0) out |= POLLWRNORM;
    return out;
}

/// select(): readable means data, EOF/hangup or an error; writable means
/// room or an error.
pub fn selectReadable(current: u32) bool {
    return current & (POLLIN | POLLHUP | POLLERR) != 0;
}

pub fn selectWritable(current: u32) bool {
    return current & (POLLOUT | POLLERR) != 0;
}

/// Next sleep slice: never longer than `slice_ms`, never past the deadline.
pub fn sliceDeadline(now_ns: u64, deadline_ns: ?u64, slice_ms: u64) u64 {
    const slice = now_ns +| slice_ms * std.time.ns_per_ms;
    return if (deadline_ns) |d| @min(slice, d) else slice;
}

test "poll timeout: negative waits forever, zero polls" {
    try std.testing.expect(pollTimeout(0xFFFF_FFFF_FFFF_FFFF) == .forever);
    try std.testing.expect(pollTimeout(0xFFFF_FFFF) == .forever);
    try std.testing.expectEqual(@as(u64, 0), pollTimeout(0).ms);
    try std.testing.expectEqual(@as(u64, 120), pollTimeout(120).ms);
}

test "select timeout validation and rounding" {
    try std.testing.expect(selectTimeout(-1, 0) == null);
    try std.testing.expect(selectTimeout(0, -1) == null);
    try std.testing.expect(selectTimeout(0, 1_000_000) == null);
    try std.testing.expectEqual(@as(u64, 0), selectTimeout(0, 0).?.ms);
    try std.testing.expectEqual(@as(u64, 1), selectTimeout(0, 1).?.ms);
    try std.testing.expectEqual(@as(u64, 100), selectTimeout(0, 100_000).?.ms);
    try std.testing.expectEqual(@as(u64, 2500), selectTimeout(2, 500_000).?.ms);
    try std.testing.expect(selectTimeout(std.math.maxInt(i64), 0).? == .forever);
}

test "revents always reports errors and hangups, only requested data events" {
    try std.testing.expectEqual(POLLIN, revents(POLLIN | POLLOUT, POLLIN));
    try std.testing.expectEqual(@as(u32, 0), revents(POLLIN, POLLOUT));
    try std.testing.expectEqual(POLLHUP, revents(POLLHUP, 0));
    try std.testing.expectEqual(POLLERR | POLLOUT, revents(POLLERR | POLLOUT, POLLOUT));
    try std.testing.expectEqual(POLLIN | POLLRDNORM, revents(POLLIN, POLLRDNORM));
}

test "select readiness and slicing" {
    try std.testing.expect(selectReadable(POLLHUP));
    try std.testing.expect(!selectReadable(POLLOUT));
    try std.testing.expect(selectWritable(POLLERR));
    try std.testing.expect(!selectWritable(POLLIN));
    try std.testing.expect(nfdsValid(64, 64));
    try std.testing.expect(!nfdsValid(65, 64));
    try std.testing.expectEqual(@as(u64, 5_000_000), sliceDeadline(0, null, 5));
    try std.testing.expectEqual(@as(u64, 2_000_000), sliceDeadline(0, 2_000_000, 5));
}
