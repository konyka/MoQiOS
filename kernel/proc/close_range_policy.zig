const errno = @import("../lib/errno.zig");

pub const CLOSE_RANGE_CLOEXEC: u32 = 4;
pub const UINT_MAX: u32 = 0xFFFF_FFFF;

pub fn validate(first: u32, last: u32, flags: u32) i64 {
    if (first > last) return errno.EINVAL;
    if ((flags & ~CLOSE_RANGE_CLOEXEC) != 0) return errno.EINVAL;
    return 0;
}

test "close_range policy rejects invalid ranges and flags" {
    try @import("std").testing.expectEqual(errno.EINVAL, validate(8, 7, 0));
    try @import("std").testing.expectEqual(errno.EINVAL, validate(0, 1, 1));
    try @import("std").testing.expectEqual(@as(i64, 0), validate(0, 0, CLOSE_RANGE_CLOEXEC));
}
