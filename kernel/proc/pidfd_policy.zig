//! Pure pidfd_open flag validation.

pub fn flagsValid(flags: u32) bool {
    return flags == 0;
}

test "pidfd_open rejects unsupported flags" {
    const std = @import("std");
    try std.testing.expect(flagsValid(0));
    try std.testing.expect(!flagsValid(1));
    try std.testing.expect(!flagsValid(0x80000));
}
