//! Pure sockaddr_in / sockaddr_in6 encode/decode (Linux layout).
//!
//! Used by the socket syscall layer so AF_INET6 UDP can round-trip without
//! embedding layout constants in every call site. Probeable on non-x86.

const bo = @import("../lib/byte_order.zig");

pub const AF_INET: u16 = 2;
pub const AF_INET6: u16 = 10;

/// Bytes userspace commonly passes for `sockaddr_in` (with padding).
pub const SOCKADDR_IN_LEN: u32 = 16;
/// `sizeof(struct sockaddr_in6)` on Linux.
pub const SOCKADDR_IN6_LEN: u32 = 28;

pub const Inet4 = struct {
    port: u16,
    addr: [4]u8,
};

pub const Inet6 = struct {
    port: u16,
    addr: [16]u8,
    scope_id: u32 = 0,
};

fn readFamilyLe(buf: []const u8) u16 {
    return @as(u16, buf[0]) | (@as(u16, buf[1]) << 8);
}

fn writeFamilyLe(buf: []u8, family: u16) void {
    buf[0] = @truncate(family);
    buf[1] = @truncate(family >> 8);
}

/// Parse `sockaddr_in`. Accepts a buffer of at least 8 bytes (port + addr).
pub fn parseInet4(buf: []const u8) ?Inet4 {
    if (buf.len < 8) return null;
    if (readFamilyLe(buf) != AF_INET) return null;
    return .{
        .port = bo.readU16BeAt(buf.ptr, 2),
        .addr = .{ buf[4], buf[5], buf[6], buf[7] },
    };
}

/// Parse `sockaddr_in6`. Requires the full 28-byte structure.
pub fn parseInet6(buf: []const u8) ?Inet6 {
    if (buf.len < SOCKADDR_IN6_LEN) return null;
    if (readFamilyLe(buf) != AF_INET6) return null;
    var addr: [16]u8 = undefined;
    @memcpy(&addr, buf[8..24]);
    const scope = @as(u32, buf[24]) |
        (@as(u32, buf[25]) << 8) |
        (@as(u32, buf[26]) << 16) |
        (@as(u32, buf[27]) << 24);
    return .{
        .port = bo.readU16BeAt(buf.ptr, 2),
        .addr = addr,
        .scope_id = scope,
    };
}

/// Write a minimal `sockaddr_in` (8 bytes used; zeros the rest of `buf`).
/// Returns the POSIX address length (16).
pub fn writeInet4(buf: []u8, port: u16, addr: [4]u8) u32 {
    if (buf.len < 8) return 0;
    @memset(buf, 0);
    writeFamilyLe(buf, AF_INET);
    bo.writeU16BeAt(buf.ptr, 2, port);
    buf[4] = addr[0];
    buf[5] = addr[1];
    buf[6] = addr[2];
    buf[7] = addr[3];
    return SOCKADDR_IN_LEN;
}

/// Write a full `sockaddr_in6`. Returns 28 on success.
pub fn writeInet6(buf: []u8, port: u16, addr: [16]u8, scope_id: u32) u32 {
    if (buf.len < SOCKADDR_IN6_LEN) return 0;
    @memset(buf, 0);
    writeFamilyLe(buf, AF_INET6);
    bo.writeU16BeAt(buf.ptr, 2, port);
    // flowinfo @4 stays 0
    @memcpy(buf[8..24], &addr);
    buf[24] = @truncate(scope_id);
    buf[25] = @truncate(scope_id >> 8);
    buf[26] = @truncate(scope_id >> 16);
    buf[27] = @truncate(scope_id >> 24);
    return SOCKADDR_IN6_LEN;
}

/// Encode a local/peer name for UDP or TCP (SK-73/78). Same sockaddr layout.
pub fn encodeInetName(is_v6: bool, port: u16, ip4: [4]u8, ip6: [16]u8, out: []u8) u32 {
    if (is_v6) return writeInet6(out, port, ip6, 0);
    return writeInet4(out, port, ip4);
}

/// Encode a UDP local/peer name for either address family (SK-73).
pub fn encodeUdpName(is_v6: bool, port: u16, ip4: [4]u8, ip6: [16]u8, out: []u8) u32 {
    return encodeInetName(is_v6, port, ip4, ip6, out);
}
