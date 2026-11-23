const std = @import("std");
const kt = @import("kernel_shared");
const rp = kt.raw_icmp_policy;
const mc = kt.mcast_policy;

// raw_v6_match: a socket bound to a unicast address still takes a packet to a multicast address when inet6_mc_check passes: it
// joined the group, or IPV6_MULTICAST_ALL is on (the default). Before this the bound address had to equal the destination.
test "an IPv6 raw socket bound to a unicast address takes multicast it joined or IPV6_MULTICAST_ALL lets through (hello500)" {
    const lo6: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    const any: [16]u8 = @splat(0);
    const grp: [16]u8 = .{ 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 3 };
    const other: [16]u8 = .{ 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 4 };
    var m: mc.Membership = .{};
    // Not joined: IPV6_MULTICAST_ALL decides.
    try std.testing.expect(rp.matches6Mc(lo6, any, lo6, grp, &m, true));
    try std.testing.expect(!rp.matches6Mc(lo6, any, lo6, grp, &m, false));
    // Joined: taken even with IPV6_MULTICAST_ALL off, but not for another group.
    try std.testing.expectEqual(@as(i64, 0), mc.join(&m, grp, 1, false));
    try std.testing.expect(rp.matches6Mc(lo6, any, lo6, grp, &m, false));
    try std.testing.expect(!rp.matches6Mc(lo6, any, lo6, other, &m, false));
    // Unicast destinations keep the old rule: the bound address must match.
    const other_uc: [16]u8 = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 };
    try std.testing.expect(!rp.matches6Mc(lo6, any, lo6, other_uc, &m, true));
    try std.testing.expect(rp.matches6Mc(lo6, any, other_uc, lo6, &m, false));
    // A connected peer still filters by source.
    try std.testing.expect(!rp.matches6Mc(lo6, lo6, other_uc, grp, &m, true));
    // Unbound sockets are unchanged.
    try std.testing.expect(rp.matches6Mc(any, any, lo6, grp, &m, false));
}

// raw_v4_local_deliver: after raw_v4_match (whose address checks are unchanged), ip_mc_sf_allow decides a packet to a group: taken when
// the socket joined it on the arrival interface, else only with IP_MULTICAST_ALL (the default). Unicast destinations always pass.
test "an IPv4 raw socket takes a group only if it joined it on that interface or IP_MULTICAST_ALL is on (hello500)" {
    const grp = [4]u8{ 224, 1, 2, 3 };
    const uc = [4]u8{ 127, 0, 0, 1 };
    var m: mc.Membership4 = .{};
    try std.testing.expect(rp.mcAllow4(&m, true, uc, 1));
    try std.testing.expect(rp.mcAllow4(&m, false, uc, 1));
    try std.testing.expect(rp.mcAllow4(&m, true, grp, 1));
    try std.testing.expect(!rp.mcAllow4(&m, false, grp, 1));
    try std.testing.expectEqual(@as(i64, 0), mc.join4(&m, grp, .{ 0, 0, 0, 0 }, 1, false, .{ 10, 0, 2, 15 }));
    try std.testing.expect(rp.mcAllow4(&m, false, grp, 1));
    // Joined on lo only: a copy that arrived on the NIC is not taken without IP_MULTICAST_ALL.
    try std.testing.expect(!rp.mcAllow4(&m, false, grp, 2));
}
