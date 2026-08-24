//! Pure policy for the bounded TCP sendmmsg/recvmmsg ABI.

const errno = @import("../lib/errno.zig");

pub const MAX_MESSAGES: u64 = 16;
pub const SUPPORTED_FLAGS: u32 = 0;

/// The current socket implementation is nonblocking and has no timeout
/// handling.  A timeout pointer must therefore be null, but is never read.
pub fn validate(vlen: u64, flags: u32, timeout_ptr: u64) i64 {
    if (vlen > MAX_MESSAGES) return errno.EINVAL;
    if ((flags & ~SUPPORTED_FLAGS) != 0) return errno.EINVAL;
    if (timeout_ptr != 0) return errno.EINVAL;
    return 0;
}

test "message batch policy bounds count and validates current contract" {
    try @import("std").testing.expectEqual(@as(i64, 0), validate(0, 0, 0));
    try @import("std").testing.expectEqual(@as(i64, 0), validate(MAX_MESSAGES, 0, 0));
    try @import("std").testing.expectEqual(errno.EINVAL, validate(MAX_MESSAGES + 1, 0, 0));
    try @import("std").testing.expectEqual(errno.EINVAL, validate(1, 1, 0));
    try @import("std").testing.expectEqual(errno.EINVAL, validate(1, 0, 1));
}
