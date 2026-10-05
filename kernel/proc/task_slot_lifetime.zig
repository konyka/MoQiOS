//! Shared task-slot reset primitive used by production creation and host tests.

/// Clear a task slot while retaining the incarnation that identifies its
/// lifetime. The caller owns synchronization and must increment the
/// incarnation before publishing a new occupant.
pub fn resetPreservingIncarnation(bytes: []u8, incarnation: *u64) void {
    const saved = incarnation.*;
    @memset(bytes, 0);
    incarnation.* = saved;
}

test "slot reset preserves incarnation while clearing other bytes" {
    const std = @import("std");
    var bytes = [_]u8{0xA5} ** 32;
    const incarnation = @as(*u64, @ptrCast(@alignCast(&bytes[8])));
    incarnation.* = 7;
    resetPreservingIncarnation(&bytes, incarnation);
    try std.testing.expectEqual(@as(u64, 7), incarnation.*);
    try std.testing.expectEqual(@as(u8, 0), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0), bytes[31]);
}
