//! Safe validation for user-controlled sigreturn register targets.

pub const USER_LIMIT: u64 = 0x0000_8000_0000_0000;
const FORBIDDEN_RFLAGS: u64 = (3 << 12) | (1 << 14) | (1 << 16) | (1 << 17) |
    (1 << 19) | (1 << 20);

pub fn userTargetValid(value: u64) bool {
    return value != 0 and value < USER_LIMIT;
}

pub fn rflagsValid(value: u64) bool {
    return (value & FORBIDDEN_RFLAGS) == 0 and (value & 2) != 0 and (value & (1 << 9)) != 0;
}

test "sigreturn rejects kernel targets and privileged flags" {
    const std = @import("std");
    try std.testing.expect(userTargetValid(0x4000));
    try std.testing.expect(!userTargetValid(0));
    try std.testing.expect(!userTargetValid(USER_LIMIT));
    try std.testing.expect(rflagsValid(0x202));
    try std.testing.expect(rflagsValid(0x203));
    try std.testing.expect(!rflagsValid(0x2));
    try std.testing.expect(!rflagsValid(0x4202));
}
