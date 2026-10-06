//! Safe validation for user-controlled sigreturn register targets.

pub const USER_LIMIT: u64 = 0x0000_8000_0000_0000;

/// RFLAGS bits a user task may restore through sigreturn (Linux FIX_EFLAGS):
/// CF PF AF ZF SF TF DF OF RF AC ID. Everything else is kernel-owned — IOPL
/// would grant port I/O and cli/sti, NT/VM/VIF/VIP change iret semantics.
pub const USER_RFLAGS: u64 = (1 << 0) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 7) |
    (1 << 8) | (1 << 10) | (1 << 11) | (1 << 16) | (1 << 18) | (1 << 21);
const FORCED_RFLAGS: u64 = (1 << 1) | (1 << 9);

pub fn userTargetValid(value: u64) bool {
    return value != 0 and value < USER_LIMIT;
}

/// The saved image is legitimately allowed to differ from what user code
/// could set itself: a handler entered from a fault frame carries RF=1.
/// Masking rather than rejecting keeps those returns working.
pub fn sanitizeRflags(value: u64) u64 {
    return (value & USER_RFLAGS) | FORCED_RFLAGS;
}

test "sigreturn rejects kernel targets and masks privileged flags" {
    const std = @import("std");
    try std.testing.expect(userTargetValid(0x4000));
    try std.testing.expect(!userTargetValid(0));
    try std.testing.expect(!userTargetValid(USER_LIMIT));
    try std.testing.expectEqual(@as(u64, 0x202), sanitizeRflags(0x202));
    try std.testing.expectEqual(@as(u64, 0x203), sanitizeRflags(0x203));
    try std.testing.expectEqual(@as(u64, 0x202), sanitizeRflags(0x2));
    try std.testing.expectEqual(@as(u64, 0x202), sanitizeRflags(0x4202));
    try std.testing.expectEqual(@as(u64, 0x10202), sanitizeRflags(0x10202));
}
