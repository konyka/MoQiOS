//! Process-directed signals that no thread can take yet (Linux's shared pending set, the part this kernel needs).
//!
//! A signal sent to a process is delivered once. When the named thread and every sibling block it, it stays pending for the
//! process rather than for one thread: the first thread to stop blocking it takes it. `held` is the set of such signals for one
//! process (bit N = signal N+1).

const std = @import("std");

/// `held` after a process-directed send of `signum` that no live thread can take (`any_unblocked` false), or after one that some
/// thread can take (the set is unchanged: that thread gets the signal directly).
pub fn hold(held: u64, signum: u32, any_unblocked: bool) u64 {
    if (any_unblocked) return held;
    return held | (@as(u64, 1) << @intCast(signum - 1));
}

/// The lowest signal in `held` that `mask` does not block, or null. A thread that just unblocked something takes it.
pub fn claimable(held: u64, mask: u64) ?u32 {
    const bits = held & ~mask;
    if (bits == 0) return null;
    return @as(u32, @ctz(bits)) + 1;
}

/// `held` after `signum` was taken by a thread.
pub fn taken(held: u64, signum: u32) u64 {
    return held & ~(@as(u64, 1) << @intCast(signum - 1));
}

/// What sigpending reports: this thread's own pending set plus the process-directed signals every thread still blocks.
/// A thread-directed signal is only in `private`, so a sibling does not see it.
pub fn visible(private: u64, held: u64) u64 {
    return private | held;
}

/// The signals an exiting thread must pass on to a live sibling: those pending for it that are held for the process. Its
/// thread-directed signals (tkill) die with it, as in Linux.
pub fn handOff(private: u64, held: u64) u64 {
    return private & held;
}

test "an exiting thread passes on only the held process-directed signals" {
    try std.testing.expectEqual(@as(u64, 1 << 9), handOff((1 << 9) | (1 << 11), 1 << 9));
    try std.testing.expectEqual(@as(u64, 0), handOff(1 << 11, 1 << 9));
    try std.testing.expectEqual(@as(u64, 0), handOff(1 << 9, 0));
}

test "a process-directed signal stays pending only while every thread blocks it" {
    var held: u64 = 0;
    held = hold(held, 10, false);
    try std.testing.expectEqual(@as(u64, 1) << 9, held);
    try std.testing.expectEqual(@as(?u32, null), claimable(held, 1 << 9)); // the thread still blocks it
    try std.testing.expectEqual(@as(?u32, 10), claimable(held, 0));
    held = taken(held, 10);
    try std.testing.expectEqual(@as(u64, 0), held);
    try std.testing.expectEqual(@as(u64, 0), hold(0, 10, true)); // a thread could take it: nothing is held
    // The sibling has nothing of its own, but the held process-directed signal shows; a private bit stays private.
    try std.testing.expectEqual(@as(u64, 1) << 9, visible(0, 1 << 9));
    try std.testing.expectEqual(@as(u64, (1 << 9) | (1 << 11)), visible(1 << 11, 1 << 9));
}
