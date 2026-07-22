// kernel/net/ndp.zig — IPv6 Neighbor Discovery Protocol (RFC 4861).
//
// Provides:
//   - Neighbor cache (IPv6 → MAC mappings, with reachability state).
//   - EUI-64 link-local address generation from a 48-bit MAC.
//   - Lookup/update helpers used by upper layers and ICMPv6.
//   - Incomplete NS retransmit (SK-79), reachable→stale aging (SK-80),
//     and stale→delay→probe unicast NUD (SK-81).

const ipv6 = @import("ipv6.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

pub const MAX_NEIGHBORS: u32 = 64;

/// RFC 4861 default RetransTimer (ms).
pub const RETRANS_MS: u32 = 1000;
/// RFC 4861 MAX_MULTICAST_SOLICIT (initial NS + retransmits).
pub const MAX_MULTICAST_SOLICIT: u8 = 3;
/// RFC 4861 BaseReachableTime default (ms). SK-80 uses this as REACHABLE_TIME.
pub const REACHABLE_TIME_MS: u32 = 30_000;
/// RFC 4861 DELAY_FIRST_PROBE_TIME (ms).
pub const DELAY_FIRST_PROBE_TIME_MS: u32 = 5_000;
/// RFC 4861 MAX_UNICAST_SOLICIT.
pub const MAX_UNICAST_SOLICIT: u8 = 3;

pub const NeighborState = enum(u8) {
    incomplete = 0,
    reachable = 1,
    stale = 2,
    delay = 3,
    probe = 4,
};

/// Pending Neighbor Solicitation produced by `timerTick` (SK-79/81).
/// Zero `dst_mac` means multicast (solicited-node); otherwise unicast.
pub const Solicit = struct {
    target: [16]u8 = @splat(0),
    dst_mac: [6]u8 = @splat(0),
};

pub const NeighborEntry = struct {
    ipv6_addr: [16]u8 = @splat(0),
    mac_addr: [6]u8 = @splat(0),
    state: NeighborState = .incomplete,
    valid: bool = false,
    /// SK-79/81: ms since last NS for incomplete/probe entries.
    retrans_ms: u32 = 0,
    /// SK-79/81: NS transmissions so far in the current solicit phase.
    solicit_count: u8 = 0,
    /// SK-80/81: ms in reachable (aging) or delay (before first probe).
    age_ms: u32 = 0,
};

var neighbor_cache: [MAX_NEIGHBORS]NeighborEntry = @splat(.{});

/// SK-82: single default router learned from Router Advertisement.
var default_router_ip: [16]u8 = @splat(0);
var default_router_lifetime_sec: u16 = 0;
var default_router_valid: bool = false;

/// SK-83: on-link / PIO prefixes from Router Advertisement.
pub const MAX_PREFIXES: u32 = 8;
pub const PrefixEntry = struct {
    prefix: [16]u8 = @splat(0),
    prefix_len: u8 = 0,
    on_link: bool = false,
    autonomous: bool = false,
    valid_lifetime: u32 = 0,
    valid: bool = false,
};
var prefix_table: [MAX_PREFIXES]PrefixEntry = @splat(.{});

/// SK-84: SLAAC addresses formed from A-flag /64 prefixes.
pub const MAX_LOCAL_ADDRS: u32 = 4;
const LocalAddr = struct {
    addr: [16]u8 = @splat(0),
    /// Matching PIO prefix length (always 64 for SLAAC today).
    prefix_len: u8 = 0,
    valid: bool = false,
};
var local_addrs: [MAX_LOCAL_ADDRS]LocalAddr = @splat(.{});

// v53.40: Protect neighbor_cache against interrupt vs syscall races
var ndp_lock: IrqSpinlock = .{};

fn macIsZero(m: [6]u8) bool {
    return m[0] == 0 and m[1] == 0 and m[2] == 0 and m[3] == 0 and m[4] == 0 and m[5] == 0;
}

/// Reset/clear the neighbor cache. Called from net.init().
pub fn init() void {
    for (0..MAX_NEIGHBORS) |i| {
        neighbor_cache[i] = .{};
    }
    default_router_ip = @splat(0);
    default_router_lifetime_sec = 0;
    default_router_valid = false;
    for (0..MAX_PREFIXES) |i| {
        prefix_table[i] = .{};
    }
    for (0..MAX_LOCAL_ADDRS) |i| {
        local_addrs[i] = .{};
    }
}

/// Install or clear the default router from an RA (SK-82).
/// `lifetime_sec == 0` removes this router if it is the current default.
pub fn setDefaultRouter(ip: [16]u8, lifetime_sec: u16) void {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    if (lifetime_sec == 0) {
        if (default_router_valid and ipv6.addrEq(default_router_ip, ip)) {
            default_router_valid = false;
            default_router_lifetime_sec = 0;
            default_router_ip = @splat(0);
        }
        return;
    }
    default_router_ip = ip;
    default_router_lifetime_sec = lifetime_sec;
    default_router_valid = true;
}

/// Current default router IPv6 address, if any (SK-82).
pub fn getDefaultRouter() ?[16]u8 {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    if (!default_router_valid) return null;
    return default_router_ip;
}

/// Probe helper (SK-82): Router Lifetime seconds, or 0 if none.
pub fn probeDefaultRouterLifetime() u16 {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    if (!default_router_valid) return 0;
    return default_router_lifetime_sec;
}

/// Install or refresh a Prefix Information entry (SK-83).
/// `valid_lifetime == 0` deletes a matching prefix/len.
pub fn setPrefix(
    prefix: [16]u8,
    prefix_len: u8,
    on_link: bool,
    autonomous: bool,
    valid_lifetime: u32,
) void {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    if (prefix_len > 128) return;

    // Update or delete existing.
    for (0..MAX_PREFIXES) |i| {
        const e = &prefix_table[i];
        if (!e.valid) continue;
        if (e.prefix_len == prefix_len and ipv6.addrEq(e.prefix, prefix)) {
            if (valid_lifetime == 0) {
                e.* = .{};
            } else {
                e.on_link = on_link;
                e.autonomous = autonomous;
                e.valid_lifetime = valid_lifetime;
            }
            return;
        }
    }
    if (valid_lifetime == 0) return;

    // Insert into first free slot (drop if full).
    for (0..MAX_PREFIXES) |i| {
        const e = &prefix_table[i];
        if (!e.valid) {
            e.* = .{
                .prefix = prefix,
                .prefix_len = prefix_len,
                .on_link = on_link,
                .autonomous = autonomous,
                .valid_lifetime = valid_lifetime,
                .valid = true,
            };
            return;
        }
    }
}

/// True when `addr` is on-link (link-local or matching L-flag prefix) (SK-83).
pub fn isOnLink(addr: [16]u8) bool {
    if (ipv6.isLinkLocal(addr)) return true;
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    for (0..MAX_PREFIXES) |i| {
        const e = &prefix_table[i];
        if (!e.valid or !e.on_link or e.valid_lifetime == 0) continue;
        if (ipv6.prefixMatch(addr, e.prefix, e.prefix_len)) return true;
    }
    return false;
}

/// Probe helper (SK-83): number of valid prefix entries.
pub fn probePrefixCount() u32 {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    var n: u32 = 0;
    for (0..MAX_PREFIXES) |i| {
        if (prefix_table[i].valid) n += 1;
    }
    return n;
}

/// Form a /64 SLAAC address: prefix[0..8] || EUI-64(mac) (SK-84).
pub fn formSlaacAddress(prefix: [16]u8, mac: [6]u8) [16]u8 {
    var addr: [16]u8 = @splat(0);
    @memcpy(addr[0..8], prefix[0..8]);
    const iid = generateLinkLocal(mac);
    @memcpy(addr[8..16], iid[8..16]);
    return addr;
}

/// Install or remove a SLAAC address for an autonomous /64 prefix (SK-84).
/// `valid_lifetime == 0` removes any address formed from this prefix.
pub fn installSlaac(prefix: [16]u8, prefix_len: u8, valid_lifetime: u32, mac: [6]u8) void {
    if (prefix_len != 64) return;
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);

    if (valid_lifetime == 0) {
        for (0..MAX_LOCAL_ADDRS) |i| {
            const e = &local_addrs[i];
            if (!e.valid) continue;
            if (e.prefix_len == 64 and ipv6.prefixMatch(e.addr, prefix, 64)) {
                e.* = .{};
            }
        }
        return;
    }

    const addr = formSlaacAddress(prefix, mac);
    // Refresh existing.
    for (0..MAX_LOCAL_ADDRS) |i| {
        const e = &local_addrs[i];
        if (e.valid and ipv6.addrEq(e.addr, addr)) {
            e.prefix_len = 64;
            return;
        }
    }
    // Insert.
    for (0..MAX_LOCAL_ADDRS) |i| {
        const e = &local_addrs[i];
        if (!e.valid) {
            e.* = .{ .addr = addr, .prefix_len = 64, .valid = true };
            return;
        }
    }
}

/// True when `addr` is a configured local IPv6 address (SK-84).
pub fn hasLocalAddress(addr: [16]u8) bool {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    for (0..MAX_LOCAL_ADDRS) |i| {
        if (local_addrs[i].valid and ipv6.addrEq(local_addrs[i].addr, addr)) return true;
    }
    return false;
}

/// First configured non-link-local address, if any (SK-84).
pub fn getGlobalAddress() ?[16]u8 {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    for (0..MAX_LOCAL_ADDRS) |i| {
        if (!local_addrs[i].valid) continue;
        if (!ipv6.isLinkLocal(local_addrs[i].addr)) return local_addrs[i].addr;
    }
    return null;
}

/// Probe helper (SK-84): number of configured local addresses.
pub fn probeLocalAddrCount() u32 {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    var n: u32 = 0;
    for (0..MAX_LOCAL_ADDRS) |i| {
        if (local_addrs[i].valid) n += 1;
    }
    return n;
}

/// Lookup the cached MAC for a given IPv6 unicast address.
/// Returns null when no valid (reachable/stale/etc.) entry exists.
/// SK-81: first use of a `stale` entry moves it to `delay` (NUD).
pub fn lookup(ipv6_addr: [16]u8) ?[6]u8 {
    // v53.40: Acquire lock — neighbor_cache accessed from interrupt + syscall contexts
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    for (0..MAX_NEIGHBORS) |i| {
        const e = &neighbor_cache[i];
        if (!e.valid) continue;
        if (e.state == .incomplete) continue;
        if (!ipv6.addrEq(e.ipv6_addr, ipv6_addr)) continue;
        if (e.state == .stale) {
            e.state = .delay;
            e.age_ms = 0;
        }
        return e.mac_addr;
    }
    return null;
}

/// Insert or refresh an entry, marking it as `reachable`.
/// Mirrors the simple "always overwrite" cache strategy used by ARP.
pub fn update(ipv6_addr: [16]u8, mac_addr: [6]u8) void {
    // v53.40: Acquire lock — neighbor_cache accessed from interrupt + syscall contexts
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    // Refresh existing.
    for (0..MAX_NEIGHBORS) |i| {
        const e = &neighbor_cache[i];
        if (e.valid and ipv6.addrEq(e.ipv6_addr, ipv6_addr)) {
            e.mac_addr = mac_addr;
            e.state = .reachable;
            e.retrans_ms = 0;
            e.solicit_count = 0;
            e.age_ms = 0;
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
                .retrans_ms = 0,
                .solicit_count = 0,
                .age_ms = 0,
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
        .retrans_ms = 0,
        .solicit_count = 0,
        .age_ms = 0,
    };
}

/// Mark an entry as `incomplete` placeholder while NS is in flight.
/// Caller should send the initial NS immediately; `solicit_count` starts at 1.
/// Existing entries (any state) are left untouched so in-flight timers continue.
pub fn markIncomplete(ipv6_addr: [16]u8) void {
    // v53.40: Acquire lock — neighbor_cache accessed from interrupt + syscall contexts
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
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
                .retrans_ms = 0,
                .solicit_count = 1,
            };
            return;
        }
    }
}

fn pushSolicit(out: []Solicit, n: *u32, target: [16]u8, dst_mac: [6]u8) void {
    if (n.* >= out.len) return;
    out[n.*] = .{ .target = target, .dst_mac = dst_mac };
    n.* += 1;
}

/// Advance NDP timers (SK-79/80/81).
/// Writes pending NS work into `out`. Zero `dst_mac` = multicast NS.
/// Does not transmit — caller (icmpv6) sends to avoid ndp↔icmpv6 cycles.
pub fn timerTick(ms_elapsed: u32, out: []Solicit) u32 {
    if (ms_elapsed == 0) return 0;
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);

    var n: u32 = 0;
    for (0..MAX_NEIGHBORS) |i| {
        const e = &neighbor_cache[i];
        if (!e.valid) continue;

        switch (e.state) {
            .reachable => {
                e.age_ms +%= ms_elapsed;
                if (e.age_ms >= REACHABLE_TIME_MS) {
                    e.state = .stale;
                    e.age_ms = 0;
                }
            },
            .delay => {
                e.age_ms +%= ms_elapsed;
                if (e.age_ms >= DELAY_FIRST_PROBE_TIME_MS) {
                    e.state = .probe;
                    e.age_ms = 0;
                    e.retrans_ms = 0;
                    e.solicit_count = 1;
                    pushSolicit(out, &n, e.ipv6_addr, e.mac_addr);
                }
            },
            .probe => {
                e.retrans_ms +%= ms_elapsed;
                if (e.retrans_ms < RETRANS_MS) continue;
                e.retrans_ms = 0;
                if (e.solicit_count >= MAX_UNICAST_SOLICIT) {
                    e.valid = false;
                    continue;
                }
                e.solicit_count +%= 1;
                pushSolicit(out, &n, e.ipv6_addr, e.mac_addr);
            },
            .incomplete => {
                e.retrans_ms +%= ms_elapsed;
                if (e.retrans_ms < RETRANS_MS) continue;
                e.retrans_ms = 0;
                if (e.solicit_count >= MAX_MULTICAST_SOLICIT) {
                    e.valid = false;
                    continue;
                }
                e.solicit_count +%= 1;
                pushSolicit(out, &n, e.ipv6_addr, @splat(0));
            },
            .stale => {},
        }
    }
    return n;
}

/// True when `s` requests a multicast (solicited-node) NS.
pub fn solicitIsMulticast(s: Solicit) bool {
    return macIsZero(s.dst_mac);
}

/// Probe helper (SK-79): true when `ipv6_addr` is a valid incomplete entry.
pub fn probeIsIncomplete(ipv6_addr: [16]u8) bool {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    for (0..MAX_NEIGHBORS) |i| {
        const e = &neighbor_cache[i];
        if (e.valid and e.state == .incomplete and ipv6.addrEq(e.ipv6_addr, ipv6_addr))
            return true;
    }
    return false;
}

/// Probe helper (SK-79): solicit_count for an entry, or 0xFF.
pub fn probeSolicitCount(ipv6_addr: [16]u8) u8 {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    for (0..MAX_NEIGHBORS) |i| {
        const e = &neighbor_cache[i];
        if (e.valid and ipv6.addrEq(e.ipv6_addr, ipv6_addr)) return e.solicit_count;
    }
    return 0xFF;
}

/// Probe helper (SK-80/81): neighbor state, or null if missing/invalid.
pub fn probeState(ipv6_addr: [16]u8) ?NeighborState {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    for (0..MAX_NEIGHBORS) |i| {
        const e = &neighbor_cache[i];
        if (e.valid and ipv6.addrEq(e.ipv6_addr, ipv6_addr)) return e.state;
    }
    return null;
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
