//! Which local addresses bind() accepts (Linux inet_bind / inet6_bind without IP_FREEBIND).
//!
//! An address that is neither this host's own, a broadcast, a multicast group nor the wildcard is
//! EADDRNOTAVAIL. The check comes before the port checks (EACCES, EADDRINUSE) as in Linux.

const std = @import("std");

pub const EADDRNOTAVAIL: i64 = -99;

pub const Nic = struct {
    active: bool = false,
    ip: [4]u8 = .{ 0, 0, 0, 0 },
    netmask: [4]u8 = .{ 255, 255, 255, 0 },
    link_local6: [16]u8 = @splat(0),
};

fn isBroadcastOf(addr: [4]u8, nic: Nic) bool {
    for (0..4) |k| {
        if (addr[k] != (nic.ip[k] | ~nic.netmask[k])) return false;
    }
    return true;
}

/// 0.0.0.0, 127/8, 224/4 (multicast), 255.255.255.255, and the NIC's address and subnet broadcast.
pub fn inet4Bindable(addr: [4]u8, nic: Nic) bool {
    if (std.mem.eql(u8, &addr, &[4]u8{ 0, 0, 0, 0 })) return true;
    if (addr[0] == 127) return true;
    if (addr[0] >= 224 and addr[0] <= 239) return true;
    if (std.mem.eql(u8, &addr, &[4]u8{ 255, 255, 255, 255 })) return true;
    if (!nic.active) return false;
    return std.mem.eql(u8, &addr, &nic.ip) or isBroadcastOf(addr, nic);
}

fn mappedV4(addr: [16]u8) ?[4]u8 {
    if (!std.mem.allEqual(u8, addr[0..10], 0)) return null;
    if (addr[10] != 0xff or addr[11] != 0xff) return null;
    return .{ addr[12], addr[13], addr[14], addr[15] };
}

/// ::, ::1, ff00::/8, a v4-mapped address whose IPv4 part is bindable, the NIC's link-local address,
/// and any address in `configured`.
pub fn inet6Bindable(addr: [16]u8, nic: Nic, configured: bool) bool {
    const head_zero = std.mem.allEqual(u8, addr[0..15], 0);
    if (head_zero and (addr[15] == 0 or addr[15] == 1)) return true;
    if (addr[0] == 0xff) return true;
    if (mappedV4(addr)) |v4| return inet4Bindable(v4, nic);
    if (configured) return true;
    return nic.active and std.mem.eql(u8, &addr, &nic.link_local6);
}
