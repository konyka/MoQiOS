//! Pure TCP receive-path policy: what recv() returns when the receive ring
//! is empty, as a function of connection state, and whether a blocking
//! reader waits instead. Host-testable (no arch deps).

const errno = @import("../lib/errno.zig");

/// TCP connection states (RFC 793). Declaration order is ABI for
/// tcp.tcpState() callers that compare raw integers (e.g. shared/sk77.zig).
pub const TcpState = enum(u8) {
    closed,
    syn_sent,
    syn_received,
    established,
    fin_wait_1,
    fin_wait_2,
    closing,
    time_wait,
    close_wait,
    last_ack,
    listen,
};

pub const RecvDecision = enum {
    /// Ring holds bytes: copy them out.
    read_data,
    /// Peer FIN seen (or connection torn down) and ring drained: return 0.
    eof,
    /// Peer may still send: a blocking reader waits (see shouldBlock); a
    /// non-blocking or timed-out reader gets EAGAIN.
    would_block,
    /// Listening socket: recv is not meaningful.
    not_connected,
    /// Connection aborted by a peer RST and ring drained: ECONNRESET.
    reset,
};

/// Classify a recv() on a TCB in `state` whose receive ring holds
/// `available` bytes. 0 is reserved for EOF so the standard
/// `while ((n = recv(fd, ...)) > 0)` loop does not stop on a transiently
/// empty ring. `reset_by_peer` (a valid RST tore the connection down) turns
/// the drained-ring result into ECONNRESET: an aborted stream must not look
/// like an orderly EOF. Bytes buffered before the RST are still delivered.
pub fn decide(state: TcpState, available: u32, reset_by_peer: bool) RecvDecision {
    if (state == .listen) return .not_connected;
    if (available > 0) return .read_data;
    if (reset_by_peer) return .reset;
    return switch (state) {
        // No FIN from the peer yet: more data can still arrive.
        .syn_sent, .syn_received, .established, .fin_wait_1, .fin_wait_2 => .would_block,
        // Peer FIN received (close_wait, closing, last_ack, time_wait) or the
        // connection is gone (closed): nothing more will ever arrive.
        .close_wait, .closing, .last_ack, .time_wait, .closed => .eof,
        .listen => .not_connected,
    };
}

/// fd status flag (fcntl F_SETFL / SOCK_NONBLOCK / FIONBIO).
pub const O_NONBLOCK: u32 = 0x800;
/// Per-call recv flag: this one call does not wait.
pub const MSG_DONTWAIT: u32 = 0x40;

/// A recv is nonblocking when the fd carries O_NONBLOCK or the call passes
/// MSG_DONTWAIT.
pub fn nonblockRequested(status_flags: u32, msg_flags: u32) bool {
    return (status_flags & O_NONBLOCK) != 0 or (msg_flags & MSG_DONTWAIT) != 0;
}

/// Whether recv() should sleep instead of returning `emptyResult(decision)`.
/// Only a would-block ring waits, and only for a blocking reader whose
/// SO_RCVTIMEO deadline (if any) has not passed — an expired wait keeps the
/// would-block EAGAIN result (Linux SO_RCVTIMEO semantics).
pub fn shouldBlock(decision: RecvDecision, nonblock: bool, timeout_expired: bool) bool {
    return decision == .would_block and !nonblock and !timeout_expired;
}

/// Absolute monotonic deadline for an SO_RCVTIMEO of `timeout_ms`; null
/// (wait forever) when no timeout is set. Saturates instead of wrapping.
pub fn recvDeadlineNs(now_ns: u64, timeout_ms: u32) ?u64 {
    if (timeout_ms == 0) return null;
    return now_ns +| @as(u64, timeout_ms) * 1_000_000;
}

/// True once `now_ns` reached the deadline; never without one.
pub fn timedOut(deadline_ns: ?u64, now_ns: u64) bool {
    const d = deadline_ns orelse return false;
    return now_ns >= d;
}

/// send() on a TCB that cannot queue data (state, FIN request, reset). A
/// connection that never carried data is ENOTCONN; one that was shut down for
/// writing (or whose peer vanished) is EPIPE; a peer RST is ECONNRESET.
/// `established_ever` stays set once the handshake finished.
pub fn sendErrno(state: TcpState, fin_pending: bool, reset_by_peer: bool, established_ever: bool) i64 {
    if (reset_by_peer) return errno.ECONNRESET;
    if (fin_pending) return errno.EPIPE;
    return switch (state) {
        .established, .close_wait => 0,
        .closed, .syn_sent, .syn_received, .listen => if (established_ever) errno.EPIPE else errno.ENOTCONN,
        .fin_wait_1, .fin_wait_2, .closing, .last_ack, .time_wait => errno.EPIPE,
    };
}

/// Data may be queued for sending while the connection is open for writing:
/// ESTABLISHED, and CLOSE_WAIT (the peer shut down its sending side; ours is
/// still open and the peer is waiting for the reply).
pub fn canQueueSend(state: TcpState, fin_pending: bool) bool {
    return (state == .established or state == .close_wait) and !fin_pending;
}

/// After shutdown(SHUT_RD) a read reports EOF whatever the ring holds, and
/// data that arrives later is acknowledged but not kept.
pub fn shutRdEof(shut_rd: bool) bool {
    return shut_rd;
}

/// read() on a connection that never got established (socket(), or a failed
/// connect) is ENOTCONN, not an orderly EOF.
pub fn recvNeverConnected(state: TcpState, established_ever: bool) bool {
    return state == .closed and !established_ever;
}

/// recv() return value for a decision that copies no data.
pub fn emptyResult(decision: RecvDecision) i64 {
    return switch (decision) {
        .read_data, .eof => 0,
        .would_block => errno.EAGAIN,
        .not_connected => errno.ENOTCONN,
        .reset => errno.ECONNRESET,
    };
}
