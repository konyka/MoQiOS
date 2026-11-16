//! IPv4 next-hop choice for the NIC (Linux fib_lookup with one connected route and a default route).

/// The address ARP resolves to reach `dst`: `dst` itself when it is on the interface's subnet (`our`/`mask`), else the default
/// gateway `gw`; with no gateway (0.0.0.0) every address is tried on the link.
pub fn nextHop4(dst: [4]u8, our: [4]u8, mask: [4]u8, gw: [4]u8) [4]u8 {
    if (@as(u32, @bitCast(gw)) == 0) return dst;
    for (0..4) |k| {
        if ((dst[k] & mask[k]) != (our[k] & mask[k])) return gw;
    }
    return dst;
}

/// Whether `ip` is this host's: the 127/8 block or the interface's own address `our`. Traffic to it goes over lo (Linux routes a
/// local address through the local table to the loopback device), and the loopback-only replies (RST, port unreachable) apply.
pub fn isLocal4(ip: [4]u8, our: [4]u8) bool {
    return ip[0] == 127 or @as(u32, @bitCast(ip)) == @as(u32, @bitCast(our));
}

pub const EINVAL: i64 = -22;

/// A socket bound to a 127/8 address may only reach destinations routed through lo: another 127/8 address, this host's own `our`,
/// the limited broadcast and multicast (ip_route_output_key_hash_rcu sends those from a local source address without a route, so
/// they never reach __mkroute_output's check). Anything else leaves through the NIC, and a loopback source on a non-loopback device
/// is EINVAL (net/ipv4/route.c __mkroute_output, route_localnet off). 0 when the destination is fine.
pub fn loopbackSourceErrno(bound: [4]u8, dst: [4]u8, our: [4]u8) i64 {
    if (bound[0] != 127) return 0;
    if (isLocal4(dst, our)) return 0;
    if (@as(u32, @bitCast(dst)) == 0xffff_ffff) return 0;
    if (dst[0] >= 224 and dst[0] <= 239) return 0;
    if (@as(u32, @bitCast(dst)) == 0) return 0;
    return EINVAL;
}
