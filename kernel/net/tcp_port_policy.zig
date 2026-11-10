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

/// A bound port held by another socket can still be taken when the new socket
/// asked for SO_REUSEADDR and the holder is only a TIME_WAIT leftover.
pub fn reuseMayShare(new_has_reuseaddr: bool, holder_is_time_wait: bool) bool {
    return new_has_reuseaddr and holder_is_time_wait;
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

