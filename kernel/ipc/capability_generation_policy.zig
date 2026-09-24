//! Pure endpoint generation binding for IPC capabilities.

pub fn matches(cap_generation: u64, endpoint_generation: u64) bool {
    return cap_generation != 0 and cap_generation == endpoint_generation;
}

test "stale endpoint capability generations are rejected" {
    const std = @import("std");
    try std.testing.expect(matches(7, 7));
    try std.testing.expect(!matches(7, 8));
    try std.testing.expect(!matches(0, 7));
}
