//! Pure runqueue lifetime policy.

pub const Entry = struct {
    task: usize,
    incarnation: u64,
};

pub fn tokenMatches(entry: Entry, current_incarnation: u64) bool {
    return entry.incarnation == current_incarnation;
}

pub fn sameEntry(left: Entry, right: Entry) bool {
    return left.task == right.task and left.incarnation == right.incarnation;
}

test "runqueue token rejects reused task slots" {
    const std = @import("std");
    const entry: Entry = .{ .task = 7, .incarnation = 4 };
    try std.testing.expect(tokenMatches(entry, 4));
    try std.testing.expect(!tokenMatches(entry, 5));
}

test "runqueue duplicate identity requires task and incarnation" {
    const std = @import("std");
    const entry: Entry = .{ .task = 7, .incarnation = 4 };
    try std.testing.expect(sameEntry(entry, .{ .task = 7, .incarnation = 4 }));
    try std.testing.expect(!sameEntry(entry, .{ .task = 8, .incarnation = 4 }));
    try std.testing.expect(!sameEntry(entry, .{ .task = 7, .incarnation = 5 }));
}
