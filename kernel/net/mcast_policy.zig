//! IPv6 multicast group membership of one UDP socket (IPV6_ADD_MEMBERSHIP / IPV6_DROP_MEMBERSHIP) and the rules that decide
//! which sockets take a datagram sent to a group (Linux ipv6_sock_mc_join/drop, inet6_mc_check, __udp6_lib_mcast_deliver).

const std = @import("std");
const bap = @import("bind_addr_policy.zig");

/// Groups one socket can join at once. Linux bounds this by the socket's optmem (one ipv6_mc_socklist per group; a socket joined
/// 2340 on the host with the default optmem_max); here a fixed table per socket, the join past it is ENOMEM as in Linux.
pub const MAX_GROUPS = 64;

pub const EINVAL: i64 = -22;
pub const EADDRINUSE: i64 = -98;
pub const EADDRNOTAVAIL: i64 = -99;
pub const ENODEV: i64 = -19;
pub const ENOMEM: i64 = -12;

pub const Membership = struct {
    group: [MAX_GROUPS][16]u8 = @splat(@splat(0)),
    /// The interface each group was joined on (1 lo, 2 the NIC).
    ifindex: [MAX_GROUPS]u8 = @splat(0),
    n: u8 = 0,
};

pub fn isMulticast(addr: [16]u8) bool {
    return addr[0] == 0xff;
}

fn eql(a: [16]u8, b: [16]u8) bool {
    return @as(u128, @bitCast(a)) == @as(u128, @bitCast(b));
}

/// The interface a join on `ifindex` lands on: the NIC for 0 (the route to a group leaves through it), else the named one when it
/// exists. Null is ENODEV (Linux ip6_mc_find_dev; with only lo up a join on 0 finds no route).
pub fn deviceFor(ifindex: u32, nic_active: bool) ?u8 {
    if (ifindex == 0) return if (nic_active) @intCast(bap.NIC_IFINDEX) else null;
    if (ifindex == bap.LO_IFINDEX) return @intCast(bap.LO_IFINDEX);
    if (ifindex == bap.NIC_IFINDEX and nic_active) return @intCast(bap.NIC_IFINDEX);
    return null;
}

/// IPV6_ADD_MEMBERSHIP: EINVAL for a non-multicast address, EADDRINUSE when the socket already has the group on that interface
/// (any interface for 0), ENOMEM when the table is full, ENODEV for an interface that does not exist; checked in that order.
pub fn join(m: *Membership, group: [16]u8, ifindex: u32, nic_active: bool) i64 {
    if (!isMulticast(group)) return EINVAL;
    for (0..m.n) |i| {
        if ((ifindex == 0 or m.ifindex[i] == ifindex) and eql(m.group[i], group)) return EADDRINUSE;
    }
    if (m.n == MAX_GROUPS) return ENOMEM;
    const dev = deviceFor(ifindex, nic_active) orelse return ENODEV;
    m.group[m.n] = group;
    m.ifindex[m.n] = dev;
    m.n += 1;
    return 0;
}

/// IPV6_DROP_MEMBERSHIP: EINVAL for a non-multicast address, EADDRNOTAVAIL when the socket has no such membership.
pub fn drop(m: *Membership, group: [16]u8, ifindex: u32) i64 {
    if (!isMulticast(group)) return EINVAL;
    for (0..m.n) |i| {
        if ((ifindex == 0 or m.ifindex[i] == ifindex) and eql(m.group[i], group)) {
            m.n -= 1;
            m.group[i] = m.group[m.n];
            m.ifindex[i] = m.ifindex[m.n];
            m.group[m.n] = @splat(0);
            m.ifindex[m.n] = 0;
            return 0;
        }
    }
    return EADDRNOTAVAIL;
}

/// Whether the socket joined `group` on interface `ifindex` (any interface when null).
pub fn joinedOn(m: *const Membership, group: [16]u8, ifindex: ?u8) bool {
    for (0..m.n) |i| {
        if (eql(m.group[i], group) and (ifindex == null or m.ifindex[i] == ifindex.?)) return true;
    }
    return false;
}

/// Groups every interface is in without a join: interface-local and link-local all-nodes (ff01::1, ff02::1).
pub fn alwaysJoined(group: [16]u8) bool {
    if (group[0] != 0xff or (group[1] != 0x01 and group[1] != 0x02)) return false;
    return std.mem.allEqual(u8, group[2..15], 0) and group[15] == 1;
}

/// Whether a socket takes a datagram to `group` that reached the host (inet6_mc_check without source filters): it joined the
/// group, or IPV6_MULTICAST_ALL is on (the default).
pub fn socketAccepts(m: *const Membership, mc_all: bool, group: [16]u8) bool {
    return joinedOn(m, group, null) or mc_all;
}

/// Whether a socket bound to `bound` (and connected to `peer_ip`:`peer_port` when that port is nonzero) is a candidate for a
/// datagram from `src_ip`:`src_port` to `group` that arrived on interface `dif` (__udp_v6_is_mcast_sock): bound to :: or to the
/// group itself, not connected to another peer, and not tied to another interface (`bound_dev`, 0 for none).
pub fn socketMatches(bound: [16]u8, group: [16]u8, peer_port: u16, peer_ip: [16]u8, src_ip: [16]u8, src_port: u16, bound_dev: u8, dif: u8) bool {
    if (bound_dev != 0 and bound_dev != dif) return false;
    if (@as(u128, @bitCast(bound)) != 0 and !eql(bound, group)) return false;
    if (peer_port != 0 and (peer_port != src_port or !eql(peer_ip, src_ip))) return false;
    return true;
}

/// The interface a datagram to a group leaves through: IPV6_MULTICAST_IF when set, else the NIC.
pub fn outInterface(mc_if: u8) u8 {
    return if (mc_if != 0) mc_if else @intCast(bap.NIC_IFINDEX);
}

/// Groups one IPv4 socket can join at once (Linux net.ipv4.igmp_max_memberships, default 20; the join past it is ENOBUFS).
pub const MAX_GROUPS4 = 20;
pub const ENOBUFS: i64 = -105;

pub const Membership4 = struct {
    group: [MAX_GROUPS4][4]u8 = @splat(.{ 0, 0, 0, 0 }),
    /// The interface address the join named (0.0.0.0 when it named none) and the interface it landed on (1 lo, 2 the NIC).
    addr: [MAX_GROUPS4][4]u8 = @splat(.{ 0, 0, 0, 0 }),
    ifindex: [MAX_GROUPS4]u8 = @splat(0),
    n: u8 = 0,
};

pub fn isMulticast4(addr: [4]u8) bool {
    return addr[0] >= 224 and addr[0] <= 239;
}

fn eql4(a: [4]u8, b: [4]u8) bool {
    return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
}

/// The interface an IPv4 group request lands on (Linux ip_mc_find_dev): the index when given, else the interface owning `addr`,
/// else the one the route to the group leaves through (the NIC). Null is ENODEV.
pub fn deviceFor4(addr: [4]u8, index: u32, nic_active: bool, our: [4]u8) ?u8 {
    if (index != 0 or @as(u32, @bitCast(addr)) != 0) return @import("ip_opt_policy.zig").ifaceOf4(addr, index, nic_active, our);
    return if (nic_active) @intCast(bap.NIC_IFINDEX) else null;
}

/// IP_ADD_MEMBERSHIP (ip_mc_join_group): EINVAL for a non-multicast group, ENODEV when the interface does not exist, EADDRINUSE when
/// the socket already has the group on that interface, ENOBUFS past MAX_GROUPS4; checked in that order.
pub fn join4(m: *Membership4, group: [4]u8, addr: [4]u8, index: u32, nic_active: bool, our: [4]u8) i64 {
    if (!isMulticast4(group)) return EINVAL;
    const dev = deviceFor4(addr, index, nic_active, our) orelse return ENODEV;
    for (0..m.n) |i| {
        if (eql4(m.group[i], group) and m.ifindex[i] == dev) return EADDRINUSE;
    }
    if (m.n == MAX_GROUPS4) return ENOBUFS;
    m.group[m.n] = group;
    m.addr[m.n] = addr;
    m.ifindex[m.n] = dev;
    m.n += 1;
    return 0;
}

/// IP_DROP_MEMBERSHIP (ip_mc_leave_group): ENODEV when neither an index nor an address is given and no route leads to the group;
/// otherwise the membership of `group` on the resolved index, or (no index found) the one joined with that interface address, is
/// removed, and none is EADDRNOTAVAIL. A non-multicast group is simply not found.
pub fn drop4(m: *Membership4, group: [4]u8, addr: [4]u8, index: u32, nic_active: bool, our: [4]u8) i64 {
    const dev = deviceFor4(addr, index, nic_active, our);
    if (index == 0 and @as(u32, @bitCast(addr)) == 0 and dev == null) return ENODEV;
    const ifx: u32 = if (index != 0) index else if (dev) |d| d else 0;
    for (0..m.n) |i| {
        if (!eql4(m.group[i], group)) continue;
        if (ifx != 0) {
            if (m.ifindex[i] != ifx) continue;
        } else if (@as(u32, @bitCast(addr)) != 0 and !eql4(addr, m.addr[i])) continue;
        m.n -= 1;
        m.group[i] = m.group[m.n];
        m.addr[i] = m.addr[m.n];
        m.ifindex[i] = m.ifindex[m.n];
        m.group[m.n] = .{ 0, 0, 0, 0 };
        m.addr[m.n] = .{ 0, 0, 0, 0 };
        m.ifindex[m.n] = 0;
        return 0;
    }
    return EADDRNOTAVAIL;
}

/// Whether the socket joined `group` on interface `ifindex` (any interface when null).
pub fn joined4(m: *const Membership4, group: [4]u8, ifindex: ?u8) bool {
    for (0..m.n) |i| {
        if (eql4(m.group[i], group) and (ifindex == null or m.ifindex[i] == ifindex.?)) return true;
    }
    return false;
}

/// 224.0.0.1 (all hosts): every interface is in it without a join.
pub fn alwaysJoined4(group: [4]u8) bool {
    return eql4(group, .{ 224, 0, 0, 1 });
}

/// Whether a socket takes an IPv4 datagram to `group` that arrived on interface `ifindex` (ip_mc_sf_allow without source filters:
/// the membership must be on that interface): it joined the group there, or IP_MULTICAST_ALL is on.
pub fn socketAccepts4(m: *const Membership4, mc_all: bool, group: [4]u8, ifindex: u8) bool {
    return joined4(m, group, ifindex) or mc_all;
}

/// __udp_is_mcast_sock for IPv4: bound to 0.0.0.0 or the group, and not connected to another peer (the peer address is in the first
/// 4 bytes of `peer_ip`).
pub fn socketMatches4(bound: [4]u8, group: [4]u8, peer_port: u16, peer_ip: [16]u8, src_ip: [4]u8, src_port: u16) bool {
    if (@as(u32, @bitCast(bound)) != 0 and !eql4(bound, group)) return false;
    if (peer_port != 0 and (peer_port != src_port or !eql4(peer_ip[0..4].*, src_ip))) return false;
    return true;
}

/// The source address of an IPv4 datagram to a group from a socket bound to `bound`: the IP_MULTICAST_IF address `mc_addr` when the
/// socket is unbound and one was given; null leaves the choice to tcp_port_policy.sourceAddr.
pub fn multicastSource4(group: bool, bound: [4]u8, mc_addr: [4]u8) ?[4]u8 {
    if (!group or @as(u32, @bitCast(bound)) != 0 or @as(u32, @bitCast(mc_addr)) == 0) return null;
    return mc_addr;
}

/// The Ethernet address of an IPv4 group (RFC 1112 §6.4): 01:00:5e and the low 23 bits of the group.
pub fn multicastMac4(group: [4]u8) [6]u8 {
    return .{ 0x01, 0x00, 0x5e, group[1] & 0x7f, group[2], group[3] };
}
