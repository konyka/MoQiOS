//! IPv6 multicast group membership of one UDP socket (IPV6_ADD_MEMBERSHIP / IPV6_DROP_MEMBERSHIP) and the rules that decide
//! which sockets take a datagram sent to a group (Linux ipv6_sock_mc_join/drop, inet6_mc_check, __udp6_lib_mcast_deliver).

const std = @import("std");
const bap = @import("bind_addr_policy.zig");

/// Groups one socket can join at once (Linux bounds this by optmem; here a fixed table, the join past it is ENOMEM).
pub const MAX_GROUPS = 8;

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
/// datagram from `src_ip`:`src_port` to `group` (__udp_v6_is_mcast_sock): bound to :: or to the group itself, and not connected
/// to another peer.
pub fn socketMatches(bound: [16]u8, group: [16]u8, peer_port: u16, peer_ip: [16]u8, src_ip: [16]u8, src_port: u16) bool {
    if (@as(u128, @bitCast(bound)) != 0 and !eql(bound, group)) return false;
    if (peer_port != 0 and (peer_port != src_port or !eql(peer_ip, src_ip))) return false;
    return true;
}

/// The interface a datagram to a group leaves through: IPV6_MULTICAST_IF when set, else the NIC.
pub fn outInterface(mc_if: u8) u8 {
    return if (mc_if != 0) mc_if else @intCast(bap.NIC_IFINDEX);
}
