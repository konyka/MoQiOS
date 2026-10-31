//! epoll readiness of an AF_UNIX socket, derived from a snapshot of its
//! state (kernel/net/unix_socket.zig takes the snapshot under unix_lock).
//! Pure: no arch/sched imports, so it is host-testable.

pub const EPOLLIN: u32 = 0x001;
pub const EPOLLOUT: u32 = 0x004;
pub const EPOLLHUP: u32 = 0x010;

/// A datagram send needs its 2-byte length prefix plus at least one byte.
pub const DGRAM_MIN_ROOM: u32 = 3;

pub const State = struct {
    stream: bool,
    /// Bytes queued in this socket's own receive ring.
    rx_bytes: u32,
    listening: bool,
    pending_connections: u8,
    /// STREAM only: not connected — the peer closed, or the socket was never
    /// connected — so read() reports EOF and send() fails at once.
    disconnected: bool,
    /// STREAM only: connect() queued this socket on a listener's backlog and
    /// accept() has not run yet; it is neither readable, writable nor hung up.
    connect_pending: bool = false,
    /// STREAM only: an empty ring reads EOF (shutdown) - readable.
    read_eof: bool = false,
    /// STREAM only: a send fails at once (shutdown) - writable.
    send_broken: bool = false,
    /// Free bytes in the ring of the peer this socket sends into; null when
    /// there is no valid peer to block on (send fails immediately instead).
    peer_free: ?u32,
};

pub fn events(s: State) u32 {
    var ev: u32 = 0;
    if (s.rx_bytes > 0 or s.read_eof) ev |= EPOLLIN;
    if (s.send_broken) ev |= EPOLLOUT;
    if (s.stream and s.listening) {
        // Linux never reports a listening socket writable or hung up.
        if (s.pending_connections > 0) ev |= EPOLLIN;
        return ev;
    }
    if (s.stream and s.connect_pending) return ev;
    if (s.stream and s.disconnected) return ev | EPOLLIN | EPOLLOUT | EPOLLHUP;
    if (s.peer_free) |free| {
        const min_room: u32 = if (s.stream) 1 else DGRAM_MIN_ROOM;
        if (free >= min_room) ev |= EPOLLOUT;
    } else {
        ev |= EPOLLOUT;
    }
    return ev;
}
