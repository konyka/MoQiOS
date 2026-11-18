//! Pure TCP receive-path policy: what recv() returns when the receive ring
//! is empty, as a function of connection state, and whether a blocking
//! reader waits instead. Host-testable (no arch deps).

const std = @import("std");
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

/// send() on a TCB that cannot queue data (state, FIN request, reset). A peer
/// RST is ECONNRESET; everything else is EPIPE — Linux answers EPIPE (not
/// ENOTCONN) for a socket that never connected, a listening one, one shut down
/// for writing and one whose peer vanished. (recv() is the call that reports
/// ENOTCONN for a socket that never connected.) `established_ever` is kept in
/// the signature for callers; it no longer changes the answer.
pub fn sendErrno(state: TcpState, fin_pending: bool, reset_by_peer: bool, established_ever: bool) i64 {
    _ = established_ever;
    if (reset_by_peer) return errno.ECONNRESET;
    if (fin_pending) return errno.EPIPE;
    return switch (state) {
        .established, .close_wait => 0,
        .closed, .syn_sent, .syn_received, .listen => errno.EPIPE,
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

/// connect() on a socket that is not in the closed state it needs to start.
/// A handshake in progress is EALREADY; anything else (established, closing,
/// listening) is EISCONN.
pub fn connectRejection(state: TcpState) i64 {
    return switch (state) {
        .closed => 0,
        .syn_sent, .syn_received => errno.EALREADY,
        else => errno.EISCONN,
    };
}

pub const ConnectWait = enum { keep_waiting, connected, failed };

/// Where a blocking connect() stands: still handshaking, done, or reset/timed out.
pub fn connectProgress(state: TcpState) ConnectWait {
    return switch (state) {
        .syn_sent, .syn_received => .keep_waiting,
        .closed => .failed,
        else => .connected,
    };
}

/// errno of a failed connect: what the connection recorded (refused, timed
/// out), ECONNREFUSED if it recorded nothing.
/// EHOSTUNREACH: a connect whose next hop never answered ARP or NDP (Linux neigh_invalidate reports it to the queued SYN's socket).
pub const EHOSTUNREACH: i32 = 113;
/// How long a SYN waits for the next hop to resolve before connect() fails (Linux: 3 ARP probes 1 s apart).
pub const NEIGH_RESOLVE_NS: u64 = 3_000_000_000;

/// Whether a SYN that started waiting for its next hop at `since_ns` gives up at `now_ns` (monotonic clock: the maintenance pass
/// that checks it runs late under load, so counting passes would stretch the wait).
pub fn neighborGaveUp(since_ns: u64, now_ns: u64) bool {
    return now_ns >= since_ns and now_ns - since_ns >= NEIGH_RESOLVE_NS;
}

pub fn connectFailure(so_error: i32) i64 {
    return if (so_error > 0) -@as(i64, so_error) else errno.ECONNREFUSED;
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

/// Which calls a stream socket's state admits, as the errno Linux gives when it does not.
pub const EINVAL: i64 = -22;
pub const ENOTCONN: i64 = -107;
pub const EISCONN: i64 = -106;

/// A connection that exists or is being set up (getpeername has an answer once the handshake began).
pub fn hasPeer(state: TcpState) bool {
    return switch (state) {
        .closed, .listen => false,
        else => true,
    };
}

/// accept(): only a listening socket.
pub fn acceptErrno(state: TcpState) i64 {
    return if (state == .listen) 0 else EINVAL;
}

/// net.core.somaxconn (SOMAXCONN): listen() clamps its backlog to it.
pub const SOMAXCONN: u32 = 4096;

/// How many connections a listener's accept queue holds for listen(fd, `backlog`): __sys_listen_socket clamps the (unsigned)
/// backlog to somaxconn and sk_acceptq_is_full refuses a new one only past it, so backlog + 1; MoQiOS's queue holds at most `cap`.
pub fn acceptLimit(backlog: u32, cap: u32) u32 {
    return @min(@min(backlog, SOMAXCONN) + 1, cap);
}

/// listen(): a fresh (closed) or already listening socket; a connected one is EINVAL.
pub fn listenErrno(state: TcpState) i64 {
    return if (state == .closed or state == .listen) 0 else EINVAL;
}

/// shutdown(): a listener accepts it (it stops listening); a socket that never connected is ENOTCONN
/// for every `how`; one that was connected, or is being, is fine.
pub fn shutdownErrno(state: TcpState, established_ever: bool) i64 {
    if (state == .listen) return 0;
    return if (hasPeer(state) or established_ever) 0 else ENOTCONN;
}

/// getpeername(): only with a peer (including a handshake in progress); a listener has none.
pub fn peernameErrno(state: TcpState, established_ever: bool) i64 {
    return if (hasPeer(state) or established_ever) 0 else ENOTCONN;
}


/// The tail loss probe runs only once the handshake is done (Linux tcp_schedule_loss_probe needs TCP_ESTABLISHED or later): before
/// that the only thing in flight is the SYN or SYN-ACK, which the retransmit timer resends, and a probe would move SND.NXT back
/// over it so the matching ACK (SND.NXT exactly) is refused.
pub fn tailLossProbeAllowed(state: TcpState) bool {
    return state != .syn_sent and state != .syn_received;
}

/// A SYN on a connection whose handshake is done gets a bare ACK and is dropped (RFC 5961 §4, Linux tcp_validate_incoming). This also
/// answers a SYN-ACK the server retransmitted because our final ACK was lost: the ACK lets its child leave SYN_RECEIVED.
pub fn synGetsChallengeAck(state: TcpState) bool {
    return switch (state) {
        .established, .fin_wait_1, .fin_wait_2, .close_wait, .closing, .last_ack => true,
        else => false,
    };
}

/// sk_clone_lock: a connection the listener accepts starts with a copy of the listener's options, except its error and SO_PRIORITY
/// (sk_err, sk_err_soft and sk_priority are cleared).
pub fn childOptions(comptime T: type, listener: T) T {
    var c = listener;
    c.so_error = 0;
    c.priority = 0;
    return c;
}

// ── TCP_USER_TIMEOUT and giving up on an unanswered connection (Linux tcp_timer.c) ──

/// tcp_sock_set_user_timeout: 0 turns it off, a negative value is EINVAL.
pub fn userTimeoutErrno(val: i32) i64 {
    return if (val < 0) EINVAL else 0;
}

/// net.ipv4.tcp_retries2, TCP_RTO_MIN, and the orphan retries tcp_orphan_retries picks while the RTO is below the cap.
pub const RETRIES2: u32 = 15;
pub const RTO_MIN_MS: u32 = 200;
pub const ORPHAN_RETRIES_ALIVE: u32 = 8;

pub const RetransState = struct {
    /// The expiry of the retransmission timer this is (1: the first).
    retransmits: u32,
    /// Since the oldest unacknowledged data went out (retrans_stamp).
    elapsed_ms: u64,
    user_timeout_ms: u32 = 0,
    rto_max_ms: u32 = RTO_MAX_MS,
    /// Closed by its owner (SOCK_DEAD), with the RTO the timer ran on.
    orphan: bool = false,
    rto_ms: u32 = 0,
};

/// tcp_write_timeout → retransmits_timed_out for any state but SYN_SENT: never at the first expiry, which only retransmits. With a
/// user timeout the connection gives up once `elapsed_ms` reaches it; without one, once it reaches the time tcp_retries2
/// backed-off retransmissions from TCP_RTO_MIN take under the socket's RTO cap (tcp_model_timeout), whatever the count. An orphan
/// gets tcp_orphan_retries instead: 8 while its RTO is below the cap, 0 once it reached it.
pub fn retransGiveUp(st: RetransState) bool {
    if (st.retransmits < 2) return false;
    if (st.user_timeout_ms != 0) return st.elapsed_ms >= st.user_timeout_ms;
    const boundary: u32 = if (!st.orphan) RETRIES2 else if (st.rto_ms < st.rto_max_ms) ORPHAN_RETRIES_ALIVE else 0;
    return st.elapsed_ms >= modelTimeoutMs(boundary, RTO_MIN_MS, st.rto_max_ms);
}

/// TCP_RTO_MAX_MS: 1 s to TCP_RTO_MAX_SEC (120 s), anything else EINVAL.
pub fn rtoMaxErrno(val: i32) i64 {
    return if (val < 1000 or val > @as(i32, RTO_MAX_MS)) EINVAL else 0;
}

/// tcp_retransmit_timer: the RTO doubles after an expiry, at most the socket's cap.
pub fn backoffRto(rto: u32, rto_max_ms: u32) u32 {
    return if (rto > rto_max_ms / 2) rto_max_ms else rto * 2;
}

/// tcp_clamp_rto_to_user_timeout: the retransmission timer waits at most what is left of the user timeout (1 ms once it passed).
pub fn clampRto(rto: u32, user_timeout_ms: u32, elapsed_ms: u64) u32 {
    if (user_timeout_ms == 0) return rto;
    if (elapsed_ms >= user_timeout_ms) return 1;
    return @min(rto, @as(u32, @intCast(user_timeout_ms - elapsed_ms)));
}

/// tcp_keepalive_timer: with a user timeout the connection dies once `idle_ms` since the last data reaches it and a probe went out;
/// without one, after `keep_cnt` unanswered probes.
pub fn keepaliveGiveUp(probes: u32, keep_cnt: u32, user_timeout_ms: u32, idle_ms: u64) bool {
    if (user_timeout_ms != 0) return probes > 0 and idle_ms >= user_timeout_ms;
    return probes >= keep_cnt;
}

/// tcp_write_err: the soft error an ICMP error left, else ETIMEDOUT.
pub fn timeoutErrno(soft_err: i32) i32 {
    return if (soft_err != 0) soft_err else 110;
}

/// The ms the first timer pass after a segment went out charges to its retransmission time: only what passed since it was sent
/// (`start_ns`, Linux retrans_stamp) up to the end of the pass (`now_ns`), at most the pass; the whole pass when either time is
/// unknown. Charging the whole pass let a pass that ran late under emulation age a segment sent just before it by up to 1 s.
pub fn firstChargeMs(pass_ms: u32, start_ns: u64, now_ns: u64) u32 {
    if (start_ns == 0 or now_ns == 0 or start_ns > now_ns) return pass_ms;
    const ms = (now_ns - start_ns) / 1_000_000;
    return @intCast(@min(ms, pass_ms));
}

/// How many ms a TCP timer pass covers: the time since the previous pass, at least 1 and at most 1 s. The maintenance pass is
/// meant to run every 100 ms but runs late when the CPU is slow (emulation); a fixed 100 would stretch every TCP timeout with it,
/// and a stall of seconds must not fire every timer at once.
pub fn passElapsedMs(last_ns: u64, now_ns: u64) u32 {
    if (now_ns <= last_ns) return 1;
    const ms = (now_ns - last_ns) / 1_000_000;
    return @intCast(@max(1, @min(ms, 1000)));
}

// ── TCP_SYNCNT and the SYN retransmission schedule (Linux tcp_sock_set_syncnt, tcp_write_timeout, tcp_retransmit_timer) ──

/// MAX_TCP_SYNCNT, and net.ipv4.tcp_syn_retries / tcp_syn_linear_timeouts (the defaults).
pub const MAX_SYNCNT: i32 = 127;
pub const SYN_RETRIES: u32 = 6;
pub const SYN_LINEAR_TIMEOUTS: u32 = 4;
/// TCP_TIMEOUT_INIT (the first SYN's RTO) and TCP_RTO_MAX.
pub const SYN_RTO_MS: u32 = 1000;
pub const RTO_MAX_MS: u32 = 120_000;

/// tcp_sock_set_syncnt: 1..MAX_TCP_SYNCNT, anything else EINVAL.
pub fn syncntErrno(val: i32) i64 {
    return if (val < 1 or val > MAX_SYNCNT) EINVAL else 0;
}

/// The socket's TCP_SYNCNT, tcp_syn_retries while it is unset (0).
pub fn effectiveSyncnt(syn_cnt: u32) u32 {
    return if (syn_cnt == 0) SYN_RETRIES else syn_cnt;
}

/// How long a SYN waits before the `k`-th expiry of its retransmission timer (1: the first): TCP_TIMEOUT_INIT for the first
/// tcp_syn_linear_timeouts + 1 waits, then doubling (tcp_retransmit_timer backs off only past total_rto > linear_timeouts), at most
/// the socket's RTO cap.
pub fn synRtoMs(k: u32, rto_max_ms: u32) u32 {
    if (k <= SYN_LINEAR_TIMEOUTS + 1) return @min(SYN_RTO_MS, rto_max_ms);
    const shift = k - (SYN_LINEAR_TIMEOUTS + 1);
    if (shift >= 7) return rto_max_ms;
    return @min(SYN_RTO_MS << @intCast(shift), rto_max_ms);
}

/// tcp_model_timeout(boundary, rto_base): how long `boundary` exponentially backed-off retransmissions starting at `rto_base` take,
/// in ms, with the RTO capped at `rto_max_ms`.
pub fn modelTimeoutMs(boundary: u32, rto_base: u32, rto_max_ms: u32) u64 {
    const thresh: u32 = std.math.log2_int(u32, @max(1, rto_max_ms / rto_base));
    if (boundary <= thresh) return ((@as(u64, 2) << @intCast(boundary)) - 1) * rto_base;
    return ((@as(u64, 2) << @intCast(thresh)) - 1) * rto_base + @as(u64, boundary - thresh) * rto_max_ms;
}

/// tcp_write_timeout for SYN_SENT, at an expiry after `retransmits` retransmissions: give up once syncnt +
/// tcp_syn_linear_timeouts of them went out, or (from the first retransmission on) once `elapsed_ms` since the SYN reaches the user
/// timeout, or without one the time `syncnt` backed-off retransmissions from TCP_TIMEOUT_INIT would take under the RTO cap.
pub fn synGiveUp(retransmits: u32, syncnt: u32, elapsed_ms: u64, user_timeout_ms: u32, rto_max_ms: u32) bool {
    if (retransmits >= syncnt + SYN_LINEAR_TIMEOUTS) return true;
    if (retransmits == 0) return false;
    const limit: u64 = if (user_timeout_ms != 0) user_timeout_ms else modelTimeoutMs(syncnt, SYN_RTO_MS, rto_max_ms);
    return elapsed_ms >= limit;
}

/// TCP_TIMEOUT_FALLBACK: the first RTO when the handshake gave no RTT sample (RFC 6298 5.7, tcp_init_metrics).
pub const TIMEOUT_FALLBACK_MS: u32 = 3000;

/// The RTT sample the handshake gives without timestamps (tcp_clean_rtx_queue for the SYN, tcp_synack_rtt_meas for the SYN-ACK):
/// the time since the SYN or SYN-ACK went out, but only if it went out once (Karn: after a retransmission nobody knows which copy
/// was answered).
pub fn handshakeRttSample(retransmits: u32, elapsed_ms: u64) ?u32 {
    if (retransmits != 0) return null;
    return @intCast(@min(elapsed_ms, std.math.maxInt(u32)));
}

/// net.ipv4.tcp_synack_retries: SYN-ACK retransmissions before a half-open connection is dropped.
pub const SYNACK_RETRIES: u32 = 5;

/// tcp_reqsk_timeout: how long a SYN-ACK waits before the `k`-th expiry (1: the first), TCP_TIMEOUT_INIT doubled per earlier
/// expiry, at most the RTO cap.
pub fn synAckRtoMs(k: u32, rto_max_ms: u32) u32 {
    const shift = k -| 1;
    if (shift >= 17) return rto_max_ms;
    return @min(SYN_RTO_MS << @intCast(shift), rto_max_ms);
}

/// reqsk_timer_handler: the listener's TCP_SYNCNT (the child inherits it), tcp_synack_retries while it is unset.
pub fn effectiveSynAckRetries(syn_cnt: u32) u32 {
    return if (syn_cnt == 0) SYNACK_RETRIES else syn_cnt;
}

/// syn_ack_recalc: the `expiry`-th expiry (num_timeout = expiry - 1 before it) drops the request once num_timeout reaches the limit.
pub fn synAckGiveUp(expiry: u32, max_retries: u32) bool {
    return expiry > max_retries;
}

/// secs_to_retrans(seconds, TCP_TIMEOUT_INIT, TCP_RTO_MAX): TCP_DEFER_ACCEPT seconds as a count of SYN-ACK timeouts on the 1 s
/// doubling schedule; 0 or less turns it off.
pub fn deferSecsToRetrans(seconds: i32) u8 {
    if (seconds <= 0) return 0;
    var timeout: i64 = 1;
    var period: i64 = timeout;
    var res: u8 = 1;
    while (seconds > period and res < 255) {
        res += 1;
        timeout = @min(timeout * 2, RTO_MAX_MS / 1000);
        period += timeout;
    }
    return res;
}

/// retrans_to_secs: what getsockopt(TCP_DEFER_ACCEPT) reads back, the seconds `retrans` timeouts cover.
pub fn deferRetransToSecs(retrans: u8) i32 {
    if (retrans == 0) return 0;
    var timeout: i32 = 1;
    var period: i32 = timeout;
    var left = retrans - 1;
    while (left > 0) : (left -= 1) {
        timeout = @min(timeout * 2, @as(i32, RTO_MAX_MS / 1000));
        period += timeout;
    }
    return period;
}

/// tcp_check_req with TCP_DEFER_ACCEPT: while fewer than `defer_retrans` SYN-ACK timeouts have passed, a bare ACK completing the
/// handshake (no data, no FIN) is dropped; the request remembers it was acknowledged.
pub fn deferDropsBareAck(timeouts: u32, defer_retrans: u8, payload_len: u32, fin: bool) bool {
    return timeouts < defer_retrans and payload_len == 0 and !fin;
}

pub const SynAckExpiry = struct { give_up: bool, resend: bool };

/// syn_ack_recalc at the `expiry`-th expiry (num_timeout = expiry - 1 before it). Without TCP_DEFER_ACCEPT: drop once num_timeout
/// reaches `max_retries`, else resend. With it, a request the client already acknowledged (`acked`) is dropped only once the defer
/// count has passed too, and its SYN-ACK is resent only from the last deferred timeout on (a last chance for the ACK).
pub fn synAckExpiry(expiry: u32, max_retries: u32, defer_retrans: u8, acked: bool) SynAckExpiry {
    const nt = expiry -| 1;
    if (defer_retrans == 0) return .{ .give_up = synAckGiveUp(expiry, max_retries), .resend = true };
    return .{
        .give_up = nt >= max_retries and (!acked or nt >= defer_retrans),
        .resend = !acked or nt + 1 >= defer_retrans,
    };
}

/// tcp_probe_timer: zero-window probing goes on as long as the peer answers (RFC 1122 4.2.2.17); with TCP_USER_TIMEOUT the
/// connection gives up once the window has stayed shut `shut_ms` that long.
pub fn persistGiveUp(user_timeout_ms: u32, shut_ms: u64) bool {
    return user_timeout_ms != 0 and shut_ms >= user_timeout_ms;
}

/// tcp_retransmit_timer with a zero send window: the retransmissions are window probes (RFC 1122 4.2.2.17), and the connection
/// times out only when tcp_rtx_probe0_timed_out says so. With TCP_USER_TIMEOUT, once `rtx_ms` of retransmitting passed it; without,
/// only once the peer has also been silent `silent_ms` past 2 x TCP_RTO_MAX (an answering peer keeps it open).
pub fn zeroWindowGiveUp(user_timeout_ms: u32, rtx_ms: u64, silent_ms: u64) bool {
    var limit: u64 = 2 * @as(u64, RTO_MAX_MS);
    if (user_timeout_ms != 0) {
        if (rtx_ms > user_timeout_ms) return true;
        limit = @min(limit, user_timeout_ms);
    }
    if (silent_ms <= limit) return false;
    return rtx_ms > limit;
}

/// The states tcp_retransmit_timer treats a zero window as probing in (not SYN_SENT or SYN_RECEIVED).
pub fn zeroWindowState(state: TcpState) bool {
    return state != .syn_sent and state != .syn_received;
}

// ── TCP_NOTSENT_LOWAT (Linux tcp_stream_memory_free, tcp_notsent_lowat) ──

/// tcp_notsent_lowat: the socket's value, or the sysctl default (UINT_MAX: no limit) when it is 0. The value is kept as the int the
/// caller gave and used as a u32, so a negative one is a very large limit.
pub fn notsentLimit(lowat: i32) u32 {
    return if (lowat == 0) std.math.maxInt(u32) else @bitCast(lowat);
}

/// sk_stream_memory_free (wake 0): a send may queue more while the bytes written but not yet sent are below the limit.
pub fn notsentAllowsQueue(unsent: u32, lowat: i32) bool {
    return unsent < notsentLimit(lowat);
}

/// tcp_poll (__sk_stream_is_writeable with wake 1): the socket reports writable only while twice the unsent bytes are below it.
pub fn notsentWritable(unsent: u32, lowat: i32) bool {
    return (@as(u64, unsent) << 1) < notsentLimit(lowat);
}
