//! Pure TCP local-port policy: ephemeral port selection that never hands out
//! a port still held by a live TCB, and when connect() must (re)allocate one.
//! Host-testable (no arch deps). Callers in tcp.zig hold tcp_lock and pass a
//! snapshot of the local ports of every active TCB.

/// IANA dynamic/private range used for ephemeral ports.
pub const EPHEMERAL_FIRST: u16 = 49152;
pub const EPHEMERAL_LAST: u16 = 65535;
pub const EPHEMERAL_COUNT: u32 = @as(u32, EPHEMERAL_LAST) - EPHEMERAL_FIRST + 1;

/// Successor of `cur` inside the ephemeral range, wrapping 65535 → 49152.
pub fn nextEphemeralPort(cur: u16) u16 {
    const next = cur +% 1;
    return if (next < EPHEMERAL_FIRST) EPHEMERAL_FIRST else next;
}

/// True when `port` is nonzero and no active TCB (any state, TIME_WAIT
/// included) has it as its local port.
pub fn portAvailable(port: u16, in_use: []const u16) bool {
    if (port == 0) return false;
    for (in_use) |p| {
        if (p == port) return false;
    }
    return true;
}

/// First available ephemeral port at or after `start` (wrapping), or null
/// when every port of the range is taken. Bounded by the range size.
pub fn pickEphemeralPort(start: u16, in_use: []const u16) ?u16 {
    var port: u16 = if (start < EPHEMERAL_FIRST) EPHEMERAL_FIRST else start;
    var tries: u32 = 0;
    while (tries < EPHEMERAL_COUNT) : (tries += 1) {
        if (portAvailable(port, in_use)) return port;
        port = nextEphemeralPort(port);
    }
    return null;
}

/// bind() errors (negative errno).
pub const BIND_EADDRINUSE: i64 = -98;
pub const BIND_EINVAL: i64 = -22;
pub const BIND_EACCES: i64 = -13;

/// First port a process needs CAP_NET_BIND_SERVICE for is below this.
pub const PRIVILEGED_PORT_LIMIT: u16 = 1024;

/// bind() to `port` without the capability: EACCES for a privileged port.
pub fn bindNeedsPrivilege(port: u16) bool {
    return port != 0 and port < PRIVILEGED_PORT_LIMIT;
}

/// A port another socket holds can still be bound (or listened on) when both sockets set SO_REUSEADDR and the holder is not listening
/// (Linux inet_csk_bind_conflict: sk->sk_reuse && sk2->sk_reuse && sk2->sk_state != TCP_LISTEN). A TIME_WAIT holder is no exception:
/// without SO_REUSEADDR on it the port stays taken.
pub fn reuseMayShare(new_has_reuseaddr: bool, holder_has_reuseaddr: bool, holder_is_listening: bool) bool {
    return new_has_reuseaddr and holder_has_reuseaddr and !holder_is_listening;
}

/// Two sockets on one port only conflict when they are of the same family: every AF_INET6 socket here is IPV6_V6ONLY (no IPv4-mapped
/// dual stack), and Linux inet_bind_conflict lets a v6-only socket and an IPv4 one share a port.
pub fn familiesConflict(new_is_v6: bool, holder_is_v6: bool) bool {
    return new_is_v6 == holder_is_v6;
}

pub const WILDCARD4 = [4]u8{ 0, 0, 0, 0 };
pub const LOOPBACK4 = [4]u8{ 127, 0, 0, 1 };

fn isWildcard4(a: [4]u8) bool {
    return @as(u32, @bitCast(a)) == 0;
}

/// Two IPv4 sockets on one port conflict when either is bound to the wildcard or both to the same address (Linux inet_bind_conflict
/// compares inet_rcv_saddr). 127.0.0.1:p and 127.0.0.2:p may coexist; 0.0.0.0:p conflicts with every address on p.
pub fn addrsConflict(a: [4]u8, b: [4]u8) bool {
    return isWildcard4(a) or isWildcard4(b) or @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
}

fn isWildcard6(a: [16]u8) bool {
    return @as(u128, @bitCast(a)) == 0;
}

/// The IPv6 counterpart of addrsConflict (Linux udp_lib_lport_inuse compares sk_v6_rcv_saddr): [::1]:p and [ff0e::1]:p may coexist;
/// [::]:p conflicts with every address on p.
pub fn addrsConflict6(a: [16]u8, b: [16]u8) bool {
    return isWildcard6(a) or isWildcard6(b) or @as(u128, @bitCast(a)) == @as(u128, @bitCast(b));
}

/// The IPv6 counterpart of listenerTakes: `exact` asks for a socket bound to `dst` itself, otherwise a wildcard one (Linux
/// udp6_lib_lookup2 scores an exact local address above ::).
pub fn listenerTakes6(bound: [16]u8, dst: [16]u8, exact: bool) bool {
    if (exact) return !isWildcard6(bound) and @as(u128, @bitCast(bound)) == @as(u128, @bitCast(dst));
    return isWildcard6(bound);
}

/// Whether a listener bound to `bound` takes a SYN for `dst`. `exact` asks for an address match only: a listener bound to the SYN's
/// destination is preferred over a wildcard one (Linux compute_score).
pub fn listenerTakes(bound: [4]u8, dst: [4]u8, exact: bool) bool {
    if (exact) return !isWildcard4(bound) and @as(u32, @bitCast(bound)) == @as(u32, @bitCast(dst));
    return isWildcard4(bound);
}

/// The IPv4 source address of a segment to `remote`. A loopback peer is reached from the bound address when that is on loopback too,
/// otherwise from 127.0.0.1 (the source of Linux's local route); any other peer from the bound address, else the interface's.
pub fn sourceAddr(bound: [4]u8, remote: [4]u8, our: [4]u8) [4]u8 {
    if (remote[0] == 127) return if (bound[0] == 127) bound else LOOPBACK4;
    return if (isWildcard4(bound) or bound[0] == 127) our else bound;
}

/// Whether a segment to `dst` belongs to a connection bound to `bound` with peer `remote` (the local half of Linux
/// __inet_lookup_established's 4-tuple). A loopback connection's local address is the one its segments carry (sourceAddr); any other
/// connection is matched by a specific non-loopback bound address only, as the interface address is all it can be reached at.
pub fn localAddrMatches(bound: [4]u8, remote: [4]u8, our: [4]u8, dst: [4]u8) bool {
    if (remote[0] == 127) return @as(u32, @bitCast(sourceAddr(bound, remote, our))) == @as(u32, @bitCast(dst));
    return isWildcard4(bound) or bound[0] == 127 or @as(u32, @bitCast(bound)) == @as(u32, @bitCast(dst));
}

/// Whether two IPv4 connections to the same peer and ports also share a local address, so connect() must refuse the second
/// (Linux __inet_check_established): their segments would carry the same source address.
pub fn sameLocalAddr(a_bound: [4]u8, b_bound: [4]u8, remote: [4]u8, our: [4]u8) bool {
    return @as(u32, @bitCast(sourceAddr(a_bound, remote, our))) == @as(u32, @bitCast(sourceAddr(b_bound, remote, our)));
}

/// getsockname's IPv4 address: the bound one; for an unbound socket with a peer, the source address its segments carry; otherwise
/// the wildcard (Linux reports 0.0.0.0 for an unbound, unconnected socket).
pub fn nameAddr(bound: [4]u8, has_peer: bool, remote: [4]u8, our: [4]u8) [4]u8 {
    if (!isWildcard4(bound)) return bound;
    if (!has_peer) return WILDCARD4;
    return sourceAddr(bound, remote, our);
}

/// getsockname's IPv6 address, the IPv6 counterpart of nameAddr: the bound address; for an unbound socket with a peer, ::1 when the
/// peer is ::1 and `our` (the interface's preferred address) otherwise; else :: (Linux reports :: for an unbound, unconnected socket).
pub fn nameAddr6(bound: [16]u8, has_peer: bool, remote: [16]u8, our: [16]u8) [16]u8 {
    const wild: [16]u8 = @splat(0);
    if (@as(u128, @bitCast(bound)) != 0) return bound;
    if (!has_peer) return wild;
    var loop6 = wild;
    loop6[15] = 1;
    return if (@as(u128, @bitCast(remote)) == @as(u128, @bitCast(loop6))) loop6 else our;
}

/// connect() from a port another connection shares: the 4-tuple is taken (EADDRNOTAVAIL, Linux __inet_check_established) while that
/// connection is live. A CLOSED slot is no connection, and a TIME_WAIT one is taken over the way a loopback tcp_tw_reuse does.
pub const CONNECT_EADDRNOTAVAIL: i64 = -99;

pub fn tupleTakenBy(holder_is_closed: bool, holder_is_time_wait: bool) bool {
    return !holder_is_closed and !holder_is_time_wait;
}

/// SO_REUSEPORT (socket_opt flag bit 8): two sockets may bind the same port only when BOTH set it before binding and have the same owner uid
/// (Linux additionally requires the same effective uid so another user cannot hijack the port).
pub const REUSEPORT_FLAG: u16 = 8;

pub fn reusePortMayShare(new_extra_flags: u16, holder_extra_flags: u16, new_uid: u32, holder_uid: u32) bool {
    return (new_extra_flags & REUSEPORT_FLAG) != 0 and (holder_extra_flags & REUSEPORT_FLAG) != 0 and new_uid == holder_uid;
}

/// Which of `count` same-port listeners takes a connection from this peer: a stable hash of the peer's address and port, so a given client
/// always reaches the same listener (Linux hashes the 4-tuple the same way).
pub fn pickListener(count: u32, src_ip: [4]u8, src_port: u16) u32 {
    if (count <= 1) return 0;
    var h: u32 = 2166136261;
    for (src_ip) |b| h = (h ^ b) *% 16777619;
    h = (h ^ (src_port & 0xff)) *% 16777619;
    h = (h ^ (src_port >> 8)) *% 16777619;
    return h % count;
}

/// connect() keeps the TCB's local port only when bind() set it; any other
/// nonzero value is left over from a previous occupant of the slot.
pub fn connectNeedsEphemeral(local_port: u16, bound_explicitly: bool) bool {
    return local_port == 0 or !bound_explicitly;
}

/// When the TCB table is full, the slot to give to a new connection: the TIME_WAIT leftover that has waited longest. A TIME_WAIT
/// connection has no owner and holds nothing but its 4-tuple; every other state is a live connection, a listener or one an fd still
/// references and is never taken. `waiting[i]` is true for a TIME_WAIT slot no descriptor references, `age_ms[i]` its time in that
/// state (larger = older). Returns the index to evict, or null when no slot qualifies.
pub fn pickTimeWaitVictim(waiting: []const bool, age_ms: []const u32) ?usize {
    var best: ?usize = null;
    for (waiting, 0..) |w, i| {
        if (!w) continue;
        if (best == null or age_ms[i] > age_ms[best.?]) best = i;
    }
    return best;
}

/// What accept() does with one queued entry of a listener's ring (oldest first).
pub const QueueEntry = enum { dead, handshaking, ready };

/// The entry accept() takes from `entries` (oldest first), or null when none is ready. A dead entry is dropped; a connection still in its
/// handshake (SYN_RECEIVED) stays queued, and a ready one behind it may be taken first (Linux keeps half-open connections out of the
/// accept queue, so they never block or lose a later established one).
pub fn pickAcceptable(entries: []const QueueEntry) ?usize {
    for (entries, 0..) |e, i| {
        if (e == .ready) return i;
    }
    return null;
}

