//! Pure TCP receive-path policy: what recv() returns when the receive ring
//! is empty, as a function of connection state. Host-testable (no arch deps).

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
    /// Peer may still send: a non-blocking reader gets EAGAIN.
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

/// recv() return value for a decision that copies no data.
pub fn emptyResult(decision: RecvDecision) i64 {
    return switch (decision) {
        .read_data, .eof => 0,
        .would_block => errno.EAGAIN,
        .not_connected => errno.ENOTCONN,
        .reset => errno.ECONNRESET,
    };
}
