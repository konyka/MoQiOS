//! Pure sockaddr length policy for connect.

const std = @import("std");

pub fn inetLengthValid(addr_len: u32, is_v6: bool) bool {
    const minimum: u32 = if (is_v6) 28 else 16;
    return addr_len >= minimum;
}

pub fn unixLengthValid(addr_len: u32, path_offset: u32) bool {
    return addr_len > path_offset;
}

/// Length of the name in a sockaddr_un whose bytes after the family are `name` (already cut to addr_len - 2). A pathname runs to its first NUL;
/// an abstract name (first byte NUL) is every byte given, NULs included, so "\0a" and "\0a\0" are different names. A pathname is never empty
/// and never starts with NUL, so the two kinds cannot collide when compared as bytes.
pub fn unixNameLen(name: []const u8) usize {
    if (name.len > 0 and name[0] == 0) return name.len;
    return std.mem.indexOfScalar(u8, name, 0) orelse name.len;
}

pub fn unixIsAbstract(name: []const u8) bool {
    return name.len > 0 and name[0] == 0;
}

/// sockaddr_un for a socket named `path` (empty = the unnamed address, just the family). Returns the address length: 2 + path + NUL for a
/// pathname, 2 + name (no terminator) for an abstract name.
pub fn unixNameEncode(path: []const u8, out: []u8) u32 {
    std.mem.writeInt(u16, out[0..2], 1, .little); // AF_UNIX
    if (path.len == 0) return 2;
    @memcpy(out[2..][0..path.len], path);
    if (unixIsAbstract(path)) return @intCast(2 + path.len);
    out[2 + path.len] = 0;
    return @intCast(2 + path.len + 1);
}

pub const DgramConnect = enum { einval, eafnosupport, disconnect, address };

/// What connect() on a datagram socket does with an address of `addr_len` bytes whose family is `family`: shorter than the family
/// field is EINVAL; AF_UNSPEC dissolves the association (Linux inet_dgram_connect); anything else goes through the address checks.
pub fn dgramConnectAction(addr_len: u32, family: u16) DgramConnect {
    if (addr_len < 2) return .einval;
    if (family == 0) return .disconnect;
    return .address;
}

/// dgramConnectAction for an AF_INET6 socket (always V6ONLY in MoQiOS): __ip6_datagram_connect refuses AF_INET before it looks at
/// the length, so a 16-byte sockaddr_in is EAFNOSUPPORT rather than EINVAL.
pub fn dgramConnectAction6(addr_len: u32, family: u16) DgramConnect {
    const a = dgramConnectAction(addr_len, family);
    if (a == .address and family == 2) return .eafnosupport;
    return a;
}

pub fn inet4FamilyValid(family: u16) bool {
    return family == 2;
}

pub fn optionalUserAddressValid(addr: u64, user_limit: u64) bool {
    return addr == 0 or addr < user_limit;
}
