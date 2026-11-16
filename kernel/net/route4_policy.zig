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
