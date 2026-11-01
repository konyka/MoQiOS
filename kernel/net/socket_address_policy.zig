//! Pure sockaddr length policy for connect.

const std = @import("std");

pub fn inetLengthValid(addr_len: u32, is_v6: bool) bool {
    const minimum: u32 = if (is_v6) 28 else 16;
    return addr_len >= minimum;
}

pub fn unixLengthValid(addr_len: u32, path_offset: u32) bool {
    return addr_len > path_offset;
}

/// sockaddr_un for a socket named `path` (empty = the unnamed address, just the
/// family). Returns the address length: 2 + path + NUL for a named socket.
pub fn unixNameEncode(path: []const u8, out: []u8) u32 {
    std.mem.writeInt(u16, out[0..2], 1, .little); // AF_UNIX
    if (path.len == 0) return 2;
    @memcpy(out[2..][0..path.len], path);
    out[2 + path.len] = 0;
    return @intCast(2 + path.len + 1);
}

pub fn inet4FamilyValid(family: u16) bool {
    return family == 2;
}

pub fn optionalUserAddressValid(addr: u64, user_limit: u64) bool {
    return addr == 0 or addr < user_limit;
}
