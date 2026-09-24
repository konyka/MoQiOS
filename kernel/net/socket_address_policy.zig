//! Pure sockaddr length policy for connect.

pub fn inetLengthValid(addr_len: u32, is_v6: bool) bool {
    const minimum: u32 = if (is_v6) 28 else 16;
    return addr_len >= minimum;
}

pub fn unixLengthValid(addr_len: u32, path_offset: u32) bool {
    return addr_len > path_offset;
}

pub fn inet4FamilyValid(family: u16) bool {
    return family == 2;
}

pub fn optionalUserAddressValid(addr: u64, user_limit: u64) bool {
    return addr == 0 or addr < user_limit;
}

test "connect requires a complete sockaddr for the selected family" {
    const std = @import("std");
    try std.testing.expect(inetLengthValid(16, false));
    try std.testing.expect(!inetLengthValid(15, false));
    try std.testing.expect(inetLengthValid(28, true));
    try std.testing.expect(!inetLengthValid(27, true));
    try std.testing.expect(unixLengthValid(3, 2));
    try std.testing.expect(!unixLengthValid(2, 2));
    try std.testing.expect(inet4FamilyValid(2));
    try std.testing.expect(!inet4FamilyValid(1));
    try std.testing.expect(optionalUserAddressValid(0, 0x8000));
    try std.testing.expect(!optionalUserAddressValid(0x8000, 0x8000));
}
