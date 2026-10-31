//! Pure validation policy for the supported socketpair ABI.

const errno = @import("../lib/errno.zig");

pub const AF_UNIX: u32 = 1;
pub const SOCK_STREAM: u32 = 1;
pub const SOCK_DGRAM: u32 = 2;
pub const SOCK_NONBLOCK: u32 = 0x800;
pub const SOCK_CLOEXEC: u32 = 0x80000;
pub const TYPE_FLAGS: u32 = SOCK_NONBLOCK | SOCK_CLOEXEC;
pub const EPROTONOSUPPORT: i64 = -93;

pub fn validate(domain: u32, sock_type: u32, protocol: u32) i64 {
    if (domain != AF_UNIX or protocol != 0) return errno.EINVAL;
    if ((sock_type & ~(TYPE_FLAGS | 0xff)) != 0) return errno.EINVAL;
    const kind = sock_type & 0xff;
    if (kind != SOCK_STREAM and kind != SOCK_DGRAM) return errno.EINVAL;
    return 0;
}

test "socketpair policy accepts only AF_UNIX stream with supported flags" {
    try @import("std").testing.expectEqual(@as(i64, 0), validate(AF_UNIX, SOCK_STREAM, 0));
    try @import("std").testing.expectEqual(@as(i64, 0), validate(AF_UNIX, SOCK_STREAM | TYPE_FLAGS, 0));
    try @import("std").testing.expectEqual(errno.EINVAL, validate(2, SOCK_STREAM, 0));
    try @import("std").testing.expectEqual(errno.EINVAL, validate(AF_UNIX, SOCK_STREAM, 1));
    try @import("std").testing.expectEqual(@as(i64, 0), validate(AF_UNIX, SOCK_DGRAM, 0));
    try @import("std").testing.expectEqual(@as(i64, 0), validate(AF_UNIX, SOCK_DGRAM | TYPE_FLAGS, 0));
    try @import("std").testing.expectEqual(errno.EINVAL, validate(AF_UNIX, 3, 0)); // SOCK_RAW
    try @import("std").testing.expectEqual(errno.EINVAL, validate(AF_UNIX, 5, 0)); // SOCK_SEQPACKET
    try @import("std").testing.expectEqual(errno.EINVAL, validate(AF_UNIX, SOCK_STREAM | 0x400, 0));
}
