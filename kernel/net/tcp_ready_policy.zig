//! poll/epoll readiness of a TCP socket as a pure function of a snapshot of its
//! state, shared by poll(2) and epoll so the two agree. The bit values are the
//! common POLL*/EPOLL* ones.

const rp = @import("tcp_recv_policy.zig");

pub const IN: u32 = 0x001;
pub const OUT: u32 = 0x004;
pub const ERR: u32 = 0x008;
pub const HUP: u32 = 0x010;
/// The peer shut down its writing side (or the connection is gone): reported
/// as EPOLLRDHUP / POLLRDHUP, only when asked for.
pub const RDHUP: u32 = 0x2000;

pub const Snapshot = struct {
    /// false = the slot is gone (closed and reaped).
    active: bool,
    state: rp.TcpState,
    recv_bytes: u32,
    send_space: u32,
    reset_by_peer: bool,
    shut_rd: bool,
    fin_pending: bool,
    /// Pending socket error (a refused or timed-out connect): reported as ERR.
    so_error: i32 = 0,
};

/// Linux tcp_poll semantics:
///  - IN  : data queued, or a read would return EOF (peer FIN, our SHUT_RD)
///  - OUT : room to send while open for writing; also once writing is shut
///          down (a write then fails at once, which must not block a poller)
///  - HUP : both directions are finished (or the connection is closed)
///  - ERR : the peer reset the connection
/// A connection still being set up and a listener report nothing here.
pub fn events(s: Snapshot) u32 {
    if (!s.active) return HUP | OUT;
    var ev: u32 = 0;
    if (s.reset_by_peer or s.so_error != 0) ev |= ERR;
    switch (s.state) {
        .listen => return if (s.recv_bytes > 0) IN else 0,
        .syn_sent, .syn_received => return ev,
        else => {},
    }
    const peer_fin = switch (s.state) {
        .close_wait, .closing, .last_ack, .time_wait => true,
        else => false,
    };
    const we_fin = s.fin_pending or switch (s.state) {
        .fin_wait_1, .fin_wait_2, .closing, .last_ack, .time_wait, .closed => true,
        else => false,
    };
    const read_done = peer_fin or s.shut_rd or s.state == .closed;
    if (s.recv_bytes > 0 or read_done) ev |= IN;
    if (peer_fin or s.state == .closed) ev |= RDHUP;
    if (we_fin) {
        ev |= OUT;
    } else if (s.send_space > 0) {
        ev |= OUT;
    }
    if (s.state == .closed or (read_done and we_fin)) ev |= HUP;
    return ev;
}
