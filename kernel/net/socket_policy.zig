//! Pure socket syscall argument policy.

pub fn shutdownHowValid(how: u32) bool {
    return how <= 2;
}

test "shutdown rejects invalid direction" {
    const std = @import("std");
    try std.testing.expect(shutdownHowValid(0));
    try std.testing.expect(shutdownHowValid(2));
    try std.testing.expect(!shutdownHowValid(3));
}
