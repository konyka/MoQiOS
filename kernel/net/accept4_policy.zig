//! Validation for the accept4 flags supported by the kernel.
const errno = @import("../lib/errno.zig");

pub const SOCK_NONBLOCK: u32 = 0x800;
pub const SOCK_CLOEXEC: u32 = 0x80000;
pub const SUPPORTED_FLAGS: u32 = SOCK_NONBLOCK | SOCK_CLOEXEC;

pub fn validate(flags: u32) i64 {
    return if (flags & ~SUPPORTED_FLAGS == 0) 0 else errno.EINVAL;
}

test "accept4 accepts supported flags and rejects unknown flags" {
    const std = @import("std");
    try std.testing.expectEqual(@as(i64, 0), validate(0));
    try std.testing.expectEqual(@as(i64, 0), validate(SOCK_NONBLOCK));
    try std.testing.expectEqual(@as(i64, 0), validate(SOCK_CLOEXEC));
    try std.testing.expectEqual(@as(i64, 0), validate(SUPPORTED_FLAGS));
    try std.testing.expectEqual(errno.EINVAL, validate(1));
    try std.testing.expectEqual(errno.EINVAL, validate(SUPPORTED_FLAGS | 1));
}
