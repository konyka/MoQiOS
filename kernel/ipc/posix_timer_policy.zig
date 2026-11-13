//! Pure validation for POSIX timer_create output arguments.

pub const USER_LIMIT: u64 = 0x0000_8000_0000_0000;
pub const TIMER_ABSTIME: u32 = 1;

pub fn timerIdPointerValid(ptr: u64) bool {
    return ptr != 0 and ptr < USER_LIMIT;
}

pub fn sigeventPointerValid(ptr: u64) bool {
    return ptr == 0 or (ptr < USER_LIMIT and ptr <= USER_LIMIT - 64);
}

pub fn timerOwnerTid(is_thread: bool, tid: u32, parent_tid: u32) u32 {
    return if (is_thread and parent_tid != 0) parent_tid else tid;
}

pub fn shouldDeleteForExit(owner_group_tid: u32, exiting_is_thread: bool, exiting_tid: u32) bool {
    return !exiting_is_thread and owner_group_tid == exiting_tid;
}

pub fn flagsValid(flags: u32) bool {
    return flags & ~TIMER_ABSTIME == 0;
}

pub const SIGEV_SIGNAL: i32 = 0;
pub const SIGEV_NONE: i32 = 1;
pub const SIGEV_THREAD: i32 = 2;
pub const SIGEV_THREAD_ID: i32 = 4;

/// Linux good_sigevent: SIGEV_THREAD_ID only combines with SIGEV_SIGNAL, and the signal must be 1..64. The target tid is checked
/// separately against the caller's thread group.
pub fn sigeventValid(notify: i32, signo: i32) bool {
    const kind = notify & ~SIGEV_THREAD_ID;
    if (kind != SIGEV_SIGNAL and kind != SIGEV_NONE and kind != SIGEV_THREAD) return false;
    if ((notify & SIGEV_THREAD_ID) != 0 and kind != SIGEV_SIGNAL) return false;
    if (kind == SIGEV_SIGNAL or kind == SIGEV_THREAD) return signo > 0 and signo <= 64;
    return true;
}

/// Where the timer's signal goes: the named thread when SIGEV_THREAD_ID is set, otherwise the creator.
pub fn signalTarget(notify: i32, thread_tid: u32, creator_tid: u32) u32 {
    return if ((notify & SIGEV_THREAD_ID) != 0) thread_tid else creator_tid;
}

pub fn ownerMatches(owner_group_tid: u32, current_group_tid: u32) bool {
    return owner_group_tid != 0 and owner_group_tid == current_group_tid;
}

/// The signal side of one timer (Linux keeps one sigqueue per timer). `owed`: an expiry has happened whose signal has not been
/// delivered yet; `queued`: that signal is pending on the owner; `overrun`: expiries since the owed one.
pub const SigState = struct {
    owed: bool = false,
    queued: bool = false,
    overrun: u64 = 0,
};

/// One expiry. `still_pending`: the owner still has the signal pending (if it is gone without a delivery, a kill() of the same
/// standard signal took it or it was discarded, and the timer starts over); `ignored`: the owner ignores the signal and does not
/// block it, so it is not sent but the expiries keep counting until it can be. Returns whether to send the signal now.
pub fn onExpiry(s: *SigState, still_pending: bool, ignored: bool) bool {
    if (s.queued and !still_pending) s.* = .{};
    if (s.owed) s.overrun +|= 1 else s.owed = true;
    return !s.queued and !ignored;
}

/// The signal was taken: its overrun is reported and the timer may queue the next one.
pub fn onDeliver(s: *SigState) u64 {
    const o = s.overrun;
    s.* = .{};
    return o;
}

test "timer_create requires a non-null user timer ID pointer" {
    const std = @import("std");
    try std.testing.expect(!timerIdPointerValid(0));
    try std.testing.expect(timerIdPointerValid(0x4000));
    try std.testing.expect(!timerIdPointerValid(USER_LIMIT));
}

test "timer_create rejects an invalid non-null sigevent pointer" {
    const std = @import("std");
    try std.testing.expect(sigeventPointerValid(0));
    try std.testing.expect(sigeventPointerValid(0x4000));
    try std.testing.expect(!sigeventPointerValid(USER_LIMIT));
}

test "POSIX timers follow the process thread-group owner" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 42), timerOwnerTid(true, 99, 42));
    try std.testing.expectEqual(@as(u32, 99), timerOwnerTid(false, 99, 42));
    try std.testing.expect(!shouldDeleteForExit(42, true, 99));
    try std.testing.expect(shouldDeleteForExit(42, false, 42));
}

test "timer_settime rejects unknown flags and foreign owners" {
    const std = @import("std");
    try std.testing.expect(flagsValid(0));
    try std.testing.expect(flagsValid(TIMER_ABSTIME));
    try std.testing.expect(!flagsValid(2));
    try std.testing.expect(ownerMatches(42, 42));
    try std.testing.expect(!ownerMatches(42, 99));
    try std.testing.expect(!ownerMatches(0, 0));
}

test "a timer queues one signal and counts the expiries that come before it is taken" {
    const std = @import("std");
    var s: SigState = .{};
    try std.testing.expect(onExpiry(&s, false, false));
    s.queued = true;
    for (0..9) |_| try std.testing.expect(!onExpiry(&s, true, false));
    try std.testing.expectEqual(@as(u64, 9), onDeliver(&s));
    try std.testing.expect(onExpiry(&s, false, false));
    s.queued = true;
    try std.testing.expectEqual(@as(u64, 0), onDeliver(&s));
}

test "an ignored timer signal is not sent, its expiries keep counting, and it is sent once it is not ignored" {
    const std = @import("std");
    var s: SigState = .{};
    for (0..5) |_| try std.testing.expect(!onExpiry(&s, false, true));
    try std.testing.expect(onExpiry(&s, false, false));
    s.queued = true;
    try std.testing.expectEqual(@as(u64, 5), onDeliver(&s));
}

test "a queued timer signal that vanished without a delivery starts the count over" {
    const std = @import("std");
    var s: SigState = .{};
    try std.testing.expect(onExpiry(&s, false, false));
    s.queued = true;
    _ = onExpiry(&s, true, false);
    try std.testing.expect(onExpiry(&s, false, false));
    try std.testing.expectEqual(@as(u64, 0), s.overrun);
}

test "SIGEV_THREAD_ID only combines with SIGEV_SIGNAL and a real signal number" {
    const t = @import("std").testing;
    try t.expect(sigeventValid(SIGEV_SIGNAL, 10));
    try t.expect(sigeventValid(SIGEV_NONE, 0));
    try t.expect(sigeventValid(SIGEV_SIGNAL | SIGEV_THREAD_ID, 10));
    try t.expect(!sigeventValid(SIGEV_SIGNAL | SIGEV_THREAD_ID, 0));
    try t.expect(!sigeventValid(SIGEV_NONE | SIGEV_THREAD_ID, 10));
    try t.expect(sigeventValid(SIGEV_THREAD, 10));
    try t.expect(!sigeventValid(SIGEV_THREAD | SIGEV_THREAD_ID, 10));
    try t.expect(!sigeventValid(3, 10));
    try t.expectEqual(@as(u32, 77), signalTarget(SIGEV_SIGNAL | SIGEV_THREAD_ID, 77, 5));
    try t.expectEqual(@as(u32, 5), signalTarget(SIGEV_SIGNAL, 77, 5));
}
