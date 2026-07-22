// kernel/net/ndp.zig — IPv6 Neighbor Discovery Protocol (RFC 4861).
//
// Provides:
//   - Neighbor cache (IPv6 → MAC mappings, with reachability state).
//   - EUI-64 link-local address generation from a 48-bit MAC.
//   - Lookup/update helpers used by upper layers and ICMPv6.
//   - Incomplete-entry NS retransmit schedule (SK-79; RFC 4861 RetransTimer).

const ipv6 = @import("ipv6.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

pub const MAX_NEIGHBORS: u32 = 64;

/// RFC 4861 default RetransTimer (ms).
pub const RETRANS_MS: u32 = 1000;
/// RFC 4861 MAX_MULTICAST_SOLICIT (initial NS + retransmits).
pub const MAX_MULTICAST_SOLICIT: u8 = 3;
/// RFC 4861 BaseReachableTime default (ms). SK-80 uses this as REACHABLE_TIME.
pub const REACHABLE_TIME_MS: u32 = 30_000;

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
    /// SK-79: ms since last NS for incomplete entries.
    retrans_ms: u32 = 0,
    /// SK-79: NS transmissions so far (1 = initial send by caller).
    solicit_count: u8 = 0,
    /// SK-80: ms spent in `reachable` (NUD aging toward `stale`).
    age_ms: u32 = 0,
};

var neighbor_cache: [MAX_NEIGHBORS]NeighborEntry = @splat(.{});

// v53.40: Protect neighbor_cache against interrupt vs syscall races
var ndp_lock: IrqSpinlock = .{};

/// Reset/clear the neighbor cache. Called from net.init().
pub fn init() void {
    for (0..MAX_NEIGHBORS) |i| {
        neighbor_cache[i] = .{};
    }
}

/// Lookup the cached MAC for a given IPv6 unicast address.
/// Returns null when no valid (reachable/stale/etc.) entry exists.
pub fn lookup(ipv6_addr: [16]u8) ?[6]u8 {
    // v53.40: Acquire lock — neighbor_cache accessed from interrupt + syscall contexts
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
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

/// Advance NDP timers (SK-79 incomplete NS; SK-80 reachable→stale aging).
/// Writes incomplete targets that need another NS into `out` (up to `out.len`).
/// Entries that exhaust `MAX_MULTICAST_SOLICIT` are invalidated.
/// Does not transmit — caller (icmpv6) sends to avoid ndp↔icmpv6 cycles.
pub fn timerTick(ms_elapsed: u32, out: [][16]u8) u32 {
    if (ms_elapsed == 0) return 0;
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);

    var n: u32 = 0;
    for (0..MAX_NEIGHBORS) |i| {
        const e = &neighbor_cache[i];
        if (!e.valid) continue;

        // SK-80: REACHABLE_TIME aging — stale entries remain usable via lookup.
        if (e.state == .reachable) {
            e.age_ms +%= ms_elapsed;
            if (e.age_ms >= REACHABLE_TIME_MS) {
                e.state = .stale;
                e.age_ms = 0;
            }
            continue;
        }

        if (e.state != .incomplete) continue;
        e.retrans_ms +%= ms_elapsed;
        if (e.retrans_ms < RETRANS_MS) continue;
        e.retrans_ms = 0;
        if (e.solicit_count >= MAX_MULTICAST_SOLICIT) {
            e.valid = false;
            continue;
        }
        e.solicit_count +%= 1;
        if (n < out.len) {
            out[n] = e.ipv6_addr;
            n += 1;
        }
    }
    return n;
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

/// Probe helper (SK-79): solicit_count for an incomplete entry, or 0xFF.
pub fn probeSolicitCount(ipv6_addr: [16]u8) u8 {
    const flags = ndp_lock.acquire();
    defer ndp_lock.release(flags);
    for (0..MAX_NEIGHBORS) |i| {
        const e = &neighbor_cache[i];
        if (e.valid and ipv6.addrEq(e.ipv6_addr, ipv6_addr)) return e.solicit_count;
    }
    return 0xFF;
}

/// Probe helper (SK-80): neighbor state, or null if missing/invalid.
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
