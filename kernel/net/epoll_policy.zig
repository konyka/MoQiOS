//! Strict validation for the currently implemented epoll_create1 contract.
const errno = @import("../lib/errno.zig");

pub fn validate(flags: u32) i64 {
    return if (flags == 0) 0 else errno.EINVAL;
}

test "epoll_create1 accepts only flags zero" {
    const std = @import("std");
    try std.testing.expectEqual(@as(i64, 0), validate(0));
    try std.testing.expectEqual(errno.EINVAL, validate(0x80000));
    try std.testing.expectEqual(errno.EINVAL, validate(1));
}
