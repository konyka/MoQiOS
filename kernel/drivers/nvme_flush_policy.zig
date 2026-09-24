//! Pure NVMe Flush command shape and completion status policy.

pub const OPCODE: u8 = 0x00;

pub fn statusOk(status: u16) bool {
    return ((status >> 1) & 0x7FF) == 0;
}

test "NVMe flush uses opcode zero and accepts only successful completion" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u8, 0), OPCODE);
    try std.testing.expect(statusOk(0));
    try std.testing.expect(!statusOk(2));
}
