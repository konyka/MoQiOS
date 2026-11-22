//! The local-address portion of bind() checks (Linux inet_bind / inet6_bind).
//! Socket FREEBIND/TRANSPARENT options and the two ip_nonlocal_bind sysctls are applied by socket_syscall.
//! An address that is neither this host's own, a broadcast, a multicast group nor the wildcard is
//! EADDRNOTAVAIL. The check comes before the port checks (EACCES, EADDRINUSE) as in Linux.

const std = @import("std");

pub const EADDRNOTAVAIL: i64 = -99;
pub const EINVAL: i64 = -22;
pub const ENODEV: i64 = -19;

/// Interface indices, as SIOCGIFINDEX reports them: lo is always 1, the NIC (eth0) is 2 while it is up.
pub const LO_IFINDEX: u32 = 1;
pub const NIC_IFINDEX: u32 = 2;

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

/// Whether `addr` means something only together with an interface: link-local unicast (fe80::/10), interface-local multicast
/// (ff01::/16) or link-local multicast (ff02::/16) (Linux __ipv6_addr_needs_scope_id).
pub fn needsScope6(addr: [16]u8) bool {
    return (addr[0] == 0xfe and (addr[1] & 0xc0) == 0x80) or (addr[0] == 0xff and ((addr[1] & 0x0f) == 1 or (addr[1] & 0x0f) == 2));
}

/// The interface bind() ties an IPv6 socket to (Linux sk_bound_dev_if from sin6_scope_id): the scope of an address that needs one
/// (checked by inet6ScopeErrno first), 0 (none) for any other address.
pub fn boundDev6(addr: [16]u8, scope_id: u32) u8 {
    return if (needsScope6(addr)) @truncate(scope_id) else 0;
}

/// Two sockets on one port can conflict only when one of them is not tied to an interface or both are tied to the same one (Linux
/// inet_bind_conflict).
pub fn boundDevsConflict(a: u8, b: u8) bool {
    return a == 0 or b == 0 or a == b;
}

pub const ENETUNREACH: i64 = -101;

/// An interface index from a sin6_scope_id; one too large for any interface names none that exists.
fn ifIndex8(scope_id: u32) u8 {
    return if (scope_id > 255) 255 else @intCast(scope_id);
}

/// The interface an IPv6 datagram to `dst` leaves through (Linux udpv6_sendmsg's flowi6_oif): the sendto scope of an address that
/// needs one, else the interface the socket is tied to, else IPV6_MULTICAST_IF for a group. 0 is the default route.
pub fn sendOif6(dst: [16]u8, scope_id: u32, bound_dev: u8, mc_if: u8) u8 {
    if (scope_id != 0 and needsScope6(dst)) return ifIndex8(scope_id);
    if (bound_dev != 0) return bound_dev;
    return if (dst[0] == 0xff) mc_if else 0;
}

/// Whether `dst` has a route out of interface `oif` (0 the default route): lo carries only ::1, the NIC everything, an interface
/// that does not exist nothing (ENETUNREACH).
pub fn routeErrno6(dst: [16]u8, oif: u8) i64 {
    if (oif == 0 or oif == NIC_IFINDEX) return 0;
    const loop6 = blk: {
        var l: [16]u8 = @splat(0);
        l[15] = 1;
        break :blk l;
    };
    if (oif == LO_IFINDEX and std.mem.eql(u8, &dst, &loop6)) return 0;
    return ENETUNREACH;
}

pub const Connect6 = struct {
    /// The interface the socket is tied to afterwards (kept even when `err` is a route error).
    dev: u8,
    err: i64,
};

/// connect() of an IPv6 datagram socket tied to `bound_dev` (0 none) to `dst` with `scope_id` (Linux __ip6_datagram_connect): an
/// address that needs a scope ties the socket to the scope's interface, which must be the one it is already tied to (EINVAL), or
/// for a group with no scope to IPV6_MULTICAST_IF; with no interface at all it is EINVAL. The route is then checked through that
/// interface (or IPV6_MULTICAST_IF for any group), and a failure there leaves the socket tied.
pub fn connectDev6(dst: [16]u8, scope_id: u32, bound_dev: u8, mc_if: u8) Connect6 {
    var dev = bound_dev;
    const group = dst[0] == 0xff;
    if (needsScope6(dst)) {
        if (scope_id != 0) {
            if (dev != 0 and dev != scope_id) return .{ .dev = dev, .err = EINVAL };
            dev = ifIndex8(scope_id);
        }
        if (dev == 0 and group) dev = mc_if;
        if (dev == 0) return .{ .dev = dev, .err = EINVAL };
    }
    const oif = if (dev == 0 and group) mc_if else dev;
    return .{ .dev = dev, .err = routeErrno6(dst, oif) };
}

/// connect() of an IPv6 stream socket tied to `bound_dev` (0 none) to `dst` with `scope_id` (Linux tcp_v6_connect): a group is
/// ENETUNREACH before anything else; a link-local peer's scope must match the bound interface (EINVAL) and ties the socket to it,
/// and with no interface at all it is EINVAL. The route is then checked through that interface, and a failure leaves it tied.
pub fn streamConnectDev6(dst: [16]u8, scope_id: u32, bound_dev: u8) Connect6 {
    if (dst[0] == 0xff) return .{ .dev = bound_dev, .err = ENETUNREACH };
    var dev = bound_dev;
    if (needsScope6(dst)) {
        if (scope_id != 0) {
            if (dev != 0 and dev != scope_id) return .{ .dev = dev, .err = EINVAL };
            dev = ifIndex8(scope_id);
        }
        if (dev == 0) return .{ .dev = dev, .err = EINVAL };
    }
    return .{ .dev = dev, .err = routeErrno6(dst, dev) };
}

/// An IPv6 stream socket cannot bind a multicast address (Linux __inet6_bind: EINVAL before the scope checks).
pub fn streamBindErrno6(addr: [16]u8) i64 {
    return if (addr[0] == 0xff) EINVAL else 0;
}

/// bind()'s check of sin6_scope_id, made before the address check (Linux inet6_bind): a link-scoped address without an interface is
/// EINVAL, an interface that does not exist ENODEV, and a link-local unicast address on lo (which has none) EADDRNOTAVAIL. Any other
/// address ignores the scope. Returns 0 when the bind may go on.
pub fn inet6ScopeErrno(addr: [16]u8, scope_id: u32, nic_active: bool) i64 {
    if (!needsScope6(addr)) return 0;
    if (scope_id == 0) return EINVAL;
    if (scope_id != LO_IFINDEX and !(nic_active and scope_id == NIC_IFINDEX)) return ENODEV;
    if (scope_id == LO_IFINDEX and addr[0] == 0xfe) return EADDRNOTAVAIL;
    return 0;
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
