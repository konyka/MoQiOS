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

pub fn ownerMatches(owner_group_tid: u32, current_group_tid: u32) bool {
    return owner_group_tid != 0 and owner_group_tid == current_group_tid;
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
