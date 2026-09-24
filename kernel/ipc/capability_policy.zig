//! Pure authorization policy for native IPC capability grants.

pub fn grantAllowed(endpoint_owner: ?u32, caller: u32, rights_bits: u32) bool {
    return endpoint_owner != null and endpoint_owner.? == caller and rights_bits & ~@as(u32, 0x0F) == 0;
}

pub const Operation = enum { send, receive, notify };

pub fn operationAllowed(has_cap: bool, is_owner: bool, op: Operation) bool {
    return has_cap or (is_owner and op == .receive);
}

pub fn grantTargetAllowed(endpoint_owner: ?u32, caller: u32, recipient: u32) bool {
    return endpoint_owner != null and endpoint_owner.? == caller and recipient != caller;
}

test "foreign notification reads require notify capability" {
    const std = @import("std");
    try std.testing.expect(operationAllowed(true, false, .notify));
    try std.testing.expect(!operationAllowed(false, false, .notify));
}

test "capability grant requires endpoint ownership and known rights" {
    const std = @import("std");
    try std.testing.expect(grantAllowed(4, 4, 0x0F));
    try std.testing.expect(!grantAllowed(4, 5, 0x0F));
    try std.testing.expect(!grantAllowed(null, 4, 0x0F));
    try std.testing.expect(!grantAllowed(4, 4, 0x80));
    try std.testing.expect(!grantAllowed(4, 4, 0x100));
    try std.testing.expect(!grantAllowed(4, 4, 0x101));
    try std.testing.expect(grantTargetAllowed(4, 4, 5));
    try std.testing.expect(!grantTargetAllowed(4, 5, 6));
    try std.testing.expect(!grantTargetAllowed(null, 4, 5));
    try std.testing.expect(operationAllowed(true, false, .send));
    try std.testing.expect(!operationAllowed(false, false, .send));
}
