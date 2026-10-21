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

/// connect() keeps the TCB's local port only when bind() set it; any other
/// nonzero value is left over from a previous occupant of the slot.
pub fn connectNeedsEphemeral(local_port: u16, bound_explicitly: bool) bool {
    return local_port == 0 or !bound_explicitly;
}
