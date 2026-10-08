//! Pure runqueue lifetime policy.

pub const Entry = struct {
    task: usize,
    incarnation: u64,
};

pub fn tokenMatches(entry: Entry, current_incarnation: u64) bool {
    return entry.incarnation == current_incarnation;
}

test "runqueue token rejects reused task slots" {
    const std = @import("std");
    const entry: Entry = .{ .task = 7, .incarnation = 4 };
    try std.testing.expect(tokenMatches(entry, 4));
    try std.testing.expect(!tokenMatches(entry, 5));
}
