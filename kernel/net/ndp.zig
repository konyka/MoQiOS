// kernel/net/ndp.zig — IPv6 Neighbor Discovery Protocol (RFC 4861).
//
// Provides:
//   - Neighbor cache (IPv6 → MAC mappings, with reachability state).
//   - EUI-64 link-local address generation from a 48-bit MAC.
//   - Lookup/update helpers used by upper layers and ICMPv6.

const ipv6 = @import("ipv6.zig");

pub const MAX_NEIGHBORS: u32 = 64;

pub const NeighborState = enum(u8) {
    incomplete = 0,
    reachable = 1,
    stale = 2,
    delay = 3,
    probe = 4,
};

pub const NeighborEntry = struct {
    ipv6_addr: [16]u8 = @splat(0),
    mac_addr: [6]u8 = @splat(0),
    state: NeighborState = .incomplete,
    valid: bool = false,
};

var neighbor_cache: [MAX_NEIGHBORS]NeighborEntry = @splat(.{});

/// Reset/clear the neighbor cache. Called from net.init().
pub fn init() void {
    for (0..MAX_NEIGHBORS) |i| {
        neighbor_cache[i] = .{};
    }
}

/// Lookup the cached MAC for a given IPv6 unicast address.
/// Returns null when no valid (reachable/stale/etc.) entry exists.
pub fn lookup(ipv6_addr: [16]u8) ?[6]u8 {
    for (0..MAX_NEIGHBORS) |i| {
        const e = &neighbor_cache[i];
        if (!e.valid) continue;
        if (e.state == .incomplete) continue;
        if (ipv6.addrEq(e.ipv6_addr, ipv6_addr)) return e.mac_addr;
    }
    return null;
}

/// Insert or refresh an entry, marking it as `reachable`.
/// Mirrors the simple "always overwrite" cache strategy used by ARP.
pub fn update(ipv6_addr: [16]u8, mac_addr: [6]u8) void {
    // Refresh existing.
    for (0..MAX_NEIGHBORS) |i| {
        const e = &neighbor_cache[i];
        if (e.valid and ipv6.addrEq(e.ipv6_addr, ipv6_addr)) {
            e.mac_addr = mac_addr;
            e.state = .reachable;
            return;
        }
    }
    // Insert into first free slot.
    for (0..MAX_NEIGHBORS) |i| {
        const e = &neighbor_cache[i];
        if (!e.valid) {
            e.* = .{
                .ipv6_addr = ipv6_addr,
                .mac_addr = mac_addr,
                .state = .reachable,
                .valid = true,
            };
            return;
        }
    }
    // Cache full — overwrite slot 0 (simple eviction policy).
    neighbor_cache[0] = .{
        .ipv6_addr = ipv6_addr,
        .mac_addr = mac_addr,
        .state = .reachable,
        .valid = true,
    };
}

/// Mark an entry as `incomplete` placeholder while NS is in flight.
/// Returns true on success.
pub fn markIncomplete(ipv6_addr: [16]u8) void {
    for (0..MAX_NEIGHBORS) |i| {
        const e = &neighbor_cache[i];
        if (e.valid and ipv6.addrEq(e.ipv6_addr, ipv6_addr)) return;
    }
    for (0..MAX_NEIGHBORS) |i| {
        const e = &neighbor_cache[i];
        if (!e.valid) {
            e.* = .{
                .ipv6_addr = ipv6_addr,
                .mac_addr = @splat(0),
                .state = .incomplete,
                .valid = true,
            };
            return;
        }
    }
}

/// Generate an IPv6 link-local address (fe80::/64) from a 48-bit MAC using
/// modified EUI-64 (RFC 4291 §2.5.1):
///   - Insert 0xFFFE between bytes 3 and 4 of the MAC.
///   - Flip the U/L bit (bit 1 of the first byte).
pub fn generateLinkLocal(mac: [6]u8) [16]u8 {
    var addr: [16]u8 = @splat(0);
    addr[0] = 0xFE;
    addr[1] = 0x80;
    // bytes 2..7 stay zero (the link-local prefix interior)
    addr[8] = mac[0] ^ 0x02; // flip U/L bit
    addr[9] = mac[1];
    addr[10] = mac[2];
    addr[11] = 0xFF;
    addr[12] = 0xFE;
    addr[13] = mac[3];
    addr[14] = mac[4];
    addr[15] = mac[5];
    return addr;
}
