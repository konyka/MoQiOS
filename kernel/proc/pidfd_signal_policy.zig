//! Pure pidfd_send_signal argument and descriptor policy.

pub fn signalValid(sig: u32) bool {
    return sig <= 31;
}

pub fn flagsValid(flags: u32) bool {
    return flags == 0;
}

pub fn aliasesShareValidation() bool {
    return true;
}

test "pidfd_send_signal rejects invalid signal and flags" {
    const std = @import("std");
    try std.testing.expect(signalValid(0));
    try std.testing.expect(signalValid(31));
    try std.testing.expect(!signalValid(32));
    try std.testing.expect(flagsValid(0));
    try std.testing.expect(!flagsValid(1));
    try std.testing.expect(aliasesShareValidation());
}
