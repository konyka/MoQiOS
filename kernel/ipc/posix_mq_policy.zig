//! Pure policy for distinguishing an absent MQ timeout from a zero deadline.

pub const Timeout = union(enum) {
    none,
    deadline: u64,
};

pub fn fromNanoseconds(timeout_present: bool, nanoseconds: ?u64) Timeout {
    if (!timeout_present) return .none;
    return .{ .deadline = nanoseconds orelse 0 };
}

pub fn deadlineTokenMatches(saved_deadline: u64, saved_incarnation: u64, current_deadline: u64, current_incarnation: u64) bool {
    return saved_deadline != 0 and saved_deadline == current_deadline and saved_incarnation == current_incarnation;
}

test "MQ timeout preserves a valid zero deadline" {
    const std = @import("std");
    try std.testing.expect(std.meta.activeTag(fromNanoseconds(false, null)) == .none);
    try std.testing.expectEqual(@as(u64, 0), fromNanoseconds(true, 0).deadline);
    try std.testing.expect(deadlineTokenMatches(4, 9, 4, 9));
    try std.testing.expect(!deadlineTokenMatches(4, 9, 5, 9));
    try std.testing.expect(!deadlineTokenMatches(4, 9, 4, 10));
}
