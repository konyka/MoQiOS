//! Pure per-task queue of real-time signal instances (Linux semantics, measured).
//!
//! A real-time signal (32..64) sent N times is N deliveries, each with the
//! siginfo it was sent with, taken in send order; standard signals coalesce
//! and do not use this queue. The queue holds every pending real-time
//! instance of one task in arrival order, so "first instance of signal S"
//! is the first entry whose signo is S.
//!
//! When the queue is full Linux distinguishes the sender: a sigqueue-style
//! send (si_code < 0 and not SI_USER, e.g. SI_QUEUE) fails with EAGAIN,
//! while kill() and kernel sends still mark the signal pending and only the
//! siginfo is lost. `pushAllowedWhenFull` encodes that rule.

const siginfo = @import("siginfo_policy.zig");

pub const SIGRTMIN: u32 = 32;
pub const CAPACITY: usize = 32;

pub fn isRealtime(signo: u32) bool {
    return signo >= SIGRTMIN and signo <= 64;
}

/// True when a send that finds the queue full must still mark the signal
/// pending (losing only its siginfo); false means the send fails (EAGAIN).
pub fn pendingWithoutInfoWhenFull(code: i32) bool {
    return code >= 0 or code == siginfo.SI_USER or code == siginfo.SI_KERNEL;
}

/// RLIMIT_SIGPENDING (Linux sig_get_ucounts, kernel/signal.c 402): a send may queue one more real-time instance only while the
/// instances already queued for the target's real uid, across all its processes, stay below the target's soft limit. `limit` is
/// RLIM_INFINITY (all ones) when unlimited.
pub fn withinSigpendingLimit(queued_for_uid: u64, limit: u64) bool {
    if (limit == ~@as(u64, 0)) return true;
    return queued_for_uid < limit;
}

pub const Entry = struct {
    signo: u8 = 0,
    info: siginfo.Info = .{},
};

pub const Queue = struct {
    entries: [CAPACITY]Entry = @splat(.{}),
    count: u8 = 0,

    pub fn push(self: *Queue, signo: u32, info: siginfo.Info) bool {
        if (self.count == CAPACITY) return false;
        self.entries[self.count] = .{ .signo = @intCast(signo), .info = info };
        self.count += 1;
        return true;
    }

    pub fn has(self: *const Queue, signo: u32) bool {
        for (self.entries[0..self.count]) |e| {
            if (e.signo == signo) return true;
        }
        return false;
    }

    /// Remove and return the oldest instance of `signo`.
    pub fn take(self: *Queue, signo: u32) ?siginfo.Info {
        for (self.entries[0..self.count], 0..) |e, i| {
            if (e.signo != signo) continue;
            var j = i;
            while (j + 1 < self.count) : (j += 1) self.entries[j] = self.entries[j + 1];
            self.count -= 1;
            self.entries[self.count] = .{};
            return e.info;
        }
        return null;
    }

    /// Drop every queued instance of `signo` (SIG_IGN installed).
    pub fn discard(self: *Queue, signo: u32) void {
        var w: usize = 0;
        for (self.entries[0..self.count]) |e| {
            if (e.signo == signo) continue;
            self.entries[w] = e;
            w += 1;
        }
        for (self.entries[w..self.count]) |*e| e.* = .{};
        self.count = @intCast(w);
    }
};

const testing = @import("std").testing;

test "real-time instances are taken per signal in send order" {
    var q: Queue = .{};
    try testing.expect(q.push(34, .{ .code = siginfo.SI_QUEUE, .b = 1 }));
    try testing.expect(q.push(35, .{ .code = siginfo.SI_QUEUE, .b = 7 }));
    try testing.expect(q.push(34, .{ .code = siginfo.SI_QUEUE, .b = 2 }));
    try testing.expectEqual(@as(u64, 1), q.take(34).?.b);
    try testing.expect(q.has(34));
    try testing.expectEqual(@as(u64, 2), q.take(34).?.b);
    try testing.expect(!q.has(34));
    try testing.expect(q.take(34) == null);
    try testing.expectEqual(@as(u64, 7), q.take(35).?.b);
    try testing.expectEqual(@as(u8, 0), q.count);
}

test "a full queue refuses the next instance; discard drops only one signal" {
    var q: Queue = .{};
    for (0..CAPACITY) |i| try testing.expect(q.push(if (i % 2 == 0) 40 else 41, .{ .b = i }));
    try testing.expect(!q.push(40, .{}));
    q.discard(40);
    try testing.expectEqual(@as(u8, CAPACITY / 2), q.count);
    try testing.expect(!q.has(40));
    try testing.expectEqual(@as(u64, 1), q.take(41).?.b);
    try testing.expect(q.push(40, .{ .b = 99 }));
}

test "which full-queue sends still mark the signal pending" {
    try testing.expect(pendingWithoutInfoWhenFull(siginfo.SI_USER));
    try testing.expect(pendingWithoutInfoWhenFull(siginfo.SI_KERNEL));
    try testing.expect(!pendingWithoutInfoWhenFull(siginfo.SI_QUEUE));
    try testing.expect(!pendingWithoutInfoWhenFull(siginfo.SI_TKILL));
    try testing.expect(isRealtime(32) and isRealtime(64) and !isRealtime(31) and !isRealtime(65));
}

test "RLIMIT_SIGPENDING counts every queued instance of the uid" {
    try testing.expect(withinSigpendingLimit(4, 5));
    try testing.expect(!withinSigpendingLimit(5, 5));
    try testing.expect(!withinSigpendingLimit(0, 0));
    try testing.expect(withinSigpendingLimit(1 << 40, ~@as(u64, 0)));
}
