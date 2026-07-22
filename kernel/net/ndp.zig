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
/// RFC 4862 DupAddrDetectTransmits default.
pub const DUP_ADDR_DETECT_TRANSMITS: u8 = 1;

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

/// SK-82/89/92/93: default router list from Router Advertisements.
pub const MAX_DEFAULT_ROUTERS: u32 = 4;
const DefaultRouterEntry = struct {
    ip: [16]u8 = @splat(0),
    lifetime_sec: u16 = 0,
    /// SK-89: ms accumulated toward the next whole-second lifetime tick.
    age_ms: u32 = 0,
    /// SK-93: NUD probe/incomplete exhausted; skip while alternatives exist.
    nud_failed: bool = false,
    valid: bool = false,
};
var default_routers: [MAX_DEFAULT_ROUTERS]DefaultRouterEntry = @splat(.{});
/// Sticky selected index; `MAX_DEFAULT_ROUTERS` means none (SK-92).
var default_router_sel: u32 = MAX_DEFAULT_ROUTERS;

/// SK-83: on-link / PIO prefixes from Router Advertisement.
pub const MAX_PREFIXES: u32 = 8;
/// RFC 4861: Valid Lifetime 0xffffffff means infinity (no aging).
pub const PREFIX_LIFETIME_INFINITY: u32 = 0xffff_ffff;
pub const PrefixEntry = struct {
    prefix: [16]u8 = @splat(0),
    prefix_len: u8 = 0,
    on_link: bool = false,
    autonomous: bool = false,
    valid_lifetime: u32 = 0,
    /// SK-90: ms accumulated toward the next whole-second lifetime tick.
    age_ms: u32 = 0,
    valid: bool = false,
};
var prefix_table: [MAX_PREFIXES]PrefixEntry = @splat(.{});

/// SK-94: more-specific routes from RA Route Information (RFC 4191).
pub const MAX_ROUTES: u32 = 8;
const RouteEntry = struct {
    prefix: [16]u8 = @splat(0),
    prefix_len: u8 = 0,
    lifetime_sec: u32 = 0,
    age_ms: u32 = 0,
    /// -1 low, 0 medium, 1 high.
    preference: i8 = 0,
    next_hop: [16]u8 = @splat(0),
    valid: bool = false,
};
var route_table: [MAX_ROUTES]RouteEntry = @splat(.{});

/// SK-95: Destination Cache entries from ICMPv6 Redirect (RFC 4861 §8).
pub const MAX_DEST_CACHE: u32 = 8;
/// How long a redirect stays installed without refresh (seconds).
pub const REDIRECT_LIFETIME_SEC: u32 = 600;
const DestCacheEntry = struct {
    destination: [16]u8 = @splat(0),
    /// Better first hop; equal to `destination` means on-link redirect.
    next_hop: [16]u8 = @splat(0),
    lifetime_sec: u32 = 0,
    age_ms: u32 = 0,
    valid: bool = false,
};
var dest_cache: [MAX_DEST_CACHE]DestCacheEntry = @splat(.{});

/// SK-84/85/91: SLAAC addresses formed from A-flag /64 prefixes.
pub const MAX_LOCAL_ADDRS: u32 = 4;
pub const AddrState = enum(u8) {
    tentative = 0,
    preferred = 1,
    /// SK-91: Preferred Lifetime expired; still valid but not for new TX.
    deprecated = 2,
};
const LocalAddr = struct {
    addr: [16]u8 = @splat(0),
    /// Matching PIO prefix length (always 64 for SLAAC today).
    prefix_len: u8 = 0,
    state: AddrState = .tentative,
    /// SK-91: remaining Preferred Lifetime seconds (infinity = no aging).
    preferred_lifetime: u32 = 0,
    /// SK-91: ms accumulated toward the next whole-second preferred tick.
    preferred_age_ms: u32 = 0,
    /// SK-85: ms since last DAD NS.
    dad_ms: u32 = 0,
    /// SK-85: DAD NS transmissions completed.
    dad_sent: u8 = 0,
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
    for (0..MAX_DEFAULT_ROUTERS) |i| {
        default_routers[i] = .{};
    }
    default_router_sel = MAX_DEFAULT_ROUTERS;
    for (0..MAX_PREFIXES) |i| {
        prefix_table[i] = .{};
    }
    for (0..MAX_ROUTES) |i| {
        route_table[i] = .{};
    }
    for (0..MAX_DEST_CACHE) |i| {
        dest_cache[i] = .{};
    }
    for (0..MAX_LOCAL_ADDRS) |i| {
        local_addrs[i] = .{};
    }
}

fn countDefaultRoutersLocked() u32 {
    var n: u32 = 0;
    for (0..MAX_DEFAULT_ROUTERS) |i| {
        if (default_routers[i].valid) n += 1;
    }
    return n;
}

/// True when a usable (non-incomplete) neighbor MAC is cached (no NUD side effects).
fn neighborHasMacLocked(ip: [16]u8) bool {
    for (0..MAX_NEIGHBORS) |i| {
        const e = &neighbor_cache[i];
        if (!e.valid or e.state == .incomplete) continue;
        if (ipv6.addrEq(e.ipv6_addr, ip) and !macIsZero(e.mac_addr)) return true;
    }
    return false;
}

/// SK-93: selecting a stale default router starts DELAY without waiting for TX.
fn nudgeStaleToDelayLocked(ip: [16]u8) void {
    for (0..MAX_NEIGHBORS) |i| {
        const e = &neighbor_cache[i];
        if (!e.valid or e.state != .stale) continue;
        if (!ipv6.addrEq(e.ipv6_addr, ip)) continue;
        e.state = .delay;
        e.age_ms = 0;
        return;
    }
}

fn markDefaultRouterNudFailedLocked(ip: [16]u8) void {
    for (0..MAX_DEFAULT_ROUTERS) |i| {
        const e = &default_routers[i];
        if (!e.valid or !ipv6.addrEq(e.ip, ip)) continue;
        e.nud_failed = true;
        if (default_router_sel == i) default_router_sel = MAX_DEFAULT_ROUTERS;
        return;
    }
}

/// SK-96: drop Destination Cache entries whose next hop became unreachable.
fn invalidateDestCacheByNextHopLocked(next_hop: [16]u8) void {
    for (0..MAX_DEST_CACHE) |i| {
        const e = &dest_cache[i];
        if (e.valid and ipv6.addrEq(e.next_hop, next_hop)) {
            e.* = .{};
        }
    }
}

fn onNeighborUnreachableLocked(ip: [16]u8) void {
    markDefaultRouterNudFailedLocked(ip);
    invalidateDestCacheByNextHopLocked(ip);
}

fn clearDefaultRouterNudFailedLocked(ip: [16]u8) void {
    for (0..MAX_DEFAULT_ROUTERS) |i| {
        const e = &default_routers[i];
        if (e.valid and ipv6.addrEq(e.ip, ip)) {
            e.nud_failed = false;
            return;
        }
    }
}

/// Pick a default router (SK-92/93): prefer !nud_failed + MAC; skip failed while alternatives exist.
fn selectDefaultRouterLocked() ?*DefaultRouterEntry {
    if (default_router_sel < MAX_DEFAULT_ROUTERS) {
        const cur = &default_routers[default_router_sel];
        if (cur.valid and !cur.nud_failed and neighborHasMacLocked(cur.ip)) {
            nudgeStaleToDelayLocked(cur.ip);
            return cur;
        }
    }
    for (0..MAX_DEFAULT_ROUTERS) |i| {
        const e = &default_routers[i];
        if (e.valid and !e.nud_failed and neighborHasMacLocked(e.ip)) {
            default_router_sel = @intCast(i);
            nudgeStaleToDelayLocked(e.ip);
            return e;
        }
    }
    if (default_router_sel < MAX_DEFAULT_ROUTERS) {
        const cur = &default_routers[default_router_sel];
        if (cur.valid and !cur.nud_failed) {
            nudgeStaleToDelayLocked(cur.ip);
            return cur;
        }
    }
    for (0..MAX_DEFAULT_ROUTERS) |i| {
        const e = &default_routers[i];
        if (e.valid and !e.nud_failed) {
            default_router_sel = @intCast(i);
            nudgeStaleToDelayLocked(e.ip);
            return e;
        }
    }
    // Last resort: retry a nud_failed router (may re-solicit).
    for (0..MAX_DEFAULT_ROUTERS) |i| {
        if (default_routers[i].valid) {
            default_router_sel = @intCast(i);
            return &default_routers[i];
        }
    }
    default_router_sel = MAX_DEFAULT_ROUTERS;
    return null;
}

/// Install, refresh, or remove a default router from an RA (SK-82/92).
/// `lifetime_sec == 0` removes this router from the list.
pub fn setDefaultRouter(ip: [16]u8, lifetime_sec: u16) void {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    if (lifetime_sec == 0) {
        for (0..MAX_DEFAULT_ROUTERS) |i| {
            const e = &default_routers[i];
            if (e.valid and ipv6.addrEq(e.ip, ip)) {
                e.* = .{};
                if (default_router_sel == i) default_router_sel = MAX_DEFAULT_ROUTERS;
                return;
            }
        }
        return;
    }
    for (0..MAX_DEFAULT_ROUTERS) |i| {
        const e = &default_routers[i];
        if (e.valid and ipv6.addrEq(e.ip, ip)) {
            e.lifetime_sec = lifetime_sec;
            e.age_ms = 0;
            e.nud_failed = false;
            return;
        }
    }
    for (0..MAX_DEFAULT_ROUTERS) |i| {
        const e = &default_routers[i];
        if (!e.valid) {
            e.* = .{
                .ip = ip,
                .lifetime_sec = lifetime_sec,
                .age_ms = 0,
                .nud_failed = false,
                .valid = true,
            };
            return;
        }
    }
    // Full: replace the entry with the shortest remaining lifetime.
    var victim: u32 = 0;
    var min_life = default_routers[0].lifetime_sec;
    for (1..MAX_DEFAULT_ROUTERS) |i| {
        if (default_routers[i].lifetime_sec < min_life) {
            min_life = default_routers[i].lifetime_sec;
            victim = @intCast(i);
        }
    }
    default_routers[victim] = .{
        .ip = ip,
        .lifetime_sec = lifetime_sec,
        .age_ms = 0,
        .nud_failed = false,
        .valid = true,
    };
    if (default_router_sel == victim) default_router_sel = MAX_DEFAULT_ROUTERS;
}

/// Current default router IPv6 address, if any (SK-82/92).
pub fn getDefaultRouter() ?[16]u8 {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    const e = selectDefaultRouterLocked() orelse return null;
    return e.ip;
}

/// Probe helper (SK-82/89): remaining Router Lifetime of the selected router.
pub fn probeDefaultRouterLifetime() u16 {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    const e = selectDefaultRouterLocked() orelse return 0;
    return e.lifetime_sec;
}

/// Probe helper (SK-92): number of default routers in the list.
pub fn probeDefaultRouterCount() u32 {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    return countDefaultRoutersLocked();
}

/// Probe helper (SK-93): true when this default router is marked NUD-failed.
pub fn probeDefaultRouterNudFailed(ip: [16]u8) bool {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    for (0..MAX_DEFAULT_ROUTERS) |i| {
        const e = &default_routers[i];
        if (e.valid and ipv6.addrEq(e.ip, ip)) return e.nud_failed;
    }
    return false;
}

/// Age all default-router Router Lifetimes (SK-89/92).
/// Returns true when the list becomes empty (caller may restart RS).
pub fn routerLifetimeTimerTick(ms_elapsed: u32) bool {
    if (ms_elapsed == 0) return false;
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    const had_any = countDefaultRoutersLocked() != 0;
    if (!had_any) return false;

    for (0..MAX_DEFAULT_ROUTERS) |i| {
        const e = &default_routers[i];
        if (!e.valid) continue;
        e.age_ms +%= ms_elapsed;
        while (e.age_ms >= 1000 and e.lifetime_sec > 0) {
            e.age_ms -= 1000;
            e.lifetime_sec -= 1;
        }
        if (e.lifetime_sec == 0) {
            e.* = .{};
            if (default_router_sel == i) default_router_sel = MAX_DEFAULT_ROUTERS;
        }
    }
    return countDefaultRoutersLocked() == 0;
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
                clearSlaacForPrefixLocked(e.prefix, e.prefix_len);
                e.* = .{};
            } else {
                e.on_link = on_link;
                e.autonomous = autonomous;
                e.valid_lifetime = valid_lifetime;
                e.age_ms = 0;
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
                .age_ms = 0,
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

/// Probe helper (SK-90): remaining Valid Lifetime seconds, or 0 if absent.
pub fn probePrefixLifetime(prefix: [16]u8, prefix_len: u8) u32 {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    for (0..MAX_PREFIXES) |i| {
        const e = &prefix_table[i];
        if (!e.valid) continue;
        if (e.prefix_len == prefix_len and ipv6.addrEq(e.prefix, prefix)) {
            return e.valid_lifetime;
        }
    }
    return 0;
}

fn clearSlaacForPrefixLocked(prefix: [16]u8, prefix_len: u8) void {
    for (0..MAX_LOCAL_ADDRS) |i| {
        const e = &local_addrs[i];
        if (!e.valid) continue;
        if (e.prefix_len == prefix_len and ipv6.prefixMatch(e.addr, prefix, prefix_len)) {
            e.* = .{};
        }
    }
}

/// Age Prefix Information Valid Lifetimes (SK-90).
/// Expired prefixes are cleared; matching SLAAC addresses are abandoned.
pub fn prefixLifetimeTimerTick(ms_elapsed: u32) void {
    if (ms_elapsed == 0) return;
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    for (0..MAX_PREFIXES) |i| {
        const e = &prefix_table[i];
        if (!e.valid) continue;
        if (e.valid_lifetime == 0 or e.valid_lifetime == PREFIX_LIFETIME_INFINITY) continue;

        e.age_ms +%= ms_elapsed;
        while (e.age_ms >= 1000 and e.valid_lifetime > 0 and e.valid_lifetime != PREFIX_LIFETIME_INFINITY) {
            e.age_ms -= 1000;
            e.valid_lifetime -= 1;
        }
        if (e.valid_lifetime == 0) {
            clearSlaacForPrefixLocked(e.prefix, e.prefix_len);
            e.* = .{};
        }
    }
}

/// Install, refresh, or delete a Route Information entry (SK-94).
/// `lifetime_sec == 0` removes the matching prefix/len/next-hop route.
pub fn setRoute(
    prefix: [16]u8,
    prefix_len: u8,
    lifetime_sec: u32,
    preference: i8,
    next_hop: [16]u8,
) void {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    if (prefix_len > 128) return;

    for (0..MAX_ROUTES) |i| {
        const e = &route_table[i];
        if (!e.valid) continue;
        if (e.prefix_len == prefix_len and ipv6.addrEq(e.prefix, prefix) and ipv6.addrEq(e.next_hop, next_hop)) {
            if (lifetime_sec == 0) {
                e.* = .{};
            } else {
                e.lifetime_sec = lifetime_sec;
                e.age_ms = 0;
                e.preference = preference;
            }
            return;
        }
    }
    if (lifetime_sec == 0) return;

    for (0..MAX_ROUTES) |i| {
        const e = &route_table[i];
        if (!e.valid) {
            e.* = .{
                .prefix = prefix,
                .prefix_len = prefix_len,
                .lifetime_sec = lifetime_sec,
                .age_ms = 0,
                .preference = preference,
                .next_hop = next_hop,
                .valid = true,
            };
            return;
        }
    }
}

fn findBestRouteLocked(dst: [16]u8) ?[16]u8 {
    var best_len: i16 = -1;
    var best_pref: i8 = -128;
    var best_nh: ?[16]u8 = null;
    for (0..MAX_ROUTES) |i| {
        const e = &route_table[i];
        if (!e.valid or e.lifetime_sec == 0) continue;
        if (!ipv6.prefixMatch(dst, e.prefix, e.prefix_len)) continue;
        const plen: i16 = e.prefix_len;
        if (plen > best_len or (plen == best_len and e.preference > best_pref)) {
            best_len = plen;
            best_pref = e.preference;
            best_nh = e.next_hop;
        }
    }
    return best_nh;
}

/// Probe helper (SK-94): number of Route Information entries.
pub fn probeRouteCount() u32 {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    var n: u32 = 0;
    for (0..MAX_ROUTES) |i| {
        if (route_table[i].valid) n += 1;
    }
    return n;
}

/// Probe helper (SK-94): next hop for best matching route, if any.
pub fn probeBestRouteNextHop(dst: [16]u8) ?[16]u8 {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    return findBestRouteLocked(dst);
}

/// Age Route Information lifetimes (SK-94).
pub fn routeLifetimeTimerTick(ms_elapsed: u32) void {
    if (ms_elapsed == 0) return;
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    for (0..MAX_ROUTES) |i| {
        const e = &route_table[i];
        if (!e.valid) continue;
        if (e.lifetime_sec == 0 or e.lifetime_sec == PREFIX_LIFETIME_INFINITY) continue;
        e.age_ms +%= ms_elapsed;
        while (e.age_ms >= 1000 and e.lifetime_sec > 0 and e.lifetime_sec != PREFIX_LIFETIME_INFINITY) {
            e.age_ms -= 1000;
            e.lifetime_sec -= 1;
        }
        if (e.lifetime_sec == 0) e.* = .{};
    }
}

/// Form a /64 SLAAC address: prefix[0..8] || EUI-64(mac) (SK-84).
pub fn formSlaacAddress(prefix: [16]u8, mac: [6]u8) [16]u8 {
    var addr: [16]u8 = @splat(0);
    @memcpy(addr[0..8], prefix[0..8]);
    const iid = generateLinkLocal(mac);
    @memcpy(addr[8..16], iid[8..16]);
    return addr;
}

/// Install or remove a SLAAC address for an autonomous /64 prefix (SK-84/85/91).
/// `valid_lifetime == 0` removes any address formed from this prefix.
/// `preferred_lifetime` is clamped to `valid_lifetime`; refresh may restore
/// a deprecated address to preferred (SK-91).
/// On new install, returns the tentative address so the caller can send DAD NS.
pub fn installSlaac(
    prefix: [16]u8,
    prefix_len: u8,
    valid_lifetime: u32,
    preferred_lifetime: u32,
    mac: [6]u8,
) ?[16]u8 {
    if (prefix_len != 64) return null;
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
        return null;
    }

    const pref: u32 = if (preferred_lifetime > valid_lifetime) valid_lifetime else preferred_lifetime;
    const addr = formSlaacAddress(prefix, mac);
    // Existing: refresh preferred lifetime; do not re-trigger DAD.
    for (0..MAX_LOCAL_ADDRS) |i| {
        const e = &local_addrs[i];
        if (e.valid and ipv6.addrEq(e.addr, addr)) {
            e.prefix_len = 64;
            e.preferred_lifetime = pref;
            e.preferred_age_ms = 0;
            if (pref == 0) {
                if (e.state == .preferred) e.state = .deprecated;
            } else if (e.state == .deprecated) {
                e.state = .preferred;
            }
            return null;
        }
    }
    // Insert as tentative; first DAD NS is sent by caller.
    for (0..MAX_LOCAL_ADDRS) |i| {
        const e = &local_addrs[i];
        if (!e.valid) {
            e.* = .{
                .addr = addr,
                .prefix_len = 64,
                .state = .tentative,
                .preferred_lifetime = pref,
                .preferred_age_ms = 0,
                .dad_ms = 0,
                .dad_sent = 1,
                .valid = true,
            };
            return addr;
        }
    }
    return null;
}

/// True when `addr` is a configured local IPv6 address (any state).
pub fn hasLocalAddress(addr: [16]u8) bool {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    for (0..MAX_LOCAL_ADDRS) |i| {
        if (local_addrs[i].valid and ipv6.addrEq(local_addrs[i].addr, addr)) return true;
    }
    return false;
}

/// First *preferred* non-link-local address, if any (SK-85: DAD must pass).
pub fn getGlobalAddress() ?[16]u8 {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    for (0..MAX_LOCAL_ADDRS) |i| {
        const e = &local_addrs[i];
        if (!e.valid or e.state != .preferred) continue;
        if (!ipv6.isLinkLocal(e.addr)) return e.addr;
    }
    return null;
}

/// Select IPv6 source address for `dst` (SK-86, RFC 6724 simplified).
/// Link-local destinations use link-local source; otherwise prefer a
/// preferred global that shares a /64 with `dst`, else any preferred global,
/// else fall back to link-local.
pub fn selectSourceAddress(dst: [16]u8, mac: [6]u8) [16]u8 {
    const ll = generateLinkLocal(mac);
    if (ipv6.isLinkLocal(dst)) return ll;

    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);

    var fallback: ?[16]u8 = null;
    for (0..MAX_LOCAL_ADDRS) |i| {
        const e = &local_addrs[i];
        if (!e.valid or e.state != .preferred) continue;
        if (ipv6.isLinkLocal(e.addr)) continue;
        if (ipv6.prefixMatch(dst, e.addr, e.prefix_len)) return e.addr;
        if (fallback == null) fallback = e.addr;
    }
    return fallback orelse ll;
}

/// Next-hop resolution result (SK-87).
pub const NextHop = struct {
    /// L2 destination when resolved.
    mac: ?[6]u8 = null,
    /// Neighbor to solicit when `mac` is null (dst or default router).
    solicit: ?[16]u8 = null,
};

fn lookupDestCacheLocked(dst: [16]u8) ?[16]u8 {
    for (0..MAX_DEST_CACHE) |i| {
        const e = &dest_cache[i];
        if (e.valid and ipv6.addrEq(e.destination, dst)) return e.next_hop;
    }
    return null;
}

fn currentFirstHopLocked(dst: [16]u8) ?[16]u8 {
    // Redirect takes precedence once installed; for validation use RIO/default only.
    if (findBestRouteLocked(dst)) |nh| return nh;
    const e = selectDefaultRouterLocked() orelse return null;
    return e.ip;
}

/// True when `src` is the current first-hop for `dst` (RIO or default) (SK-95).
pub fn isCurrentFirstHop(dst: [16]u8, src: [16]u8) bool {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    const hop = currentFirstHopLocked(dst) orelse return false;
    return ipv6.addrEq(hop, src);
}

/// Install/refresh a Destination Cache entry from Redirect (SK-95).
pub fn applyRedirect(destination: [16]u8, next_hop: [16]u8) void {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    for (0..MAX_DEST_CACHE) |i| {
        const e = &dest_cache[i];
        if (e.valid and ipv6.addrEq(e.destination, destination)) {
            e.next_hop = next_hop;
            e.lifetime_sec = REDIRECT_LIFETIME_SEC;
            e.age_ms = 0;
            return;
        }
    }
    for (0..MAX_DEST_CACHE) |i| {
        const e = &dest_cache[i];
        if (!e.valid) {
            e.* = .{
                .destination = destination,
                .next_hop = next_hop,
                .lifetime_sec = REDIRECT_LIFETIME_SEC,
                .age_ms = 0,
                .valid = true,
            };
            return;
        }
    }
    // Full: overwrite slot 0.
    dest_cache[0] = .{
        .destination = destination,
        .next_hop = next_hop,
        .lifetime_sec = REDIRECT_LIFETIME_SEC,
        .age_ms = 0,
        .valid = true,
    };
}

/// Probe helper (SK-95): Destination Cache next hop, if any.
pub fn probeDestCacheNextHop(destination: [16]u8) ?[16]u8 {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    return lookupDestCacheLocked(destination);
}

/// Probe helper (SK-95): number of Destination Cache entries.
pub fn probeDestCacheCount() u32 {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    var n: u32 = 0;
    for (0..MAX_DEST_CACHE) |i| {
        if (dest_cache[i].valid) n += 1;
    }
    return n;
}

/// Age Destination Cache redirect lifetimes (SK-95).
pub fn destCacheTimerTick(ms_elapsed: u32) void {
    if (ms_elapsed == 0) return;
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    for (0..MAX_DEST_CACHE) |i| {
        const e = &dest_cache[i];
        if (!e.valid) continue;
        e.age_ms +%= ms_elapsed;
        while (e.age_ms >= 1000 and e.lifetime_sec > 0) {
            e.age_ms -= 1000;
            e.lifetime_sec -= 1;
        }
        if (e.lifetime_sec == 0) e.* = .{};
    }
}

/// Resolve L2 next hop for IPv6 `dst` (SK-87/94/95).
/// On-link / link-local: NDP of `dst`. Multicast: derived multicast MAC.
/// Off-link: Destination Cache redirect, else RIO, else default router.
pub fn resolveNextHop(dst: [16]u8) NextHop {
    if (ipv6.isMulticast(dst)) {
        return .{ .mac = ipv6.multicastMac(dst) };
    }
    // SK-95: on-link redirect (target == destination) before prefix on-link check.
    const redirected = blk: {
        const flags = ndp_lock.acquire();
        defer ndp_lock.release(flags);
        break :blk lookupDestCacheLocked(dst);
    };
    if (redirected) |nh| {
        const l3 = if (ipv6.addrEq(nh, dst)) dst else nh;
        if (lookup(l3)) |m| return .{ .mac = m };
        markIncomplete(l3);
        return .{ .solicit = l3 };
    }
    if (ipv6.isLinkLocal(dst) or isOnLink(dst)) {
        if (lookup(dst)) |m| return .{ .mac = m };
        markIncomplete(dst);
        return .{ .solicit = dst };
    }
    // Off-link: more-specific RIO (SK-94), else default router (SK-87).
    const rtr = blk: {
        const flags = ndp_lock.acquire();
        defer ndp_lock.release(flags);
        if (findBestRouteLocked(dst)) |nh| break :blk nh;
        break :blk null;
    } orelse getDefaultRouter() orelse return .{};
    if (lookup(rtr)) |m| return .{ .mac = m };
    markIncomplete(rtr);
    return .{ .solicit = rtr };
}

/// Probe helper (SK-84/85): number of configured local addresses.
pub fn probeLocalAddrCount() u32 {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    var n: u32 = 0;
    for (0..MAX_LOCAL_ADDRS) |i| {
        if (local_addrs[i].valid) n += 1;
    }
    return n;
}

/// Probe helper (SK-85): address DAD/preferred/deprecated state, or null if missing.
pub fn probeAddrState(addr: [16]u8) ?AddrState {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    for (0..MAX_LOCAL_ADDRS) |i| {
        if (local_addrs[i].valid and ipv6.addrEq(local_addrs[i].addr, addr))
            return local_addrs[i].state;
    }
    return null;
}

/// Probe helper (SK-91): remaining Preferred Lifetime seconds, or 0 if absent.
pub fn probePreferredLifetime(addr: [16]u8) u32 {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    for (0..MAX_LOCAL_ADDRS) |i| {
        if (local_addrs[i].valid and ipv6.addrEq(local_addrs[i].addr, addr))
            return local_addrs[i].preferred_lifetime;
    }
    return 0;
}

/// Age SLAAC Preferred Lifetimes (SK-91). At zero, preferred → deprecated.
pub fn preferredLifetimeTimerTick(ms_elapsed: u32) void {
    if (ms_elapsed == 0) return;
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    for (0..MAX_LOCAL_ADDRS) |i| {
        const e = &local_addrs[i];
        if (!e.valid) continue;
        if (e.preferred_lifetime == PREFIX_LIFETIME_INFINITY) continue;
        if (e.preferred_lifetime == 0) {
            if (e.state == .preferred) e.state = .deprecated;
            continue;
        }
        // Age while tentative or preferred so the clock starts at install.
        if (e.state != .tentative and e.state != .preferred) continue;

        e.preferred_age_ms +%= ms_elapsed;
        while (e.preferred_age_ms >= 1000 and e.preferred_lifetime > 0 and
            e.preferred_lifetime != PREFIX_LIFETIME_INFINITY)
        {
            e.preferred_age_ms -= 1000;
            e.preferred_lifetime -= 1;
        }
        if (e.preferred_lifetime == 0 and e.state == .preferred) {
            e.state = .deprecated;
        }
    }
}

/// Advance DAD timers (SK-85). After DupAddrDetectTransmits × RetransTimer
/// with no conflict, marks the address preferred (or deprecated if Preferred
/// Lifetime is already zero). May emit extra DAD targets into `out` when
/// DupAddrDetectTransmits > 1.
pub fn dadTimerTick(ms_elapsed: u32, out: [][16]u8) u32 {
    if (ms_elapsed == 0) return 0;
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);

    var n: u32 = 0;
    for (0..MAX_LOCAL_ADDRS) |i| {
        const e = &local_addrs[i];
        if (!e.valid or e.state != .tentative) continue;
        e.dad_ms +%= ms_elapsed;
        if (e.dad_ms < RETRANS_MS) continue;
        e.dad_ms = 0;
        if (e.dad_sent >= DUP_ADDR_DETECT_TRANSMITS) {
            e.state = if (e.preferred_lifetime == 0) .deprecated else .preferred;
            continue;
        }
        e.dad_sent +%= 1;
        if (n < out.len) {
            out[n] = e.addr;
            n += 1;
        }
    }
    return n;
}

/// DAD conflict: abandon a tentative address matching `target` (SK-85).
pub fn dadConflict(target: [16]u8) void {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    for (0..MAX_LOCAL_ADDRS) |i| {
        const e = &local_addrs[i];
        if (!e.valid or e.state != .tentative) continue;
        if (ipv6.addrEq(e.addr, target)) {
            e.* = .{};
            return;
        }
    }
}

/// True when `target` is one of our tentative addresses (SK-85).
pub fn isTentative(target: [16]u8) bool {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    for (0..MAX_LOCAL_ADDRS) |i| {
        const e = &local_addrs[i];
        if (e.valid and e.state == .tentative and ipv6.addrEq(e.addr, target)) return true;
    }
    return false;
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
            clearDefaultRouterNudFailedLocked(ipv6_addr);
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
            clearDefaultRouterNudFailedLocked(ipv6_addr);
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
    clearDefaultRouterNudFailedLocked(ipv6_addr);
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
                    // SK-93/96: NUD failure → router failover + clear redirects.
                    onNeighborUnreachableLocked(e.ipv6_addr);
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
                    onNeighborUnreachableLocked(e.ipv6_addr);
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
