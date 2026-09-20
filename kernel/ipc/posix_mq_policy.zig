//! Pure policy for distinguishing an absent MQ timeout from a zero deadline.

pub const Timeout = union(enum) {
    none,
    deadline: u64,
};

pub fn fromNanoseconds(timeout_present: bool, nanoseconds: ?u64) Timeout {
    if (!timeout_present) return .none;
    return .{ .deadline = nanoseconds orelse 0 };
}

test "MQ timeout preserves a valid zero deadline" {
    const std = @import("std");
    try std.testing.expect(std.meta.activeTag(fromNanoseconds(false, null)) == .none);
    try std.testing.expectEqual(@as(u64, 0), fromNanoseconds(true, 0).deadline);
}
