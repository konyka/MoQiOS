//! Validation for the epoll_create1 flags supported by the kernel.
const errno = @import("../lib/errno.zig");

pub const EPOLL_CLOEXEC: u32 = 0x80000;

pub fn validate(flags: u32) i64 {
    return if (flags & ~EPOLL_CLOEXEC == 0) 0 else errno.EINVAL;
}

test "epoll_create1 accepts zero and EPOLL_CLOEXEC" {
    const std = @import("std");
    try std.testing.expectEqual(@as(i64, 0), validate(0));
    try std.testing.expectEqual(@as(i64, 0), validate(EPOLL_CLOEXEC));
    try std.testing.expectEqual(errno.EINVAL, validate(1));
}
