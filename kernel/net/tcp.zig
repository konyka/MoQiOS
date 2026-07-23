/// TCP protocol implementation for MoQiOS.
///
/// Supports: three-way handshake, data transfer with sequence numbers,
/// four-way close, retransmission, and sliding window.
///
/// Congestion control: TCP Reno (slow start, congestion avoidance,
/// fast retransmit, fast recovery).
///
/// Extensions: Window Scaling (RFC 1323), Timestamps (RFC 1323),
/// RTT measurement via Jacobson/Karels algorithm.
///
/// Design constraints:
/// - No heap allocation — all state in static arrays (BSS)
/// - Max 64 simultaneous connections
/// - Window size: 32768 bytes (before scaling)
/// - MSS: 1460 bytes
/// - SMP send safety: per-call packet buffer, e1000 serializes TX ring submit
const nic = @import("nic.zig");
const netif = @import("netif.zig");
const eth = @import("eth.zig");
const ipv4 = @import("ipv4.zig");
const ipv6 = @import("ipv6.zig");
const arp = @import("arp.zig");
const ndp = @import("ndp.zig");
const icmpv6 = @import("icmpv6.zig");
const socket_opt = @import("socket_opt.zig");
const bo = @import("../lib/byte_order.zig");
const tcp_util = @import("tcp_util.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

// v53.13: Global TCP lock — protects TCB array, tcb_active_bitmap, and all TCB fields.
// v53.15: tcb_active_bitmap uses atomic RMW for all accesses (lock-free snapshot in timerTick).
// Lock order: tcp_lock → e1000.tx_lock (sendSegment acquires tx_lock internally).
// Acquired at the entry of every public function; private helpers (sendSegment, flushSendBuffer,
// processIncomingData, allocTcb, deactivateTcb) are called from within the lock and must NOT re-acquire.
var tcp_lock: IrqSpinlock = .{};

// v53.14: Debug logging no-op — avoids serial I/O (87μs/char polling UART) inside
// tcp_lock critical sections. Serial polling in locked code caused ~170ms lock hold
// time for 64 connections, leading to e1000 RX ring overflow and packet drops.
// To re-enable: replace body with tcpLog(msg).
inline fn tcpLog(comptime msg: []const u8) void {
    _ = msg;
}

// ─── Constants ────────────────────────────────────────────────────────────

const MAX_CONNECTIONS: u32 = 64;
const TCP_WINDOW: u32 = 32768;
const TCP_MSS: u16 = 1460;
/// IPv4 header + minimum TCP header (no options) for SMSS (SK-101).
const TCP_IPV4_OVERHEAD: u16 = ipv4.HEADER_LEN + 20;
/// IPv6 header + minimum TCP header (no options) for SMSS (SK-98).
const TCP_IPV6_OVERHEAD: u16 = ipv6.HEADER_LEN + 20;
const SEND_BUF_SIZE: u32 = 65536;
const RECV_BUF_SIZE: u32 = 65536;
const RETRANSMIT_MS: u32 = 2000; // initial RTO (ms), overridden by Jacobson/Karels
const TCP_RTO_MIN: u32 = 200; // minimum RTO (ms)
const TCP_RTO_MAX: u32 = 60000; // maximum RTO (ms)
/// RFC 6675 DupThresh for SACK loss detection (SK-112).
const DUP_THRESH: u32 = 3;
const DELAYED_ACK_MS: u32 = 100; // delay ACK by 100ms (reduces ACK count ~50%)

/// Write `count` bytes from `src` into a ring buffer at `write_pos`.
/// Uses @memcpy for contiguous chunks (handles wraparound at buffer boundary).
inline fn ringWrite(buffer: [*]u8, buf_size: u32, write_pos: u32, src: [*]const u8, count: u32) void {
    if (count == 0) return;
    const tail = buf_size - write_pos;
    if (tail >= count) {
        @memcpy(buffer[write_pos .. write_pos + count], src[0..count]);
    } else {
        @memcpy(buffer[write_pos .. write_pos + tail], src[0..tail]);
        @memcpy(buffer[0 .. count - tail], src[tail..count]);
    }
}

/// Read `count` bytes from a ring buffer at `read_pos` into `dst`.
/// Uses @memcpy for contiguous chunks (handles wraparound at buffer boundary).
inline fn ringRead(buffer: [*]const u8, buf_size: u32, read_pos: u32, dst: [*]u8, count: u32) void {
    if (count == 0) return;
    const tail = buf_size - read_pos;
    if (tail >= count) {
        @memcpy(dst[0..count], buffer[read_pos .. read_pos + count]);
    } else {
        @memcpy(dst[0..tail], buffer[read_pos .. read_pos + tail]);
        @memcpy(dst[tail..count], buffer[0 .. count - tail]);
    }
}

/// SACK block: [left, right) sequence number range.
pub const SackBlock = struct {
    left: u32, // first sequence number in block
    right: u32, // one past last sequence number in block
};

// TCP header flags
const FIN: u8 = 0x01;
const SYN: u8 = 0x02;
const RST: u8 = 0x04;
const PSH: u8 = 0x08;
const ACK: u8 = 0x10;

// TCP states (RFC 793)
const TcpState = enum(u8) {
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

// ─── TCP Control Block (TCB) ──────────────────────────────────────────────

const TcpTcb = struct {
    local_port: u16,
    remote_port: u16,
    remote_ip: [4]u8,
    /// SK-75: dual-stack — when true, `remote_ip6` is the peer address.
    is_v6: bool = false,
    remote_ip6: [16]u8 = @splat(0),
    /// SK-100: peer MSS from SYN/SYN-ACK (0 = not advertised).
    peer_mss: u16 = 0,
    state: TcpState,

    // Sequence numbers
    snd_una: u32, // oldest unacknowledged
    snd_nxt: u32, // next to send
    snd_wnd: u32, // send window
    iss: u32, // initial send sequence

    rcv_nxt: u32, // next expected
    rcv_wnd: u32, // receive window
    irs: u32, // initial receive sequence

    // Send buffer (ring buffer)
    send_buf: [SEND_BUF_SIZE]u8,
    send_head: u32,
    send_tail: u32,
    send_unacked: u32, // offset into ring of first unacked byte

    // Receive buffer (ring buffer)
    recv_buf: [RECV_BUF_SIZE]u8,
    recv_head: u32,
    recv_tail: u32,

    // Retransmission
    retransmit_timer: u32, // ms since last ack
    retransmit_count: u8,

    // Congestion control (TCP Reno + PRR in recovery, SK-114)
    cwnd: u32, // congestion window (bytes)
    ssthresh: u32, // slow start threshold (bytes)
    dup_ack_count: u3, // duplicate ACK counter
    in_recovery: bool, // fast recovery active
    recover_seq: u32, // seq number at recovery entry
    /// Flight size at recovery entry (RFC 6937 RecoverFS).
    recover_fs: u32,
    /// Bytes newly delivered (ACKed/SACKed) during recovery.
    prr_delivered: u32,
    /// Bytes sent during recovery (PRR).
    prr_out: u32,

    // Window Scaling (RFC 1323)
    snd_wnd_scale: u4, // send window scale shift count
    rcv_wnd_scale: u4, // receive window scale shift count
    ws_requested: u4, // window scale we requested in SYN
    ws_enabled: bool, // window scaling negotiated

    // Timestamps (RFC 1323) & RTT measurement
    ts_recent: u32, // most recent timestamp received
    ts_val_last: u32, // TSVAL we sent in last segment (for RTT)
    ts_enabled: bool, // timestamps negotiated
    // Jacobson/Karels RTO estimation
    srtt: u32, // smoothed RTT (ms), 0 = no sample yet
    rttvar: u32, // RTT variance (ms)
    rto: u32, // current retransmission timeout (ms)

    // Keepalive state
    idle_ms: u32, // ms since last data received
    keepalive_probes: u32, // number of keepalive probes sent without response
    nagle_pending: bool, // Nagle: data is pending but held for ACK
    /// Zero-window persist probe timer (SK-110).
    persist_timer_ms: u32,
    /// Current persist probe interval (SK-110); doubles after each probe.
    persist_rto_ms: u32,

    // SACK (Selective Acknowledgment) state
    sack_permitted: bool, // SACK negotiated
    // Receiver side: out-of-order blocks to report in ACKs
    sack_blocks: [4]SackBlock,
    sack_block_count: u3,
    // Sender side: SACK info received from peer (scoreboard)
    sack_scoreboard: [4]SackBlock,
    sack_scoreboard_count: u3,

    // Delayed ACK state
    delayed_ack_pending: bool, // ACK is being held
    delayed_ack_ms: u32, // ms since first unacked data arrived

    // Connection metadata
    active: bool, // slot in use
    owner_task: u32, // task index that owns this connection
    /// Cross-process references (fork/clone) — tcpClose tears down at 0 only.
    ref_count: u32 = 1,
    options: socket_opt.SocketOptions,
};

var tcbs: [MAX_CONNECTIONS]TcpTcb = undefined;

/// Bitmap tracking active TCB slots (1 = active, 0 = free).
/// Enables O(1) skip of empty slots via @ctz instead of linear scan.
// v53.15: All accesses use @atomicLoad/@atomicRmw for SMP-safe lock-free snapshot in timerTick.
var tcb_active_bitmap: u64 = 0;

/// Compute the pool index of a TCB from its pointer.
fn tcbIdx(tcb: *const TcpTcb) u32 {
    const base: usize = @intFromPtr(&tcbs[0]);
    const elem: usize = @intFromPtr(tcb);
    return @intCast((elem - base) / @sizeOf(TcpTcb));
}

/// Deactivate a TCB and clear its bitmap bit (single call site for consistency).
inline fn deactivateTcb(tcb: *TcpTcb) void {
    const idx: u6 = @intCast(tcbIdx(tcb));
    _ = @atomicRmw(u64, &tcb_active_bitmap, .And, ~(@as(u64, 1) << idx), .release);
    tcb.active = false;
}

pub fn initTcbs() void {
    @atomicStore(u64, &tcb_active_bitmap, 0, .release);
    listen_active_bitmap = 0;
    for (0..MAX_CONNECTIONS) |i| {
        listen_slots[i] = .{
            .active = false,
            .local_port = 0,
            .owner_task = 0,
            .is_v6 = false,
            .pending_tpbs = @splat(0),
            .pending_head = 0,
            .pending_tail = 0,
        };
    }
    for (0..MAX_CONNECTIONS) |i| {
        tcbs[i] = .{
            .local_port = 0,
            .remote_port = 0,
            .remote_ip = .{0} ** 4,
            .is_v6 = false,
            .remote_ip6 = @splat(0),
            .peer_mss = 0,
            .state = .closed,
            .snd_una = 0,
            .snd_nxt = 0,
            .snd_wnd = TCP_WINDOW,
            .iss = 0,
            .rcv_nxt = 0,
            .rcv_wnd = TCP_WINDOW,
            .irs = 0,
            .send_buf = .{0} ** SEND_BUF_SIZE,
            .send_head = 0,
            .send_tail = 0,
            .send_unacked = 0,
            .recv_buf = .{0} ** RECV_BUF_SIZE,
            .recv_head = 0,
            .recv_tail = 0,
            .retransmit_timer = 0,
            .retransmit_count = 0,
            .cwnd = TCP_MSS,
            .ssthresh = 65535,
            .dup_ack_count = 0,
            .in_recovery = false,
            .recover_seq = 0,
            .recover_fs = 0,
            .prr_delivered = 0,
            .prr_out = 0,
            .snd_wnd_scale = 0,
            .rcv_wnd_scale = 2, // default: shift left by 2 (window 16KB)
            .ws_requested = 2,
            .ws_enabled = false,
            .ts_recent = 0,
            .ts_val_last = 0,
            .ts_enabled = false,
            .srtt = 0,
            .rttvar = 0,
            .rto = RETRANSMIT_MS,
            .idle_ms = 0,
            .keepalive_probes = 0,
            .nagle_pending = false,
            .persist_timer_ms = 0,
            .persist_rto_ms = RETRANSMIT_MS,
            .sack_permitted = false,
            .sack_blocks = @splat(.{ .left = 0, .right = 0 }),
            .sack_block_count = 0,
            .sack_scoreboard = @splat(.{ .left = 0, .right = 0 }),
            .sack_scoreboard_count = 0,
            .delayed_ack_pending = false,
            .delayed_ack_ms = 0,
            .active = false,
            .owner_task = 0,
            .options = .{},
        };
    }
}

var next_ephemeral_port: u16 = 49152;

// ─── Utilities ────────────────────────────────────────────────────────────

fn allocTcb() ?*TcpTcb {
    // Use inverted bitmap to find first free slot (0 bit = free)
    const all_mask: u64 = if (MAX_CONNECTIONS >= 64) 0xFFFFFFFFFFFFFFFF else (@as(u64, 1) << MAX_CONNECTIONS) - 1;
    const free_bitmap = ~@atomicLoad(u64, &tcb_active_bitmap, .acquire) & all_mask;
    if (free_bitmap == 0) return null;
    const i: u6 = @intCast(@ctz(free_bitmap));
    _ = @atomicRmw(u64, &tcb_active_bitmap, .Or, @as(u64, 1) << i, .release);
    tcbs[i].active = true;
    tcbs[i].state = .closed;
    tcbs[i].send_head = 0;
    tcbs[i].send_tail = 0;
    tcbs[i].send_unacked = 0;
    tcbs[i].recv_head = 0;
    tcbs[i].recv_tail = 0;
    tcbs[i].retransmit_timer = 0;
    tcbs[i].retransmit_count = 0;
    tcbs[i].cwnd = TCP_MSS;
    tcbs[i].ssthresh = 65535;
    tcbs[i].dup_ack_count = 0;
    tcbs[i].in_recovery = false;
    tcbs[i].recover_seq = 0;
    tcbs[i].recover_fs = 0;
    tcbs[i].prr_delivered = 0;
    tcbs[i].prr_out = 0;
    tcbs[i].snd_wnd_scale = 0;
    tcbs[i].rcv_wnd_scale = 2;
    tcbs[i].ws_requested = 2;
    tcbs[i].ws_enabled = false;
    tcbs[i].ts_recent = 0;
    tcbs[i].ts_val_last = 0;
    tcbs[i].ts_enabled = false;
    tcbs[i].srtt = 0;
    tcbs[i].rttvar = 0;
    tcbs[i].rto = RETRANSMIT_MS;
    tcbs[i].idle_ms = 0;
    tcbs[i].keepalive_probes = 0;
    tcbs[i].nagle_pending = false;
    tcbs[i].persist_timer_ms = 0;
    tcbs[i].persist_rto_ms = RETRANSMIT_MS;
    tcbs[i].delayed_ack_pending = false;
    tcbs[i].delayed_ack_ms = 0;
    tcbs[i].ref_count = 1;
    tcbs[i].options = .{};
    tcbs[i].is_v6 = false;
    tcbs[i].remote_ip6 = @splat(0);
    tcbs[i].remote_ip = .{ 0, 0, 0, 0 };
    tcbs[i].peer_mss = 0;
    return &tcbs[i];
}

/// Add a cross-process reference (fork/clone fd-table copy).
pub fn tcpRetain(tcb_idx: u32) void {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    if (tcb_idx >= MAX_CONNECTIONS) return;
    if (!tcbs[tcb_idx].active) return;
    tcbs[tcb_idx].ref_count += 1;
}

fn findTcbByTuple(local_port: u16, remote_port: u16, remote_ip: [4]u8) ?*TcpTcb {
    var bm = @atomicLoad(u64, &tcb_active_bitmap, .acquire);
    while (bm != 0) {
        const i = @ctz(bm);
        bm &= bm - 1; // clear lowest set bit
        if (!tcbs[i].is_v6 and
            tcbs[i].local_port == local_port and
            tcbs[i].remote_port == remote_port and
            @as(u32, @bitCast(tcbs[i].remote_ip)) == @as(u32, @bitCast(remote_ip)))
        {
            return &tcbs[i];
        }
    }
    return null;
}

fn findTcbByTupleV6(local_port: u16, remote_port: u16, remote_ip6: [16]u8) ?*TcpTcb {
    var bm = @atomicLoad(u64, &tcb_active_bitmap, .acquire);
    while (bm != 0) {
        const i = @ctz(bm);
        bm &= bm - 1;
        if (tcbs[i].is_v6 and
            tcbs[i].local_port == local_port and
            tcbs[i].remote_port == remote_port and
            ipv6.addrEq(tcbs[i].remote_ip6, remote_ip6))
        {
            return &tcbs[i];
        }
    }
    return null;
}

fn findTcbByLocalPort(local_port: u16) ?*TcpTcb {
    var bm = @atomicLoad(u64, &tcb_active_bitmap, .acquire);
    while (bm != 0) {
        const i = @ctz(bm);
        bm &= bm - 1;
        if (tcbs[i].local_port == local_port) {
            return &tcbs[i];
        }
    }
    return null;
}

fn allocEphemeralPort() u16 {
    const port = next_ephemeral_port;
    next_ephemeral_port +|= 1;
    if (next_ephemeral_port < 49152) next_ephemeral_port = 49152;
    return port;
}

/// Get a copy of socket options for a TCB (v53.14: locked — no raw pointer escape).
/// Returns null if tcb_idx is invalid or TCB is inactive.
pub fn tcpGetOptions(tcb_idx: u32) ?socket_opt.SocketOptions {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    if (tcb_idx >= MAX_CONNECTIONS) return null;
    if (!tcbs[tcb_idx].active) return null;
    return tcbs[tcb_idx].options;
}

/// Set socket options for a TCB from a copy (v53.14: locked).
/// Returns false if tcb_idx is invalid or TCB is inactive.
pub fn tcpSetOptions(tcb_idx: u32, opts: socket_opt.SocketOptions) bool {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    if (tcb_idx >= MAX_CONNECTIONS) return false;
    if (!tcbs[tcb_idx].active) return false;
    tcbs[tcb_idx].options = opts;
    return true;
}

/// Clear SO_ERROR for a TCB (v53.14: locked — SO_ERROR is one-shot, cleared on read).
pub fn tcpClearSoError(tcb_idx: u32) void {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    if (tcb_idx < MAX_CONNECTIONS and tcbs[tcb_idx].active) {
        tcbs[tcb_idx].options.so_error = 0;
    }
}

fn generateIss() u32 {
    // Simple ISS from the monotonic timestamp counter (rdtsc / rdtime /
    // cntvct_el0 behind the arch facade — portable across arches).
    const ts = @import("../arch/arch.zig").tsc.read();
    return @truncate(ts ^ (ts >> 32));
}

// Ring buffer helpers — arch-clean math lives in tcp_util.zig.
fn ringAvailable(head: u32, tail: u32, size: u32) u32 {
    return tcp_util.ringAvailable(head, tail, size);
}

fn ringDataLen(head: u32, tail: u32, size: u32) u32 {
    return tcp_util.ringDataLen(head, tail, size);
}

// ─── TCP Header Construction ──────────────────────────────────────────────

/// Write TCP header + options + payload at `tcp_off` (checksum field left 0).
/// Shared by IPv4/IPv6 TX (SK-76). Returns the TCP segment length.
fn fillTcpSegment(
    tcb: *TcpTcb,
    flags: u8,
    data: [*]const u8,
    data_len: u16,
    pkt: [*]u8,
    tcp_off: u16,
    seq_override: ?u32,
) u16 {
    // SK-109: keepalive probes use SND.UNA-1; normal TX uses snd_nxt.
    const seq = seq_override orelse tcb.snd_nxt;
    const ack = if (flags & ACK != 0) tcb.rcv_nxt else 0;

    var opt_buf: [48]u8 = @splat(0);
    var opt_len: u8 = 0;
    const is_syn = (flags & SYN) != 0;

    if (is_syn) {
        // SK-100: MSS first (RFC 9293 recommends early in the option list).
        const offer = localMssForTcb(tcb);
        opt_buf[opt_len] = 2;
        opt_buf[opt_len + 1] = 4;
        bo.writeU16BeAt(&opt_buf, opt_len + 2, offer);
        opt_len += 4;

        opt_buf[opt_len] = 3;
        opt_buf[opt_len + 1] = 3;
        opt_buf[opt_len + 2] = @intCast(tcb.ws_requested);
        opt_len += 3;

        const now_ms = timestampMs();
        tcb.ts_val_last = now_ms;
        opt_buf[opt_len] = 8;
        opt_buf[opt_len + 1] = 10;
        bo.writeU32BeAt(&opt_buf, opt_len + 2, now_ms);
        bo.writeU32BeAt(&opt_buf, opt_len + 6, tcb.ts_recent);
        opt_len += 10;

        opt_buf[opt_len] = 4;
        opt_buf[opt_len + 1] = 2;
        opt_len += 2;

        while (opt_len % 4 != 0) : (opt_len += 1) {
            opt_buf[opt_len] = 1;
        }
    } else {
        if (tcb.ts_enabled) {
            const now_ms = timestampMs();
            tcb.ts_val_last = now_ms;
            opt_buf[opt_len] = 8;
            opt_buf[opt_len + 1] = 10;
            bo.writeU32BeAt(&opt_buf, opt_len + 2, now_ms);
            bo.writeU32BeAt(&opt_buf, opt_len + 6, tcb.ts_recent);
            opt_len += 10;
        }

        if (tcb.sack_permitted and tcb.sack_block_count > 0 and (flags & ACK != 0)) {
            const num_blocks = tcb.sack_block_count;
            const sack_len: u8 = 2 + @as(u8, num_blocks) * 8;
            opt_buf[opt_len] = 5;
            opt_buf[opt_len + 1] = sack_len;
            opt_len += 2;
            var bi: u3 = 0;
            while (bi < num_blocks) : (bi += 1) {
                const blk = &tcb.sack_blocks[bi];
                bo.writeU32BeAt(&opt_buf, opt_len, blk.left);
                bo.writeU32BeAt(&opt_buf, opt_len + 4, blk.right);
                opt_len += 8;
            }
            tcb.sack_block_count = 0;
        }

        while (opt_len % 4 != 0) : (opt_len += 1) {
            opt_buf[opt_len] = 1;
        }
    }

    const data_offset_val: u8 = @intCast((20 + opt_len) / 4);
    const raw_window: u16 = if (tcb.ws_enabled) blk: {
        const scaled = tcb.rcv_wnd >> @intCast(tcb.rcv_wnd_scale);
        break :blk if (scaled > 0xFFFF) 0xFFFF else @intCast(scaled);
    } else @truncate(tcb.rcv_wnd);

    bo.writeU16BeAt(pkt, tcp_off + 0, tcb.local_port);
    bo.writeU16BeAt(pkt, tcp_off + 2, tcb.remote_port);
    bo.writeU32BeAt(pkt, tcp_off + 4, seq);
    bo.writeU32BeAt(pkt, tcp_off + 8, ack);
    pkt[tcp_off + 12] = data_offset_val << 4;
    pkt[tcp_off + 13] = flags;
    bo.writeU16BeAt(pkt, tcp_off + 14, raw_window);
    pkt[tcp_off + 16] = 0;
    pkt[tcp_off + 17] = 0;
    pkt[tcp_off + 18] = 0;
    pkt[tcp_off + 19] = 0;

    if (opt_len > 0) {
        @memcpy(pkt[tcp_off + 20 ..][0..opt_len], opt_buf[0..opt_len]);
    }

    const hdr_total = 20 + opt_len;
    if (data_len > 0) {
        @memcpy(pkt[tcp_off + hdr_total ..][0..data_len], data[0..data_len]);
    }
    return @intCast(hdr_total + data_len);
}

fn advanceSndNxt(tcb: *TcpTcb, flags: u8, data_len: u16) void {
    if (data_len > 0) tcb.snd_nxt +%= data_len;
    if (flags & SYN != 0) tcb.snd_nxt +%= 1;
    if (flags & FIN != 0) tcb.snd_nxt +%= 1;
}

/// Local SMSS before peer clamp (SK-98/100/101).
fn localMssForTcb(tcb: *const TcpTcb) u16 {
    if (!tcb.is_v6) {
        const pmtu = ipv4.getPathMtu(tcb.remote_ip);
        if (pmtu <= TCP_IPV4_OVERHEAD) return 1;
        return @min(TCP_MSS, pmtu - TCP_IPV4_OVERHEAD);
    }
    const pmtu = ipv6.getPathMtu(tcb.remote_ip6);
    if (pmtu <= TCP_IPV6_OVERHEAD) return 1;
    return @min(TCP_MSS, pmtu - TCP_IPV6_OVERHEAD);
}

/// Sender MSS for this TCB (SK-98/100): min(local SMSS, peer MSS).
fn mssForTcb(tcb: *const TcpTcb) u16 {
    const local = localMssForTcb(tcb);
    if (tcb.peer_mss != 0 and tcb.peer_mss < local) return tcb.peer_mss;
    return local;
}

/// Probe helper (SK-98): IPv6 SMSS for `dst` from the Path MTU cache.
pub fn probeIpv6Mss(dst: [16]u8) u16 {
    const pmtu = ipv6.getPathMtu(dst);
    if (pmtu <= TCP_IPV6_OVERHEAD) return 1;
    return @min(TCP_MSS, pmtu - TCP_IPV6_OVERHEAD);
}

/// Probe helper (SK-101): IPv4 SMSS for `dst` from the Path MTU cache.
pub fn probeIpv4Mss(dst: [4]u8) u16 {
    const pmtu = ipv4.getPathMtu(dst);
    if (pmtu <= TCP_IPV4_OVERHEAD) return 1;
    return @min(TCP_MSS, pmtu - TCP_IPV4_OVERHEAD);
}

/// Probe helper (SK-100): effective MSS = min(local, peer); peer 0 = local only.
pub fn probeMssWithPeer(local_mss: u16, peer_mss: u16) u16 {
    if (peer_mss != 0 and peer_mss < local_mss) return peer_mss;
    return local_mss;
}

/// Probe helper (SK-100): parse MSS option from a TCP header (`data_offset` bytes).
pub fn probeParseMss(data: [*]const u8, data_offset: u16) ?u16 {
    return parseTcpOptions(data, data_offset).mss;
}

/// Probe helper (SK-100): MSS value we advertise on SYN for IPv6 `dst`.
pub fn probeSynOfferMssV6(dst: [16]u8) u16 {
    return probeIpv6Mss(dst);
}

/// Probe helper (SK-99): Reno CA increment for one ACK using SMSS.
pub fn probeIpv6RenoCaInc(dst: [16]u8, cwnd: u32) u32 {
    const smss: u32 = probeIpv6Mss(dst);
    return (smss * smss) / @max(cwnd, 1);
}

/// Probe helper (SK-99): minimum ssthresh = 2×SMSS.
pub fn probeIpv6RenoMinSsthresh(dst: [16]u8) u32 {
    return 2 * @as(u32, probeIpv6Mss(dst));
}

/// Build and send a TCP segment (IPv4 or IPv6).
fn sendSegment(tcb: *TcpTcb, flags: u8, data: [*]const u8, data_len: u16) bool {
    return sendSegmentSeq(tcb, flags, data, data_len, null);
}

/// Like `sendSegment`, but may override the SEQ field (SK-109 keepalive).
fn sendSegmentSeq(tcb: *TcpTcb, flags: u8, data: [*]const u8, data_len: u16, seq_override: ?u32) bool {
    if (tcb.is_v6) return sendSegmentV6Seq(tcb, flags, data, data_len, seq_override);

    // SK-101: segment payload must fit Path MTU − IPv4 − TCP headers.
    if (data_len > mssForTcb(tcb)) return false;

    var send_pkt: [1518]u8 = @splat(0);
    const dst_mac = arp.resolve(tcb.remote_ip) orelse {
        tcpLog("[tcp] ARP resolution failed\n");
        return false;
    };

    const our_mac = netif.getMac();
    const our_ip = netif.getOurIp();
    const tcp_off: u16 = 34;
    const tcp_total = fillTcpSegment(tcb, flags, data, data_len, &send_pkt, tcp_off, seq_override);
    // SK-101/105: honor Path MTU (or armed oversized raise probe).
    if (ipv4.HEADER_LEN + tcp_total > ipv4.getSendMtu(tcb.remote_ip)) return false;
    const csum = tcpChecksum(our_ip, tcb.remote_ip, send_pkt[tcp_off..].ptr, tcp_total);
    bo.writeU16BeAt(&send_pkt, tcp_off + 16, csum);
    ipv4.buildHeader(send_pkt[14..].ptr, our_ip, tcb.remote_ip, ipv4.PROTO_TCP, tcp_total);
    const frame_len = eth.buildFrame(&send_pkt, dst_mac, our_mac, eth.ETHERTYPE_IPV4, 20 + tcp_total);
    const ok = nic.sendPacket(&send_pkt, frame_len);
    // SK-104: full-MTU TX success can raise the Path MTU early.
    if (ok) ipv4.noteFullSizeSend(tcb.remote_ip, ipv4.HEADER_LEN + tcp_total);
    advanceSndNxt(tcb, flags, data_len);
    return true;
}

/// IPv6 TCP TX (SK-76/87/98): on-link NDP or off-link via default router.
fn sendSegmentV6(tcb: *TcpTcb, flags: u8, data: [*]const u8, data_len: u16) bool {
    return sendSegmentV6Seq(tcb, flags, data, data_len, null);
}

fn sendSegmentV6Seq(tcb: *TcpTcb, flags: u8, data: [*]const u8, data_len: u16, seq_override: ?u32) bool {
    // SK-98: segment payload must fit Path MTU − IPv6 − TCP headers.
    if (data_len > mssForTcb(tcb)) return false;

    const nh = ndp.resolveNextHop(tcb.remote_ip6);
    const dst_mac = nh.mac orelse {
        if (nh.solicit) |t| icmpv6.sendNeighborSolicitation(t);
        tcpLog("[tcp] NDP resolution failed\n");
        return false;
    };

    const our_mac = netif.getMac();
    const our_ip = ndp.selectSourceAddress(tcb.remote_ip6, our_mac);
    var send_pkt: [1518]u8 = @splat(0);
    const tcp_off: u16 = 14 + ipv6.HEADER_LEN;
    const tcp_total = fillTcpSegment(tcb, flags, data, data_len, &send_pkt, tcp_off, seq_override);
    // SK-97/105: honor Path MTU (or armed oversized raise probe).
    if (ipv6.HEADER_LEN + tcp_total > ipv6.getSendMtu(tcb.remote_ip6)) return false;
    const csum = tcpChecksumV6(our_ip, tcb.remote_ip6, send_pkt[tcp_off..].ptr, tcp_total);
    bo.writeU16BeAt(&send_pkt, tcp_off + 16, csum);
    ipv6.buildHeader(send_pkt[14..].ptr, our_ip, tcb.remote_ip6, ipv6.PROTO_TCP, tcp_total);
    const frame_len = eth.buildFrame(&send_pkt, dst_mac, our_mac, eth.ETHERTYPE_IPV6, ipv6.HEADER_LEN + tcp_total);
    const ok = nic.sendPacket(&send_pkt, frame_len);
    // SK-104: full-MTU TX success can raise the Path MTU early.
    if (ok) ipv6.noteFullSizeSend(tcb.remote_ip6, ipv6.HEADER_LEN + tcp_total);
    advanceSndNxt(tcb, flags, data_len);
    return true;
}

/// Get a monotonically increasing millisecond timestamp for TCP timestamps.
fn timestampMs() u32 {
    const idt = @import("../arch/arch.zig").interrupts;
    return @truncate(idt.getTickCount() * 10); // ticks are ~10ms each, convert to ms
}

/// TCP checksum with IPv4 pseudo-header — arch-clean impl in tcp_util.zig.
fn tcpChecksum(src_ip: [4]u8, dst_ip: [4]u8, tcp_hdr: [*]const u8, tcp_len: u16) u16 {
    return tcp_util.checksum(src_ip, dst_ip, tcp_hdr, tcp_len);
}

fn tcpChecksumV6(src_ip: [16]u8, dst_ip: [16]u8, tcp_hdr: [*]const u8, tcp_len: u16) u16 {
    return tcp_util.checksumV6(src_ip, dst_ip, tcp_hdr, tcp_len);
}

/// IPv6 TCP receive (SK-74..77): checksum, demux/listen SYN, shared state machine.
pub fn handlePacketV6(src_ip: [16]u8, dst_ip: [16]u8, data: [*]const u8, len: u32) void {
    if (len < 20) return;
    const tcp_len: u16 = @intCast(@min(len, 0xFFFF));
    const data_offset = (@as(u16, data[12]) >> 4) * 4;
    if (data_offset < 20 or data_offset > tcp_len) return;

    const wire_csum = bo.readU16BeAt(data, 16);
    if (wire_csum == 0) return;
    const expect = tcpChecksumV6(src_ip, dst_ip, data, tcp_len);
    if (wire_csum != expect) return;

    const epoll = @import("epoll.zig");
    var pending_events: u32 = 0;
    var pending_idx: u32 = 0;
    defer {
        if (pending_events != 0) {
            epoll.epollNotify(.tcp_socket, pending_idx, pending_events);
        }
    }

    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);

    const src_port = bo.readU16BeAt(data, 0);
    const dst_port = bo.readU16BeAt(data, 2);
    const seq_num = bo.readU32BeAt(data, 4);
    const ack_num = bo.readU32BeAt(data, 8);
    const flags = data[13];
    const raw_window = bo.readU16BeAt(data, 14);
    const opts = parseTcpOptions(data, data_offset);
    const payload_len: u32 = if (tcp_len > data_offset) tcp_len - data_offset else 0;

    const tcb = findTcbByTupleV6(dst_port, src_port, src_ip) orelse {
        if (flags & SYN != 0) {
            handleIncomingSynV6(src_ip, src_port, dst_port, seq_num, raw_window, opts);
        }
        return;
    };

    driveTcbStateMachine(tcb, seq_num, ack_num, flags, raw_window, opts, data, data_offset, payload_len, &pending_events, &pending_idx);
}

// ─── Incoming Packet Handling ─────────────────────────────────────────────

/// Parsed TCP options from an incoming segment.
const TcpOptions = struct {
    mss: ?u16 = null, // Maximum Segment Size (kind 2) (SK-100)
    ws_shift: ?u4 = null, // window scale shift count (kind 3)
    ts_val: ?u32 = null, // timestamp value (kind 8)
    ts_ecr: ?u32 = null, // timestamp echo reply (kind 8)
    sack_permitted: bool = false, // SACK-Permitted (kind 4)
    sack_blocks: [4]SackBlock = @splat(.{ .left = 0, .right = 0 }),
    sack_block_count: u3 = 0,
};

/// Parse TCP options from the header (between byte 20 and data_offset).
fn parseTcpOptions(data: [*]const u8, data_offset: u16) TcpOptions {
    var opts = TcpOptions{};
    var pos: u16 = 20; // start of options
    while (pos + 1 < data_offset) {
        const kind = data[pos];
        switch (kind) {
            0 => break, // End of Options List
            1 => pos += 1, // NOP — no length field
            2 => { // MSS (SK-100)
                if (pos + 3 < data_offset and data[pos + 1] == 4) {
                    opts.mss = bo.readU16BeAt(data, pos + 2);
                }
                pos += 4;
            },
            3 => { // Window Scale
                if (pos + 2 < data_offset and data[pos + 1] == 3) {
                    opts.ws_shift = @intCast(data[pos + 2] & 0x0F);
                }
                pos += 3;
            },
            8 => { // Timestamps
                if (pos + 9 < data_offset and data[pos + 1] == 10) {
                    opts.ts_val = bo.readU32BeAt(data, pos + 2);
                    opts.ts_ecr = bo.readU32BeAt(data, pos + 6);
                }
                pos += 10;
            },
            4 => { // SACK-Permitted (kind=4, len=2)
                if (pos + 1 < data_offset and data[pos + 1] == 2) {
                    opts.sack_permitted = true;
                }
                pos += 2;
            },
            5 => { // SACK blocks (kind=5, len=2+8*N)
                if (pos + 1 < data_offset) {
                    const sack_len = data[pos + 1];
                    if (sack_len < 2) break; // v53.46: Prevent infinite loop on malformed SACK
                    if (sack_len >= 10) { // at least 1 block
                        const num_blocks: u3 = @intCast(@min((sack_len - 2) / 8, 4));
                        var b: u3 = 0;
                        while (b < num_blocks) : (b += 1) {
                            const boff = pos + 2 + @as(u16, b) * 8;
                            if (boff + 7 < data_offset) {
                                const left = bo.readU32BeAt(data, boff);
                                const right = bo.readU32BeAt(data, boff + 4);
                                opts.sack_blocks[b] = .{ .left = left, .right = right };
                            }
                        }
                        opts.sack_block_count = num_blocks;
                    }
                    pos += sack_len;
                } else break;
            },
            else => {
                // Unknown option: read length and skip
                if (pos + 1 < data_offset) {
                    const len = data[pos + 1];
                    if (len < 2) break; // malformed
                    pos += len;
                } else break;
            },
        }
    }
    return opts;
}

/// Update RTT estimation using Jacobson/Karels algorithm.
/// `m` is the measured RTT sample in milliseconds.
fn updateRtt(tcb: *TcpTcb, m: u32) void {
    if (tcb.srtt == 0) {
        // First measurement
        tcb.srtt = m;
        tcb.rttvar = m / 2;
    } else {
        // Jacobson/Karels
        const delta = if (m >= tcb.srtt) m - tcb.srtt else tcb.srtt - m;
        tcb.rttvar = (3 * tcb.rttvar + delta) / 4;
        tcb.srtt = (7 * tcb.srtt + m) / 8;
    }
    tcb.rto = tcb.srtt + @max(200, 4 * tcb.rttvar);
    if (tcb.rto < TCP_RTO_MIN) tcb.rto = TCP_RTO_MIN;
    if (tcb.rto > TCP_RTO_MAX) tcb.rto = TCP_RTO_MAX;
}

fn applyPeerMss(tcb: *TcpTcb, opts: TcpOptions) void {
    if (opts.mss) |m| {
        // Ignore zero/nonsense; keep prior if already set.
        if (m != 0) tcb.peer_mss = m;
    }
}

/// Called from net/mod.zig when an IPv4 packet with protocol=6 is received.
/// Handle an incoming SYN for a listening socket.
/// Creates a new TCB in SYN_RECEIVED state, sends SYN-ACK,
/// and queues it in the listen backlog.
fn handleIncomingSyn(src_ip: [4]u8, src_port: u16, dst_port: u16, seq_num: u32, _w: u16, opts: TcpOptions) void {
    _ = _w;
    // Find listen slot for this port (bitmap-driven)
    var slot: ?*ListenSlot = null;
    var lbm = listen_active_bitmap;
    while (lbm != 0) {
        const i = @ctz(lbm);
        lbm &= lbm - 1;
        if (listen_slots[i].local_port == dst_port and !listen_slots[i].is_v6) {
            slot = &listen_slots[i];
            break;
        }
    }
    const ls = slot orelse return;

    // T17: Allow TCB reuse for TIME_WAIT connections (if ISN is larger)
    var tw_bm = @atomicLoad(u64, &tcb_active_bitmap, .acquire);
    while (tw_bm != 0) {
        const i = @ctz(tw_bm);
        tw_bm &= tw_bm - 1;
        if (tcbs[i].state == .time_wait and
            !tcbs[i].is_v6 and
            tcbs[i].local_port == dst_port and
            tcbs[i].remote_port == src_port and
            @as(u32, @bitCast(seq_num -% tcbs[i].irs)) > 0)
        {
            // Reuse this TIME_WAIT TCB
            const reuse_tcb = &tcbs[i];
            reuse_tcb.iss = generateIss();
            reuse_tcb.snd_una = reuse_tcb.iss;
            reuse_tcb.snd_nxt = reuse_tcb.iss;
            reuse_tcb.irs = seq_num;
            reuse_tcb.rcv_nxt = seq_num + 1;
            reuse_tcb.rcv_wnd = TCP_WINDOW;
            reuse_tcb.state = .syn_received;
            reuse_tcb.retransmit_timer = 0;
            reuse_tcb.sack_block_count = 0;
            reuse_tcb.sack_scoreboard_count = 0;

            if (opts.ws_shift) |peer_ws| {
                reuse_tcb.snd_wnd_scale = peer_ws;
                reuse_tcb.ws_enabled = true;
            }
            if (opts.ts_val) |tv| {
                reuse_tcb.ts_recent = tv;
                reuse_tcb.ts_enabled = true;
            }
            if (opts.sack_permitted) {
                reuse_tcb.sack_permitted = true;
            }
            applyPeerMss(reuse_tcb, opts);

            _ = sendSegment(reuse_tcb, SYN | ACK, undefined, 0);
            tcpLog("[tcp] TIME_WAIT reuse → SYN-ACK\n");
            return;
        }
    }

    // Check backlog capacity
    if (ls.pending_tail -% ls.pending_head >= LISTEN_BACKLOG) return;

    // Allocate a new TCB for this connection
    const new_tcb = allocTcb() orelse return;
    new_tcb.local_port = dst_port;
    new_tcb.remote_port = src_port;
    new_tcb.remote_ip = src_ip;
    new_tcb.owner_task = ls.owner_task;
    new_tcb.iss = generateIss();
    new_tcb.snd_una = new_tcb.iss;
    new_tcb.snd_nxt = new_tcb.iss;
    new_tcb.snd_wnd = TCP_WINDOW;
    new_tcb.irs = seq_num;
    new_tcb.rcv_nxt = seq_num + 1;
    new_tcb.rcv_wnd = TCP_WINDOW;
    new_tcb.state = .syn_received;

    // Negotiate Window Scaling
    if (opts.ws_shift) |peer_ws| {
        new_tcb.snd_wnd_scale = peer_ws; // peer's scale → we apply when reading their window
        new_tcb.ws_enabled = true;
    }

    // Negotiate Timestamps
    if (opts.ts_val) |tv| {
        new_tcb.ts_recent = tv;
        new_tcb.ts_enabled = true;
    }

    // Negotiate SACK-Permitted
    if (opts.sack_permitted) {
        new_tcb.sack_permitted = true;
    }
    applyPeerMss(new_tcb, opts);

    // Send SYN-ACK
    _ = sendSegment(new_tcb, SYN | ACK, undefined, 0);
    tcpLog("[tcp] SYN-ACK sent for incoming connection\n");

    // Find the index of the new TCB
    const new_idx = tcbIdx(new_tcb);

    // Queue in listen backlog (will be moved to established when ACK arrives)
    ls.pending_tpbs[ls.pending_tail % LISTEN_BACKLOG] = new_idx;
    ls.pending_tail += 1;
}

/// IPv6 listen SYN (SK-75/76). Creates SYN_RECEIVED and sends SYN-ACK via NDP.
fn handleIncomingSynV6(src_ip: [16]u8, src_port: u16, dst_port: u16, seq_num: u32, _w: u16, opts: TcpOptions) void {
    _ = _w;
    var slot: ?*ListenSlot = null;
    var lbm = listen_active_bitmap;
    while (lbm != 0) {
        const i = @ctz(lbm);
        lbm &= lbm - 1;
        if (listen_slots[i].local_port == dst_port and listen_slots[i].is_v6) {
            slot = &listen_slots[i];
            break;
        }
    }
    const ls = slot orelse return;

    var tw_bm = @atomicLoad(u64, &tcb_active_bitmap, .acquire);
    while (tw_bm != 0) {
        const i = @ctz(tw_bm);
        tw_bm &= tw_bm - 1;
        if (tcbs[i].state == .time_wait and
            tcbs[i].is_v6 and
            tcbs[i].local_port == dst_port and
            tcbs[i].remote_port == src_port and
            ipv6.addrEq(tcbs[i].remote_ip6, src_ip) and
            @as(u32, @bitCast(seq_num -% tcbs[i].irs)) > 0)
        {
            const reuse_tcb = &tcbs[i];
            reuse_tcb.iss = generateIss();
            reuse_tcb.snd_una = reuse_tcb.iss;
            reuse_tcb.snd_nxt = reuse_tcb.iss;
            reuse_tcb.irs = seq_num;
            reuse_tcb.rcv_nxt = seq_num + 1;
            reuse_tcb.rcv_wnd = TCP_WINDOW;
            reuse_tcb.state = .syn_received;
            reuse_tcb.retransmit_timer = 0;
            reuse_tcb.sack_block_count = 0;
            reuse_tcb.sack_scoreboard_count = 0;
            if (opts.ws_shift) |peer_ws| {
                reuse_tcb.snd_wnd_scale = peer_ws;
                reuse_tcb.ws_enabled = true;
            }
            if (opts.ts_val) |tv| {
                reuse_tcb.ts_recent = tv;
                reuse_tcb.ts_enabled = true;
            }
            if (opts.sack_permitted) reuse_tcb.sack_permitted = true;
            applyPeerMss(reuse_tcb, opts);
            _ = sendSegment(reuse_tcb, SYN | ACK, undefined, 0);
            return;
        }
    }

    if (ls.pending_tail -% ls.pending_head >= LISTEN_BACKLOG) return;

    const new_tcb = allocTcb() orelse return;
    new_tcb.local_port = dst_port;
    new_tcb.remote_port = src_port;
    new_tcb.is_v6 = true;
    new_tcb.remote_ip6 = src_ip;
    new_tcb.owner_task = ls.owner_task;
    new_tcb.iss = generateIss();
    new_tcb.snd_una = new_tcb.iss;
    new_tcb.snd_nxt = new_tcb.iss;
    new_tcb.snd_wnd = TCP_WINDOW;
    new_tcb.irs = seq_num;
    new_tcb.rcv_nxt = seq_num + 1;
    new_tcb.rcv_wnd = TCP_WINDOW;
    new_tcb.state = .syn_received;

    if (opts.ws_shift) |peer_ws| {
        new_tcb.snd_wnd_scale = peer_ws;
        new_tcb.ws_enabled = true;
    }
    if (opts.ts_val) |tv| {
        new_tcb.ts_recent = tv;
        new_tcb.ts_enabled = true;
    }
    if (opts.sack_permitted) new_tcb.sack_permitted = true;
    applyPeerMss(new_tcb, opts);

    _ = sendSegment(new_tcb, SYN | ACK, undefined, 0);

    const new_idx = tcbIdx(new_tcb);
    ls.pending_tpbs[ls.pending_tail % LISTEN_BACKLOG] = new_idx;
    ls.pending_tail += 1;
}

/// Shared post-demux TCP state machine for IPv4 and IPv6 (SK-77).
/// Caller must hold `tcp_lock`. Updates `pending_events`/`pending_idx` for epoll.
fn driveTcbStateMachine(
    tcb: *TcpTcb,
    seq_num: u32,
    ack_num: u32,
    flags: u8,
    raw_window: u16,
    opts: TcpOptions,
    data: [*]const u8,
    payload_offset: u16,
    payload_len: u32,
    pending_events: *u32,
    pending_idx: *u32,
) void {
    const epoll = @import("epoll.zig");

    // Any matched segment counts as activity (keepalive idle reset).
    tcb.idle_ms = 0;

    // Update ts_recent for PAWS
    if (opts.ts_val) |tv| {
        tcb.ts_recent = tv;
    }

    // Apply window scaling to the received window value
    const window: u32 = if (tcb.ws_enabled)
        @as(u32, raw_window) << @intCast(tcb.snd_wnd_scale)
    else
        raw_window;

    // v53.5: Handle RST per RFC 793 in all non-closed/non-listen states
    // RST with valid sequence number immediately terminates the connection.
    // .syn_sent has special RST handling (must match our SYN's ACK).
    // .established already has its own RST handler (v53.3) with in_window check
    // that also handles ACK processing — we skip it here to avoid double-processing.
    if (flags & RST != 0 and tcb.state != .closed and tcb.state != .listen and tcb.state != .established) {
        if (tcb.state == .syn_sent) {
            // RFC 793 §3.4: RST in SYN_SENT is valid if ack_num == iss+1
            if (ack_num == tcb.iss +% 1) {
                tcb.state = .closed;
                deactivateTcb(tcb);
                tcpLog("[tcp] RST in SYN_SENT, connection reset\n");
                return;
            }
        } else {
            // RFC 793: RST is valid if seq_num is within the receive window
            const in_window = seq_num -% tcb.rcv_nxt < tcb.rcv_wnd;
            if (in_window) {
                tcb.state = .closed;
                deactivateTcb(tcb);
                tcpLog("[tcp] RST received, connection reset\n");
                return;
            }
        }
    }

    // State machine processing
    switch (tcb.state) {
        .syn_sent => {
            if (flags & (SYN | ACK) == (SYN | ACK)) {
                // SYN-ACK received — handshake complete
                tcb.irs = seq_num;
                tcb.rcv_nxt = seq_num + 1;
                tcb.snd_una = ack_num;
                tcb.snd_wnd = window;
                tcb.state = .established;

                // Negotiate Window Scaling from SYN-ACK options
                if (opts.ws_shift) |peer_ws| {
                    tcb.snd_wnd_scale = peer_ws;
                    tcb.ws_enabled = true;
                }

                // Negotiate Timestamps from SYN-ACK options
                if (opts.ts_val) |tv| {
                    tcb.ts_recent = tv;
                    tcb.ts_enabled = true;
                }

                // Negotiate SACK-Permitted
                if (opts.sack_permitted) {
                    tcb.sack_permitted = true;
                }
                applyPeerMss(tcb, opts);

                // RTT measurement: if our SYN carried ts_val_last and
                // the ACK echoes it back, measure initial RTT.
                if (opts.ts_ecr) |ecr| {
                    if (ecr == tcb.ts_val_last) {
                        const now = timestampMs();
                        const rtt_sample = now -% ecr;
                        updateRtt(tcb, rtt_sample);
                    }
                }

                // Initialize cwnd after handshake (SK-99: SMSS).
                tcb.cwnd = mssForTcb(tcb);
                tcb.dup_ack_count = 0;
                tcb.in_recovery = false;

                // Send ACK to complete handshake
                _ = sendSegment(tcb, ACK, undefined, 0);

                tcpLog("[tcp] connection established\n");

                // v53.41: Defer epoll notification outside tcp_lock
                pending_events.* |= epoll.EPOLLOUT;
                pending_idx.* = tcbIdx(tcb);
            } else if (flags & SYN != 0) {
                // v53.5: Simultaneous open not supported — send RST and close
                _ = sendSegment(tcb, RST, undefined, 0);
                tcb.state = .closed;
                deactivateTcb(tcb);
            }
        },
        .syn_received => {
            // Third ACK of three-way handshake (from client)
            if (flags & ACK != 0) {
                tcb.snd_una = ack_num;
                tcb.snd_wnd = window;
                tcb.state = .established;
                tcb.retransmit_timer = 0;
                tcpLog("[tcp] server: connection established (ACK received)\n");

                // v53.41: Defer epoll notification outside tcp_lock
                pending_events.* |= epoll.EPOLLOUT;
                pending_idx.* = tcbIdx(tcb);
            }
        },
        .established => {
            // v53.3: Handle RST per RFC 793 — abort connection immediately
            if (flags & RST != 0) {
                // RST is valid if seq_num is within window
                const in_window = seq_num -% tcb.rcv_nxt < tcb.rcv_wnd;
                if (in_window) {
                    tcb.state = .closed;
                    deactivateTcb(tcb);
                    tcpLog("[tcp] RST received, connection reset\n");
                    return;
                }
            }

            // Process ACK
            if (flags & ACK != 0) {
                if (ack_num != tcb.snd_una) {
                    // New ACK — advance send window
                    const acked = ack_num -% tcb.snd_una;
                    // v53.3: ack_num must be within [snd_una+1, snd_nxt] range
                    const in_flight = tcb.snd_nxt -% tcb.snd_una;
                    if (acked > 0 and acked <= in_flight and acked <= SEND_BUF_SIZE) {
                        const sacked_before = sackedBytesInFlight(tcb);
                        tcb.snd_una = ack_num;
                        // v53.2: advance send_head to free acknowledged buffer space
                        // Without this, the ring buffer permanently fills → connection deadlock
                        tcb.send_head = (tcb.send_head + acked) % SEND_BUF_SIZE;
                        tcb.send_unacked = (tcb.send_unacked + acked) % SEND_BUF_SIZE;
                        tcb.retransmit_timer = 0;
                        tcb.retransmit_count = 0;
                        // SK-113: trim/merge scoreboard (do not wipe holes still above snd_una).
                        if (opts.sack_block_count > 0) {
                            updateScoreboard(tcb, opts.sack_blocks[0..opts.sack_block_count]);
                        } else {
                            updateScoreboard(tcb, &.{});
                        }
                        const sacked_after = sackedBytesInFlight(tcb);
                        const newly_sacked: u32 = if (sacked_after > sacked_before)
                            sacked_after - sacked_before
                        else
                            0;
                        const delivered = acked + newly_sacked;

                        // Keepalive: reset idle timer and probe count on new ACK
                        tcb.idle_ms = 0;
                        tcb.keepalive_probes = 0;

                        // Nagle: if data was pending and in-flight is now empty, flush
                        // This is also handled in timerTick, but check here for faster response
                        if (tcb.nagle_pending and tcb.snd_nxt == tcb.snd_una) {
                            tcb.nagle_pending = false;
                            flushSendBuffer(tcb);
                        }

                        // RTT measurement via timestamps
                        if (tcb.ts_enabled) {
                            if (opts.ts_ecr) |ecr| {
                                if (ecr == tcb.ts_val_last) {
                                    const now = timestampMs();
                                    const rtt_sample = now -% ecr;
                                    updateRtt(tcb, rtt_sample);
                                }
                            }
                        }

                        // Congestion control on new ACK (SK-99 SMSS; SK-114 PRR in recovery).
                        const smss: u32 = mssForTcb(tcb);
                        if (tcb.in_recovery) {
                            if (ack_num -% 1 >= tcb.recover_seq) {
                                tcb.in_recovery = false;
                                tcb.cwnd = tcb.ssthresh;
                                tcb.dup_ack_count = 0;
                                tcb.recover_fs = 0;
                                tcb.prr_delivered = 0;
                                tcb.prr_out = 0;
                            } else {
                                applyPrr(tcb, delivered);
                                flushSendBuffer(tcb);
                            }
                        } else {
                            // Normal: increase cwnd
                            if (tcb.cwnd < tcb.ssthresh) {
                                // Slow start: exponential growth
                                tcb.cwnd += @intCast(acked);
                            } else {
                                // Congestion avoidance: additive increase
                                // cwnd += SMSS * SMSS / cwnd per ACK
                                const inc = (smss * smss) / @max(tcb.cwnd, 1);
                                tcb.cwnd += inc;
                            }
                            tcb.dup_ack_count = 0;
                        }

                        // v53.41: Defer epoll notification outside tcp_lock
                        pending_events.* |= epoll.EPOLLOUT;
                        pending_idx.* = tcbIdx(tcb);
                    }
                } else {
                    // Duplicate ACK (ack_num == snd_una)
                    if (payload_len == 0) {
                        const sacked_before = sackedBytesInFlight(tcb);
                        // SK-113: merge incoming SACK blocks into the scoreboard.
                        if (opts.sack_block_count > 0) {
                            updateScoreboard(tcb, opts.sack_blocks[0..opts.sack_block_count]);
                        }
                        const sacked_after = sackedBytesInFlight(tcb);
                        const delivered: u32 = if (sacked_after > sacked_before)
                            sacked_after - sacked_before
                        else
                            0;

                        tcb.dup_ack_count += 1;

                        // SK-112: enter recovery on DupThresh dupacks OR RFC 6675 IsLost(snd_una).
                        const enter_recovery = !tcb.in_recovery and
                            (tcb.dup_ack_count >= DUP_THRESH or isLost(tcb, tcb.snd_una));
                        if (enter_recovery) {
                            // Fast retransmit + PRR recovery (SK-114).
                            const smss_fr: u32 = mssForTcb(tcb);
                            const pipe = pipeBytes(tcb);
                            tcb.in_recovery = true;
                            tcb.recover_seq = tcb.snd_nxt;
                            tcb.ssthresh = @max(tcb.cwnd / 2, 2 * smss_fr);
                            tcb.recover_fs = @max(pipe, 1);
                            tcb.prr_delivered = 0;
                            tcb.prr_out = 0;
                            applyPrr(tcb, delivered);
                            // Force at least one SMSS for the fast retransmit.
                            const pipe2 = pipeBytes(tcb);
                            if (tcb.cwnd < pipe2 + smss_fr) tcb.cwnd = pipe2 + smss_fr;

                            // SK-108: retransmit the first non-SACKed hole, not always snd_una.
                            const unacked = ringDataLen(tcb.send_head, tcb.send_tail, SEND_BUF_SIZE);
                            if (unacked > 0) {
                                prepareRexmitFromHole(tcb);
                                flushSendBuffer(tcb);
                            }
                            tcpLog("[tcp] fast retransmit\n");
                        } else if (tcb.in_recovery) {
                            applyPrr(tcb, delivered);
                            flushSendBuffer(tcb);
                        }
                    }
                }
                tcb.snd_wnd = window;
                // SK-110: window reopen cancels persist and drains queued data.
                if (window > 0) {
                    tcb.persist_timer_ms = 0;
                    tcb.persist_rto_ms = RETRANSMIT_MS;
                    flushSendBuffer(tcb);
                }
            }

            // Process incoming data
            if (payload_len > 0) {
                processIncomingData(tcb, data + payload_offset, payload_len, seq_num);
                // v53.41: Defer epoll notification outside tcp_lock
                pending_events.* |= epoll.EPOLLIN;
                pending_idx.* = tcbIdx(tcb);
            }

            // Handle FIN — v53.4: only accept FIN after all data is buffered
            // If recv_buf was full and we couldn't buffer all data, rcv_nxt
            // hasn't advanced past the data segment, so the FIN seq would be
            // wrong and the peer would retransmit. Defer FIN until data drains.
            if (flags & FIN != 0) {
                const fin_seq = seq_num +% payload_len;
                const data_fully_buffered = (tcb.rcv_nxt -% seq_num >= payload_len);
                if (data_fully_buffered and fin_seq == tcb.rcv_nxt) {
                    tcb.rcv_nxt +%= 1;
                    tcb.state = .close_wait;
                    tcb.delayed_ack_pending = false; // ACK is immediate for FIN
                    _ = sendSegment(tcb, ACK, undefined, 0);
                    tcpLog("[tcp] remote closed (FIN received)\n");
                    // v53.41: Defer epoll notification outside tcp_lock
                    pending_events.* |= epoll.EPOLLIN | epoll.EPOLLHUP;
                    pending_idx.* = tcbIdx(tcb);
                }
                // else: FIN deferred — peer will retransmit after we ACK the partial data
            }
        },
        .fin_wait_1 => {
            if (flags & FIN != 0) {
                // v53.6/v53.10: RFC 793 — FIN+ACK (our FIN confirmed) → TIME_WAIT; FIN only (simultaneous close) → CLOSING
                tcb.rcv_nxt +%= 1;
                if (flags & ACK != 0 and ack_num >= tcb.snd_nxt) {
                    // Our FIN was ACKed (ack covers snd_nxt which includes FIN seq) → TIME_WAIT
                    tcb.snd_una = ack_num;
                    tcb.retransmit_timer = 0; // v53.10: Reset for TIME_WAIT 2MSL
                    tcb.state = .time_wait;
                    _ = sendSegment(tcb, ACK, undefined, 0);
                    tcpLog("[tcp] FIN+ACK in FIN_WAIT_1 → TIME_WAIT\n");
                } else {
                    // Simultaneous close, our FIN not yet ACKed → CLOSING
                    tcb.state = .closing;
                    _ = sendSegment(tcb, ACK, undefined, 0);
                    tcpLog("[tcp] FIN (no ACK) in FIN_WAIT_1 → CLOSING\n");
                }
            } else if (flags & ACK != 0) {
                tcb.snd_una = ack_num;
                tcb.retransmit_timer = 0; // v53.10: Reset for FIN_WAIT_2 timeout
                tcb.state = .fin_wait_2;
                tcpLog("[tcp] ACK in FIN_WAIT_1 → FIN_WAIT_2\n");
            }
        },
        .fin_wait_2 => {
            if (payload_len > 0) {
                processIncomingData(tcb, data + payload_offset, payload_len, seq_num);
                pending_events.* |= epoll.EPOLLIN;
                pending_idx.* = tcbIdx(tcb);
            }
            if (flags & FIN != 0) {
                tcb.rcv_nxt +%= 1;
                tcb.retransmit_timer = 0; // v53.10: Reset for TIME_WAIT 2MSL
                tcb.state = .time_wait;
                _ = sendSegment(tcb, ACK, undefined, 0);
                tcpLog("[tcp] FIN received → TIME_WAIT\n");
            }
        },
        .last_ack => {
            if (flags & ACK != 0) {
                tcb.state = .closed;
                deactivateTcb(tcb);
                tcpLog("[tcp] LAST_ACK → CLOSED\n");
            }
        },
        .close_wait => {
            if (payload_len > 0) {
                processIncomingData(tcb, data + payload_offset, payload_len, seq_num);
                pending_events.* |= epoll.EPOLLIN;
                pending_idx.* = tcbIdx(tcb);
            }
        },
        .closing => {
            // v53.11: Only transition to TIME_WAIT when our FIN is actually ACKed (ack_num >= snd_nxt)
            if (flags & ACK != 0 and ack_num >= tcb.snd_nxt) {
                tcb.retransmit_timer = 0; // v53.10: Reset for TIME_WAIT 2MSL
                tcb.state = .time_wait;
                tcpLog("[tcp] CLOSING → TIME_WAIT\n");
            }
        },
        .time_wait => {
            // Retransmitted FIN — re-ACK and reset 2MSL timer per RFC 793
            if (flags & FIN != 0) {
                tcb.retransmit_timer = 0; // v53.6: Restart 2MSL timer
                _ = sendSegment(tcb, ACK, undefined, 0);
            }
        },
        else => {
            // Ignore packets in other states
        },
    }

}

pub fn handlePacket(src_ip: [4]u8, dst_ip: [4]u8, data: [*]const u8, len: u32) void {
    _ = dst_ip;
    if (len < 20) return;

    // v53.41: Collect epoll events — notify after releasing tcp_lock to avoid blocking all TCP connections
    const epoll = @import("epoll.zig");
    var pending_events: u32 = 0;
    var pending_idx: u32 = 0;
    defer {
        if (pending_events != 0) {
            epoll.epollNotify(.tcp_socket, pending_idx, pending_events);
        }
    }

    // v53.13: Acquire TCP lock for the entire packet processing
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);

    // Parse TCP header
    const src_port = bo.readU16BeAt(data, 0);
    const dst_port = bo.readU16BeAt(data, 2);
    const seq_num = bo.readU32BeAt(data, 4);
    const ack_num = bo.readU32BeAt(data, 8);
    const data_offset = (@as(u16, data[12]) >> 4) * 4;
    const flags = data[13];
    const raw_window = bo.readU16BeAt(data, 14);

    if (data_offset < 20 or data_offset > len) return;

    // Parse TCP options
    const opts = parseTcpOptions(data, data_offset);

    const payload_offset = data_offset;
    const payload_len: u32 = if (len > data_offset) len - data_offset else 0;

    // Find matching TCB
    const tcb = findTcbByTuple(dst_port, src_port, src_ip) orelse {
        // No matching connection — check if any socket is listening on this port
        if (flags & SYN != 0) {
            handleIncomingSyn(src_ip, src_port, dst_port, seq_num, raw_window, opts);
        }
        // Otherwise send RST (or just ignore)
        return;
    };

    driveTcbStateMachine(tcb, seq_num, ack_num, flags, raw_window, opts, data, @intCast(payload_offset), payload_len, &pending_events, &pending_idx);
}


fn processIncomingData(tcb: *TcpTcb, data: [*]const u8, len: u32, seq: u32) void {
    // Check if this is the expected sequence
    if (seq != tcb.rcv_nxt) {
        // Out-of-order segment — record SACK block if SACK is negotiated
        if (tcb.sack_permitted and len > 0) {
            // Add/update SACK block for this out-of-order segment
            addSackBlock(tcb, seq, seq + len);
        }
        // Send ACK with expected seq (and SACK blocks if available)
        _ = sendSegment(tcb, ACK, undefined, 0);
        return;
    }

    // Copy to receive ring buffer (batched @memcpy)
    const recv_free = RECV_BUF_SIZE - 1 - ringDataLen(tcb.recv_head, tcb.recv_tail, RECV_BUF_SIZE);
    const to_copy = @min(len, recv_free);
    ringWrite(&tcb.recv_buf, RECV_BUF_SIZE, tcb.recv_tail, data, to_copy);
    tcb.recv_tail = (tcb.recv_tail + to_copy) % RECV_BUF_SIZE;

    // v53.3: only advance rcv_nxt by actually buffered bytes
    // (if recv_buf is full, to_copy < len, so we don't skip unbuffered seq nums)
    tcb.rcv_nxt +%= to_copy;
    tcb.rcv_wnd = TCP_WINDOW - ringDataLen(tcb.recv_head, tcb.recv_tail, RECV_BUF_SIZE);

    // Delayed ACK: every-other-segment rule (disabled by TCP_QUICKACK)
    if (tcb.options.tcp_quickack) {
        // TCP_QUICKACK: always ACK immediately
        tcb.delayed_ack_pending = false;
        tcb.delayed_ack_ms = 0;
        _ = sendSegment(tcb, ACK, undefined, 0);
    } else if (tcb.delayed_ack_pending) {
        // Second segment arrived while ACK pending — send immediately
        tcb.delayed_ack_pending = false;
        tcb.delayed_ack_ms = 0;
        _ = sendSegment(tcb, ACK, undefined, 0);
    } else {
        // First segment — hold ACK for DELAYED_ACK_MS
        tcb.delayed_ack_pending = true;
        tcb.delayed_ack_ms = 0;
    }
}

// ─── Public API (called from syscalls) ────────────────────────────────────

/// Create a new TCP connection (client connect).
/// Returns tcb index (0-based) or -1 on error.
pub fn tcpConnect(remote_ip: [4]u8, remote_port: u16, owner_task: u32) i64 {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    const tcb = allocTcb() orelse return -1;

    tcb.local_port = allocEphemeralPort();
    tcb.remote_port = remote_port;
    tcb.remote_ip = remote_ip;
    tcb.owner_task = owner_task;
    tcb.iss = generateIss();
    tcb.snd_una = tcb.iss;
    tcb.snd_nxt = tcb.iss;
    tcb.snd_wnd = TCP_WINDOW;
    tcb.rcv_nxt = 0;
    tcb.rcv_wnd = TCP_WINDOW;
    tcb.state = .syn_sent;

    // Send SYN
    if (!sendSegment(tcb, SYN, undefined, 0)) {
        deactivateTcb(tcb);
        return -1;
    }

    tcpLog("[tcp] SYN sent\n");

    // Return the index
    return @intCast(tcbIdx(tcb));
}

// Connect an existing socket TCB to a remote address.
// Returns 0 on success (SYN sent), -1 on failure.
pub fn tcpConnectSocket(tcb_idx: u32, remote_ip: [4]u8, remote_port: u16) i64 {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    if (tcb_idx >= MAX_CONNECTIONS) return -1;
    const tcb = &tcbs[tcb_idx];
    if (!tcb.active or tcb.state != .closed or tcb.is_v6) return -1;

    if (tcb.local_port == 0) {
        tcb.local_port = allocEphemeralPort();
        if (tcb.local_port == 0) return -1;
    }

    tcb.remote_port = remote_port;
    tcb.remote_ip = remote_ip;
    tcb.iss = generateIss();
    tcb.snd_una = tcb.iss;
    tcb.snd_nxt = tcb.iss;
    tcb.snd_wnd = TCP_WINDOW;
    tcb.rcv_nxt = 0;
    tcb.rcv_wnd = TCP_WINDOW;
    tcb.state = .syn_sent;

    if (!sendSegment(tcb, SYN, undefined, 0)) {
        tcb.state = .closed;
        return -1;
    }

    tcpLog("[tcp] connect: SYN sent\n");
    return 0;
}

/// Connect an IPv6 TCP socket (SK-78). Requires `tcpSetIpv6` first.
pub fn tcpConnectSocketV6(tcb_idx: u32, remote_ip6: [16]u8, remote_port: u16) i64 {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    if (tcb_idx >= MAX_CONNECTIONS) return -1;
    const tcb = &tcbs[tcb_idx];
    if (!tcb.active or tcb.state != .closed or !tcb.is_v6) return -1;

    if (tcb.local_port == 0) {
        tcb.local_port = allocEphemeralPort();
        if (tcb.local_port == 0) return -1;
    }

    tcb.remote_port = remote_port;
    tcb.remote_ip6 = remote_ip6;
    tcb.iss = generateIss();
    tcb.snd_una = tcb.iss;
    tcb.snd_nxt = tcb.iss;
    tcb.snd_wnd = TCP_WINDOW;
    tcb.rcv_nxt = 0;
    tcb.rcv_wnd = TCP_WINDOW;
    tcb.state = .syn_sent;

    if (!sendSegment(tcb, SYN, undefined, 0)) {
        tcb.state = .closed;
        return -1;
    }

    tcpLog("[tcp] connect v6: SYN sent\n");
    return 0;
}

/// Poll for connection state. Returns:
///  0 = still connecting
///  1 = established
/// -1 = error / closed
pub fn tcpPoll(tcb_idx: u32) i64 {
    // v53.46: Lock-free read — status query, stale values acceptable on x86_64.
    if (tcb_idx >= MAX_CONNECTIONS) return -1;
    const tcb = &tcbs[tcb_idx];
    if (!tcb.active) return -1;
    return switch (tcb.state) {
        .established => 1,
        .closed => -1,
        else => 0,
    };
}

/// Send data on an established connection.
/// Returns number of bytes queued, or -1 on error.
pub fn tcpSend(tcb_idx: u32, data: [*]const u8, len: u32) i64 {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    if (tcb_idx >= MAX_CONNECTIONS) return -1;
    const tcb = &tcbs[tcb_idx];
    if (!tcb.active or tcb.state != .established) return -1;

    // Copy data to send ring buffer (batched @memcpy)
    const used = ringDataLen(tcb.send_head, tcb.send_tail, SEND_BUF_SIZE);
    const free_space = SEND_BUF_SIZE - 1 - used;
    const to_copy = @min(len, free_space);
    ringWrite(&tcb.send_buf, SEND_BUF_SIZE, tcb.send_tail, data, to_copy);
    tcb.send_tail = (tcb.send_tail + to_copy) % SEND_BUF_SIZE;
    const queued: u32 = to_copy;

    // Send as much as we can from the buffer
    flushSendBuffer(tcb);

    return queued;
}

/// Flush pending send data as TCP segments.
/// Uses min(cwnd, snd_wnd) as the effective send window.
/// When TCP_CORK is set, only full MSS segments are sent (partial segments are held).
fn flushSendBuffer(tcb: *TcpTcb) void {
    while (true) {
        // SK-108: skip SACKed ranges so selective retransmit does not resend them.
        skipSackedSendRange(tcb);
        const mss = mssForTcb(tcb);
        const pending = ringDataLen(tcb.send_unacked, tcb.send_tail, SEND_BUF_SIZE);
        // SK-111: RFC 6675 pipe excludes SACKed bytes still above snd_una.
        const in_flight = pipeBytes(tcb);
        const effective_wnd = @min(tcb.cwnd, tcb.snd_wnd);
        const window_avail = if (effective_wnd > in_flight) effective_wnd - in_flight else 0;
        const can_send = @min(pending, window_avail, mss);

        if (can_send == 0) break;

        // TCP_CORK: only send full MSS segments (coalesce small writes)
        if (tcb.options.tcp_cork and can_send < mss) break;

        // Nagle algorithm: if TCP_NODELAY is disabled and there is unacknowledged
        // data in flight, only send a full MSS segment (coalesce small writes).
        if (!tcb.options.tcp_nodelay and !tcb.options.tcp_cork and in_flight > 0 and can_send < mss) {
            tcb.nagle_pending = true;
            break;
        }

        // Collect data from ring buffer (batched @memcpy)
        var seg_buf: [TCP_MSS]u8 = undefined;
        ringRead(&tcb.send_buf, SEND_BUF_SIZE, tcb.send_unacked, &seg_buf, can_send);
        tcb.send_unacked = (tcb.send_unacked + can_send) % SEND_BUF_SIZE;
        _ = sendSegment(tcb, ACK | PSH, &seg_buf, @intCast(can_send));
        if (tcb.in_recovery) tcb.prr_out +%= can_send;
        // ACK piggybacked on data — clear any pending delayed ACK
        tcb.delayed_ack_pending = false;
        tcb.delayed_ack_ms = 0;
    }
}

/// Receive data from an established connection.
/// Returns number of bytes read, 0 if none available, -1 on error/closed.
pub fn tcpRecv(tcb_idx: u32, buf: [*]u8, len: u32) i64 {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    if (tcb_idx >= MAX_CONNECTIONS) return -1;
    const tcb = &tcbs[tcb_idx];
    if (!tcb.active) return -1;
    if (tcb.state == .closed) return -1;

    const available = ringDataLen(tcb.recv_head, tcb.recv_tail, RECV_BUF_SIZE);
    if (available == 0) {
        if (tcb.state == .close_wait) return -1; // connection closed by remote
        return 0;
    }

    const to_read = @min(available, len);
    ringRead(&tcb.recv_buf, RECV_BUF_SIZE, tcb.recv_head, buf, to_read);
    tcb.recv_head = (tcb.recv_head + to_read) % RECV_BUF_SIZE;

    tcb.rcv_wnd = TCP_WINDOW - ringDataLen(tcb.recv_head, tcb.recv_tail, RECV_BUF_SIZE);

    // Flush delayed ACK when app reads data (advertises updated window promptly).
    // Also sends a window update if a significant amount was consumed.
    if (tcb.delayed_ack_pending or (to_read > mssForTcb(tcb) and tcb.state == .established)) {
        tcb.delayed_ack_pending = false;
        tcb.delayed_ack_ms = 0;
        _ = sendSegment(tcb, ACK, undefined, 0);
    }

    return @intCast(to_read);
}

/// Flush corked data — called when TCP_CORK is disabled (uncorked).
/// Sends any pending partial segment immediately.
pub fn tcpFlushCork(tcb_idx: u32) void {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    if (tcb_idx >= MAX_CONNECTIONS) return;
    const tcb = &tcbs[tcb_idx];
    if (!tcb.active or tcb.state != .established) return;
    flushSendBuffer(tcb);
}

/// Flush pending delayed ACK — called when TCP_QUICKACK is enabled.
pub fn tcpFlushAck(tcb_idx: u32) void {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    if (tcb_idx >= MAX_CONNECTIONS) return;
    const tcb = &tcbs[tcb_idx];
    if (!tcb.active) return;
    if (tcb.delayed_ack_pending) {
        tcb.delayed_ack_pending = false;
        tcb.delayed_ack_ms = 0;
        _ = sendSegment(tcb, ACK, undefined, 0);
    }
}

/// Close a TCP connection (initiates four-way close).
/// When SO_LINGER is set with l_onoff=1 and l_linger=0, sends RST (abortive close).
pub fn tcpClose(tcb_idx: u32) i64 {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    if (tcb_idx >= MAX_CONNECTIONS) return -1;
    const tcb = &tcbs[tcb_idx];
    if (!tcb.active) return -1;

    // Shared across fork/clone: drop one reference, tear down only at zero.
    if (tcb.ref_count > 1) {
        tcb.ref_count -= 1;
        return 0;
    }
    tcb.ref_count = 0;

    // SO_LINGER with linger=0: abortive close — send RST, discard unsent data
    if (tcb.options.linger_on and tcb.options.linger_sec == 0) {
        _ = sendSegment(tcb, RST | ACK, undefined, 0);
        tcpLog("[tcp] SO_LINGER(0) → RST sent, abortive close\n");
        tcb.state = .closed;
        deactivateTcb(tcb);
        return 0;
    }

    switch (tcb.state) {
        .established => {
            tcb.state = .fin_wait_1;
            _ = sendSegment(tcb, FIN | ACK, undefined, 0);
            tcpLog("[tcp] FIN sent → FIN_WAIT_1\n");
        },
        .close_wait => {
            tcb.state = .last_ack;
            _ = sendSegment(tcb, FIN | ACK, undefined, 0);
            tcpLog("[tcp] FIN sent → LAST_ACK\n");
        },
        else => {
            tcb.state = .closed;
            deactivateTcb(tcb);
        },
    }
    return 0;
}

/// Get TCP connection state as integer.
pub fn tcpState(tcb_idx: u32) u8 {
    // v53.46: Lock-free read — status query.
    if (tcb_idx >= MAX_CONNECTIONS) return 0;
    if (!tcbs[tcb_idx].active) return 0;
    return @intFromEnum(tcbs[tcb_idx].state);
}

/// Check if connection is established.
pub fn isEstablished(tcb_idx: u32) bool {
    // v53.46: Lock-free read — status query.
    if (tcb_idx >= MAX_CONNECTIONS) return false;
    return tcbs[tcb_idx].active and tcbs[tcb_idx].state == .established;
}

/// Check if connection is fully closed.
pub fn isClosed(tcb_idx: u32) bool {
    // v53.46: Lock-free read — status query.
    if (tcb_idx >= MAX_CONNECTIONS) return true;
    return !tcbs[tcb_idx].active or tcbs[tcb_idx].state == .closed;
}

/// Timer tick — called periodically to handle retransmission.
/// Uses the per-TCB RTO (Jacobson/Karels) instead of a fixed timeout.
/// v53.49: Single tcp_lock acquisition for the entire active-TCB sweep.
/// Lock order tcp_lock -> e1000.tx_lock is maintained inside timerTickOne
/// via sendSegment, so batch processing does not violate lock ordering.
/// Worst-case hold time for 64 TCBs with retransmits: ~64-320us, well
/// within the 10ms tick budget.
pub fn timerTick(ms_elapsed: u32) void {
    var bm = @atomicLoad(u64, &tcb_active_bitmap, .acquire);
    if (bm == 0) return;
    const lock_flags = tcp_lock.acquire();
    while (bm != 0) {
        const idx = @ctz(bm);
        bm &= bm - 1;
        timerTickOne(idx, ms_elapsed);
    }
    tcp_lock.release(lock_flags);
}

/// Process timer events for a single TCB. Must be called with tcp_lock held.
fn timerTickOne(idx: u32, ms_elapsed: u32) void {
    const tcb = &tcbs[idx];
    if (tcb.state == .closed) return;

    // v53.6: FIN_WAIT_2 timeout — prevent orphaned TCBs if peer crashes without FIN
    if (tcb.state == .fin_wait_2) {
        tcb.retransmit_timer +%= ms_elapsed;
        if (tcb.retransmit_timer >= 60_000) { // 60s timeout (Linux tcp_fin_timeout default)
            tcb.state = .closed;
            deactivateTcb(tcb);
            tcpLog("[tcp] FIN_WAIT_2 timeout → CLOSED\n");
            return;
        }
        // v53.11: Handle delayed ACK for half-close data (peer can still send in FIN_WAIT_2)
        if (tcb.delayed_ack_pending) {
            tcb.delayed_ack_ms +%= ms_elapsed;
            if (tcb.delayed_ack_ms >= DELAYED_ACK_MS) {
                tcb.delayed_ack_pending = false;
                tcb.delayed_ack_ms = 0;
                _ = sendSegment(tcb, ACK, undefined, 0);
            }
        }
        return; // v53.10: Don't fall through to retransmit logic
    }

    // TIME_WAIT: clean up after 15 seconds (reduced from 2*MSL=60s)
    if (tcb.state == .time_wait) {
        tcb.retransmit_timer +%= ms_elapsed;
        if (tcb.retransmit_timer >= 15000) {
            tcb.state = .closed;
            deactivateTcb(tcb);
            tcpLog("[tcp] TIME_WAIT → CLOSED (timeout)\n");
        }
        return;
    }

    // Check for unacknowledged data
    if (tcb.snd_nxt != tcb.snd_una) {
        tcb.retransmit_timer +%= ms_elapsed;
        // Use per-TCB RTO if available, otherwise fall back to RETRANSMIT_MS
        const current_rto = if (tcb.rto > 0) tcb.rto else RETRANSMIT_MS;
        if (tcb.retransmit_timer >= current_rto) {
            tcb.retransmit_timer = 0;
            tcb.retransmit_count += 1;
            if (tcb.retransmit_count > 5) {
                // Give up
                tcpLog("[tcp] retransmit timeout, closing\n");
                tcb.state = .closed;
                deactivateTcb(tcb);
                return;
            }
            // RTO timeout: Reno behavior — ssthresh = cwnd/2, cwnd = 1 SMSS (SK-99).
            const smss_rto: u32 = mssForTcb(tcb);
            tcb.ssthresh = @max(tcb.cwnd / 2, 2 * smss_rto);
            tcb.cwnd = smss_rto; // back to slow start
            tcb.in_recovery = false;
            tcb.dup_ack_count = 0;
            tcb.recover_fs = 0;
            tcb.prr_delivered = 0;
            tcb.prr_out = 0;

            // Exponential backoff for RTO
            tcb.rto = @min(tcb.rto * 2, TCP_RTO_MAX);

            // SK-108: RTO also starts at the first non-SACKed hole when possible.
            const unacked = ringDataLen(tcb.send_head, tcb.send_tail, SEND_BUF_SIZE);
            if (unacked > 0) {
                prepareRexmitFromHole(tcb);
                flushSendBuffer(tcb);
                // v53.13: If all pending data has been retransmitted, also retransmit FIN
                if (tcb.send_unacked == tcb.send_tail) {
                    if (tcb.state == .fin_wait_1 or tcb.state == .last_ack or tcb.state == .closing) {
                        _ = sendSegment(tcb, FIN | ACK, undefined, 0);
                    }
                }
            } else if (tcb.state == .syn_sent) {
                // Retransmit SYN
                _ = sendSegment(tcb, SYN, undefined, 0);
            } else if (tcb.state == .fin_wait_1 or tcb.state == .last_ack or tcb.state == .closing) {
                // v53.12: Include .closing — FIN must be retransmitted if ACK is lost
                _ = sendSegment(tcb, FIN | ACK, undefined, 0);
            }
            tcpLog("[tcp] RTO retransmit\n");
        }
    }

    // ── Delayed ACK timeout ──────────────────────────────────────
    // If ACK has been held for > DELAYED_ACK_MS, send it now.
    if (tcb.delayed_ack_pending) {
        tcb.delayed_ack_ms +%= ms_elapsed;
        if (tcb.delayed_ack_ms >= DELAYED_ACK_MS) {
            tcb.delayed_ack_pending = false;
            tcb.delayed_ack_ms = 0;
            _ = sendSegment(tcb, ACK, undefined, 0);
        }
    }

    // ── Zero-window persist (SK-110) ─────────────────────────────────
    // When the peer advertises snd_wnd=0 but we still have unsent data,
    // periodically probe with 1 byte so a lost window update cannot stall forever.
    if (tcb.state == .established) {
        const unsent = ringDataLen(tcb.send_unacked, tcb.send_tail, SEND_BUF_SIZE);
        if (probePersistActive(tcb.snd_wnd, unsent)) {
            tcb.persist_timer_ms +%= ms_elapsed;
            const interval = if (tcb.persist_rto_ms > 0) tcb.persist_rto_ms else RETRANSMIT_MS;
            if (tcb.persist_timer_ms >= interval) {
                tcb.persist_timer_ms = 0;
                tcb.persist_rto_ms = if (interval > TCP_RTO_MAX / 2) TCP_RTO_MAX else interval * 2;
                _ = sendPersistProbe(tcb);
            }
        } else {
            tcb.persist_timer_ms = 0;
            tcb.persist_rto_ms = RETRANSMIT_MS;
        }
    }

    // ── Keepalive logic ──────────────────────────────────────────────
    // Only for established connections with SO_KEEPALIVE enabled
    if (tcb.state == .established and tcb.options.keep_alive) {
        tcb.idle_ms +%= ms_elapsed;
        const keep_idle_ms = tcb.options.keep_idle * 1000;
        const keep_intvl_ms = tcb.options.keep_intvl * 1000;

        if (tcb.idle_ms >= keep_idle_ms and tcb.keepalive_probes == 0) {
            // First keepalive probe (SK-109: SEQ = SND.UNA-1).
            tcb.keepalive_probes = 1;
            _ = sendKeepaliveProbe(tcb);
        } else if (tcb.keepalive_probes > 0 and tcb.idle_ms >= keep_idle_ms + tcb.keepalive_probes * keep_intvl_ms) {
            if (tcb.keepalive_probes >= tcb.options.keep_cnt) {
                // Max probes reached — connection is dead
                tcpLog("[tcp] keepalive timeout, closing\n");
                tcb.state = .closed;
                deactivateTcb(tcb);
                return;
            }
            tcb.keepalive_probes += 1;
            _ = sendKeepaliveProbe(tcb);
        }
    }

    // ── Nagle delayed data flush ──────────────────────────────────────
    // If Nagle held data (nagle_pending), and all in-flight data is now ACKed,
    // flush the pending data.
    if (tcb.nagle_pending and tcb.snd_nxt == tcb.snd_una) {
        tcb.nagle_pending = false;
        flushSendBuffer(tcb);
    }
}

// ─── Listening / Server Socket Support ──────────────────────────────────────

const LISTEN_BACKLOG: u32 = 32;

const ListenSlot = struct {
    active: bool = false,
    local_port: u16 = 0,
    owner_task: u32 = 0,
    is_v6: bool = false,
    pending_tpbs: [LISTEN_BACKLOG]u32, // TCB indices of pending connections (SYN_RECEIVED)
    // v53.50: Ring buffer indices — O(1) enqueue/dequeue instead of O(N) array shift
    pending_head: u32 = 0,
    pending_tail: u32 = 0,
};

var listen_slots: [MAX_CONNECTIONS]ListenSlot = @splat(.{
    .active = false,
    .local_port = 0,
    .owner_task = 0,
    .is_v6 = false,
    .pending_tpbs = @splat(0),
    .pending_head = 0,
    .pending_tail = 0,
});

/// Bitmap tracking active listen slots (1 = active).
var listen_active_bitmap: u64 = 0;

/// Create a TCP socket (allocate a TCB in closed state).
/// Returns TCB index (>= 0) on success, -1 on failure.
pub fn tcpSocket(owner_task: u32) i64 {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    const tcb = allocTcb() orelse return -1;
    tcb.owner_task = owner_task;
    tcb.state = .closed;

    return @intCast(tcbIdx(tcb));
}

/// Mark a closed TCB as IPv6 (SK-75). Call after `tcpSocket` for AF_INET6.
pub fn tcpSetIpv6(tcb_idx: u32) i64 {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    if (tcb_idx >= MAX_CONNECTIONS) return -1;
    const tcb = &tcbs[tcb_idx];
    if (!tcb.active or tcb.state != .closed) return -1;
    tcb.is_v6 = true;
    return 0;
}

/// Bind a TCB to a local port.
/// Returns 0 on success, -1 on failure.
pub fn tcpBind(tcb_idx: u32, port: u16) i64 {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    if (tcb_idx >= MAX_CONNECTIONS) return -1;
    const tcb = &tcbs[tcb_idx];
    if (!tcb.active or tcb.state != .closed) return -1;

    // Check if port is already in use (bitmap-driven scan)
    // SO_REUSEADDR allows binding to a port in TIME_WAIT state
    var bm = @atomicLoad(u64, &tcb_active_bitmap, .acquire);
    while (bm != 0) {
        const i = @ctz(bm);
        bm &= bm - 1;
        if (tcbs[i].local_port == port) {
            if (tcb.options.reuse_addr and tcbs[i].state == .time_wait) {
                continue;
            }
            return -1;
        }
    }

    tcb.local_port = port;
    return 0;
}

/// Start listening for connections on a bound TCB.
/// Returns 0 on success, -1 on failure.
pub fn tcpListen(tcb_idx: u32) i64 {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    if (tcb_idx >= MAX_CONNECTIONS) return -1;
    const tcb = &tcbs[tcb_idx];
    if (!tcb.active or tcb.local_port == 0) return -1;

    tcb.state = .listen;

    // Set up listen slot for incoming SYN tracking (bitmap-driven free slot search)
    const all_listen_mask: u64 = if (MAX_CONNECTIONS >= 64) 0xFFFFFFFFFFFFFFFF else (@as(u64, 1) << MAX_CONNECTIONS) - 1;
    const free_mask = ~listen_active_bitmap & all_listen_mask;
    if (free_mask == 0) return -1;
    const i: u6 = @intCast(@ctz(free_mask));
    listen_active_bitmap |= @as(u64, 1) << i;
    listen_slots[i].active = true;
    listen_slots[i].local_port = tcb.local_port;
    listen_slots[i].owner_task = tcb.owner_task;
    listen_slots[i].is_v6 = tcb.is_v6;
    listen_slots[i].pending_head = 0;
    listen_slots[i].pending_tail = 0;
    listen_slots[i].pending_tpbs = @splat(0);
    return 0;
}

/// Probe helper (SK-75): seed an established IPv6 TCB for demux tests.
pub fn tcpProbeSeedV6(local_port: u16, remote_port: u16, remote_ip6: [16]u8) i64 {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    const tcb = allocTcb() orelse return -1;
    tcb.is_v6 = true;
    tcb.local_port = local_port;
    tcb.remote_port = remote_port;
    tcb.remote_ip6 = remote_ip6;
    tcb.state = .established;
    tcb.idle_ms = 999;
    return @intCast(tcbIdx(tcb));
}

/// Probe helper: true when an IPv6 TCB matches the tuple.
pub fn tcpProbeHasV6(local_port: u16, remote_port: u16, remote_ip6: [16]u8) bool {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    return findTcbByTupleV6(local_port, remote_port, remote_ip6) != null;
}

/// Probe helper: idle_ms of a seeded TCB (or maxInt if missing).
pub fn tcpProbeIdleV6(tcb_idx: u32) u32 {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    if (tcb_idx >= MAX_CONNECTIONS or !tcbs[tcb_idx].active) return 0xFFFF_FFFF;
    return tcbs[tcb_idx].idle_ms;
}

/// Probe helper (SK-76): true when SYN-ACK advanced snd_nxt past iss.
pub fn tcpProbeSynAckAdvancedV6(local_port: u16, remote_port: u16, remote_ip6: [16]u8) bool {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    const tcb = findTcbByTupleV6(local_port, remote_port, remote_ip6) orelse return false;
    return tcb.state == .syn_received and tcb.snd_nxt == tcb.iss +% 1;
}

/// Probe helper (SK-76): IPv6 tuple is in established state.
pub fn tcpProbeIsEstablishedV6(local_port: u16, remote_port: u16, remote_ip6: [16]u8) bool {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    const tcb = findTcbByTupleV6(local_port, remote_port, remote_ip6) orelse return false;
    return tcb.state == .established;
}

/// Probe helper: TCB index for an IPv6 tuple, or -1.
pub fn tcpProbeConnIdxV6(local_port: u16, remote_port: u16, remote_ip6: [16]u8) i64 {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    const tcb = findTcbByTupleV6(local_port, remote_port, remote_ip6) orelse return -1;
    return @intCast(tcbIdx(tcb));
}

/// Accept a pending connection on a listening socket.
/// Returns new TCB index (>= 0) for the accepted connection, -1 if none pending.
pub fn tcpAccept(tcb_idx: u32, owner_task: u32) i64 {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    if (tcb_idx >= MAX_CONNECTIONS) return -1;
    const tcb = &tcbs[tcb_idx];
    if (!tcb.active or tcb.state != .listen) return -1;

    // Find the listen slot for this TCB (bitmap-driven)
    var slot: ?*ListenSlot = null;
    var lbm = listen_active_bitmap;
    while (lbm != 0) {
        const i = @ctz(lbm);
        lbm &= lbm - 1;
        if (listen_slots[i].local_port == tcb.local_port) {
            slot = &listen_slots[i];
            break;
        }
    }
    const ls = slot orelse return -1;

    if (ls.pending_head == ls.pending_tail) return 0; // No pending connections

    // v53.50: O(1) ring buffer dequeue — no array shift needed
    const pending_idx = ls.pending_tpbs[ls.pending_head % LISTEN_BACKLOG];
    ls.pending_head += 1;

    if (pending_idx >= MAX_CONNECTIONS) return -1;
    const new_tcb = &tcbs[pending_idx];
    if (!new_tcb.active or new_tcb.state != .established) return -1;

    // Transfer ownership to the accepting task
    new_tcb.owner_task = owner_task;

    return @intCast(pending_idx);
}

/// Get the TCB index for a socket fd.
pub fn getTcbIdx(tcb_idx: u32) ?u32 {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    if (tcb_idx >= MAX_CONNECTIONS) return null;
    if (!tcbs[tcb_idx].active) return null;
    return tcb_idx;
}

/// Return the number of bytes available to read in the receive buffer.
pub fn tcpRecvAvailable(tcb_idx: u32) u32 {
    // v53.46: Lock-free read — may return slightly stale count, acceptable for epoll/poll.
    if (tcb_idx >= MAX_CONNECTIONS) return 0;
    const tcb = &tcbs[tcb_idx];
    if (!tcb.active) return 0;
    return ringDataLen(tcb.recv_head, tcb.recv_tail, RECV_BUF_SIZE);
}

/// Return the number of bytes of free space in the send buffer.
pub fn tcpSendSpace(tcb_idx: u32) u32 {
    // v53.46: Lock-free read — may return slightly stale count, acceptable for epoll/poll.
    if (tcb_idx >= MAX_CONNECTIONS) return 0;
    const tcb = &tcbs[tcb_idx];
    if (!tcb.active) return 0;
    return ringAvailable(tcb.send_head, tcb.send_tail, SEND_BUF_SIZE);
}

/// Check if the TCP connection is in a closing state.
pub fn tcpIsClosing(tcb_idx: u32) bool {
    // v53.46: Lock-free read — status query.
    if (tcb_idx >= MAX_CONNECTIONS) return true;
    const tcb = &tcbs[tcb_idx];
    if (!tcb.active) return true;
    return switch (tcb.state) {
        .fin_wait_1, .fin_wait_2, .closing, .time_wait, .close_wait, .last_ack, .closed => true,
        else => false,
    };
}

/// Socket address info returned by tcpGetAddrInfo.
pub const AddrInfo = struct {
    local_port: u16,
    remote_port: u16,
    remote_ip: [4]u8,
    local_ip: [4]u8,
    /// SK-78: dual-stack name queries.
    is_v6: bool = false,
    remote_ip6: [16]u8 = @splat(0),
    local_ip6: [16]u8 = @splat(0),
};

/// Get address info for a TCB (for getsockname/getpeername).
pub fn tcpGetAddrInfo(tcb_idx: u32) ?AddrInfo {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    if (tcb_idx >= MAX_CONNECTIONS) return null;
    const tcb = &tcbs[tcb_idx];
    if (!tcb.active) return null;
    const netif_mod = @import("netif.zig");
    const ndp_mod = @import("ndp.zig");
    return .{
        .local_port = tcb.local_port,
        .remote_port = tcb.remote_port,
        .remote_ip = tcb.remote_ip,
        .local_ip = netif_mod.getOurIp(),
        .is_v6 = tcb.is_v6,
        .remote_ip6 = tcb.remote_ip6,
        .local_ip6 = if (tcb.is_v6)
            ndp_mod.selectSourceAddress(tcb.remote_ip6, netif_mod.getMac())
        else
            ndp_mod.generateLinkLocal(netif_mod.getMac()),
    };
}

/// Probe helper (SK-78): IPv6 tuple is in syn_sent.
pub fn tcpProbeIsSynSentV6(local_port: u16, remote_port: u16, remote_ip6: [16]u8) bool {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    const tcb = findTcbByTupleV6(local_port, remote_port, remote_ip6) orelse return false;
    return tcb.state == .syn_sent;
}

/// Shutdown one direction of a TCP connection.
/// how: 0=SHUT_RD, 1=SHUT_WR, 2=SHUT_RDWR
pub fn tcpShutdown(tcb_idx: u32, how: u32) i64 {
    const lock_flags = tcp_lock.acquire();
    defer tcp_lock.release(lock_flags);
    if (tcb_idx >= MAX_CONNECTIONS) return -1;
    const tcb = &tcbs[tcb_idx];
    if (!tcb.active) return -1;

    switch (how) {
        0 => {
            // SHUT_RD: discard further received data
            // Just advance rcv_nxt to effectively ignore future data
            tcb.recv_head = tcb.recv_tail; // drain recv buffer
        },
        1 => {
            // SHUT_WR: send FIN
            switch (tcb.state) {
                .established => {
                    tcb.state = .fin_wait_1;
                    _ = sendSegment(tcb, FIN | ACK, undefined, 0);
                    tcpLog("[tcp] shutdown FIN → FIN_WAIT_1\n");
                },
                .close_wait => {
                    tcb.state = .last_ack;
                    _ = sendSegment(tcb, FIN | ACK, undefined, 0);
                    tcpLog("[tcp] shutdown FIN → LAST_ACK\n");
                },
                else => {},
            }
        },
        2 => {
            // SHUT_RDWR: shutdown both directions
            tcb.recv_head = tcb.recv_tail;
            switch (tcb.state) {
                .established => {
                    tcb.state = .fin_wait_1;
                    _ = sendSegment(tcb, FIN | ACK, undefined, 0);
                    tcpLog("[tcp] shutdown RDWR FIN → FIN_WAIT_1\n");
                },
                .close_wait => {
                    tcb.state = .last_ack;
                    _ = sendSegment(tcb, FIN | ACK, undefined, 0);
                    tcpLog("[tcp] shutdown RDWR FIN → LAST_ACK\n");
                },
                else => {
                    tcb.state = .closed;
                    deactivateTcb(tcb);
                },
            }
        },
        else => return -1,
    }
    return 0;
}

// ─── SACK Helpers ───────────────────────────────────────────────────────────

/// Add or merge a SACK block on the receiver side.
fn addSackBlock(tcb: *TcpTcb, left: u32, right: u32) void {
    // Try to merge with existing blocks
    for (0..tcb.sack_block_count) |i| {
        const blk = &tcb.sack_blocks[i];
        if (blk.left == right or blk.right == left) {
            // Merge
            if (left < blk.left) blk.left = left;
            if (right > blk.right) blk.right = right;
            return;
        }
        if (left >= blk.left and right <= blk.right) return; // already covered
    }
    // Add new block
    if (tcb.sack_block_count < 4) {
        tcb.sack_blocks[tcb.sack_block_count] = .{ .left = left, .right = right };
        tcb.sack_block_count += 1;
    } else {
        // Replace the oldest (last) block
        tcb.sack_blocks[3] = .{ .left = left, .right = right };
    }
}

/// RFC 6675 UpdateScoreboard: clip by [snd_una,snd_nxt), merge overlap/adjacent,
/// keep at most 4 highest ranges (SK-113).
pub fn probeMergeScoreboard(
    una: u32,
    nxt: u32,
    old: []const SackBlock,
    neu: []const SackBlock,
    out: *[4]SackBlock,
) u3 {
    var tmp: [8]SackBlock = undefined;
    var n: usize = 0;

    const sources = [_][]const SackBlock{ old, neu };
    for (sources) |src| {
        for (src) |blk| {
            if (n >= tmp.len) break;
            var left = blk.left;
            var right = blk.right;
            if (!tcp_util.seqLt(left, right)) continue;
            // Drop / clip below cumulative ACK.
            if (tcp_util.seqLeq(right, una)) continue;
            if (tcp_util.seqLt(left, una)) left = una;
            // Drop / clip above snd_nxt.
            if (tcp_util.seqLeq(nxt, left)) continue;
            if (tcp_util.seqLt(nxt, right)) right = nxt;
            if (!tcp_util.seqLt(left, right)) continue;
            tmp[n] = .{ .left = left, .right = right };
            n += 1;
        }
    }

    // Sort by left relative to una (insertion sort; n ≤ 8).
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const key = tmp[i];
        const key_rel = key.left -% una;
        var j: usize = i;
        while (j > 0 and (tmp[j - 1].left -% una) > key_rel) : (j -= 1) {
            tmp[j] = tmp[j - 1];
        }
        tmp[j] = key;
    }

    // Merge overlapping / adjacent half-open ranges.
    var w: usize = 0;
    for (0..n) |k| {
        if (w == 0) {
            tmp[w] = tmp[k];
            w = 1;
            continue;
        }
        const prev = &tmp[w - 1];
        if (tcp_util.seqLeq(tmp[k].left, prev.right)) {
            if (tcp_util.seqLt(prev.right, tmp[k].right)) prev.right = tmp[k].right;
        } else {
            tmp[w] = tmp[k];
            w += 1;
        }
    }

    // Cap at 4: keep the highest sequence ranges.
    const start: usize = if (w > 4) w - 4 else 0;
    const count: u3 = @intCast(w - start);
    for (0..count) |k| {
        out[k] = tmp[start + k];
    }
    return count;
}

/// Merge incoming SACK option blocks into the sender scoreboard (SK-113).
fn updateScoreboard(tcb: *TcpTcb, incoming: []const SackBlock) void {
    var out: [4]SackBlock = undefined;
    const n = probeMergeScoreboard(
        tcb.snd_una,
        tcb.snd_nxt,
        tcb.sack_scoreboard[0..tcb.sack_scoreboard_count],
        incoming,
        &out,
    );
    tcb.sack_scoreboard_count = n;
    for (0..n) |i| {
        tcb.sack_scoreboard[i] = out[i];
    }
}

/// Check if a sequence number is covered by the SACK scoreboard (sender side).
fn isSacked(tcb: *const TcpTcb, seq: u32) bool {
    for (0..tcb.sack_scoreboard_count) |i| {
        const blk = &tcb.sack_scoreboard[i];
        if (tcp_util.seqInWindow(seq, blk.left, blk.right)) return true;
    }
    return false;
}

/// Bytes of `[left,right)` that overlap `[una,nxt)` (SK-111).
fn sackRangeOverlap(una: u32, nxt: u32, left: u32, right: u32) u32 {
    if (!tcp_util.seqLt(left, right)) return 0;
    if (!tcp_util.seqLt(una, nxt)) return 0;
    // Intersection start = max(una, left), end = min(nxt, right) in seq space.
    const start = if (tcp_util.seqLt(left, una)) una else left;
    const end = if (tcp_util.seqLt(right, nxt)) right else nxt;
    if (!tcp_util.seqLt(start, end)) return 0;
    return end -% start;
}

/// SACKed bytes still between snd_una and snd_nxt (SK-111).
fn sackedBytesInFlight(tcb: *const TcpTcb) u32 {
    var n: u32 = 0;
    for (0..tcb.sack_scoreboard_count) |i| {
        const blk = tcb.sack_scoreboard[i];
        n += sackRangeOverlap(tcb.snd_una, tcb.snd_nxt, blk.left, blk.right);
    }
    return n;
}

/// RFC 6675 pipe: outstanding bytes that are not SACKed (SK-111).
fn pipeBytes(tcb: *const TcpTcb) u32 {
    const flight = tcb.snd_nxt -% tcb.snd_una;
    const sacked = sackedBytesInFlight(tcb);
    if (sacked >= flight) return 0;
    return flight - sacked;
}

/// SACKed octets with sequence numbers strictly above `seq` (SK-112).
fn sackedBytesAbove(tcb: *const TcpTcb, seq: u32) u32 {
    const after = seq +% 1;
    if (!tcp_util.seqLt(after, tcb.snd_nxt)) return 0;
    var n: u32 = 0;
    for (0..tcb.sack_scoreboard_count) |i| {
        const blk = tcb.sack_scoreboard[i];
        n += sackRangeOverlap(after, tcb.snd_nxt, blk.left, blk.right);
    }
    return n;
}

/// Number of SACK blocks that begin after `seq` (SK-112).
fn sackBlocksAbove(tcb: *const TcpTcb, seq: u32) u32 {
    var n: u32 = 0;
    for (0..tcb.sack_scoreboard_count) |i| {
        const blk = tcb.sack_scoreboard[i];
        if (tcp_util.seqLt(seq, blk.left)) n += 1;
    }
    return n;
}

/// RFC 6675 IsLost(SeqNum) (SK-112).
fn isLost(tcb: *const TcpTcb, seq: u32) bool {
    const smss: u32 = mssForTcb(tcb);
    return probeIsLost(sackedBytesAbove(tcb, seq), sackBlocksAbove(tcb, seq), smss);
}

/// First sequence ≥ `snd_una` that still needs retransmission (SK-108).
fn nextRexmitSeq(tcb: *const TcpTcb) u32 {
    var seq = tcb.snd_una;
    var guard: u32 = 0;
    while (guard < 64 and tcp_util.seqLt(seq, tcb.snd_nxt)) : (guard += 1) {
        if (!isSacked(tcb, seq)) return seq;
        var jumped = false;
        for (0..tcb.sack_scoreboard_count) |i| {
            const blk = tcb.sack_scoreboard[i];
            if (tcp_util.seqInWindow(seq, blk.left, blk.right)) {
                seq = blk.right;
                jumped = true;
                break;
            }
        }
        if (!jumped) seq +%= 1;
    }
    return tcb.snd_una;
}

/// Point `snd_nxt` / `send_unacked` at the first non-SACKed hole (SK-108).
fn prepareRexmitFromHole(tcb: *TcpTcb) void {
    const hole = nextRexmitSeq(tcb);
    const skip = hole -% tcb.snd_una;
    tcb.snd_nxt = hole;
    tcb.send_unacked = (tcb.send_head + skip) % SEND_BUF_SIZE;
}

/// Advance past SACKed bytes in the send ring (SK-108).
fn skipSackedSendRange(tcb: *TcpTcb) void {
    var guard: u32 = 0;
    while (guard < 64 and isSacked(tcb, tcb.snd_nxt)) : (guard += 1) {
        var jump: ?u32 = null;
        for (0..tcb.sack_scoreboard_count) |i| {
            const blk = tcb.sack_scoreboard[i];
            if (tcp_util.seqInWindow(tcb.snd_nxt, blk.left, blk.right)) {
                jump = blk.right;
                break;
            }
        }
        const j = jump orelse break;
        const skip = j -% tcb.snd_nxt;
        if (skip == 0) break;
        const pending = ringDataLen(tcb.send_unacked, tcb.send_tail, SEND_BUF_SIZE);
        if (skip > pending) break;
        tcb.snd_nxt = j;
        tcb.send_unacked = (tcb.send_unacked + skip) % SEND_BUF_SIZE;
    }
}

/// Probe helper (SK-108): next rexmit seq given one SACK block [left,right).
pub fn probeNextRexmitSeq(snd_una: u32, snd_nxt: u32, sack_left: u32, sack_right: u32) u32 {
    var seq = snd_una;
    var guard: u32 = 0;
    while (guard < 64 and tcp_util.seqLt(seq, snd_nxt)) : (guard += 1) {
        if (!tcp_util.seqInWindow(seq, sack_left, sack_right)) return seq;
        seq = sack_right;
    }
    return snd_una;
}

/// Probe helper (SK-111): overlap of one SACK block with [una,nxt).
pub fn probeSackOverlap(una: u32, nxt: u32, left: u32, right: u32) u32 {
    return sackRangeOverlap(una, nxt, left, right);
}

/// Probe helper (SK-111): pipe = flight − sacked.
pub fn probePipeBytes(flight: u32, sacked: u32) u32 {
    if (sacked >= flight) return 0;
    return flight - sacked;
}

/// Probe helper (SK-112): RFC 6675 IsLost predicate.
pub fn probeIsLost(sacked_above: u32, sack_blocks_above: u32, smss: u32) bool {
    if (sack_blocks_above >= DUP_THRESH) return true;
    if (smss > 0 and sacked_above >= (DUP_THRESH - 1) * smss) return true;
    return false;
}

/// RFC 6937 PRR sndcnt in bytes (SK-114).
/// When pipe > ssthresh: CEIL(prr_delivered * ssthresh / RecoverFS) − prr_out.
/// Else SSRB: MIN(ssthresh − pipe, MAX(prr_delivered − prr_out, DeliveredData)).
pub fn probePrrSndcnt(
    pipe: u32,
    ssthresh: u32,
    recover_fs: u32,
    prr_delivered: u32,
    prr_out: u32,
    delivered_data: u32,
) u32 {
    const fs = if (recover_fs == 0) @as(u32, 1) else recover_fs;
    if (pipe > ssthresh) {
        const target64 = (@as(u64, prr_delivered) * @as(u64, ssthresh) + fs - 1) / fs;
        const target: u32 = @intCast(@min(target64, @as(u64, 0xffff_ffff)));
        if (target > prr_out) return target - prr_out;
        return 0;
    }
    var sndcnt: u32 = if (prr_delivered > prr_out) prr_delivered - prr_out else 0;
    if (delivered_data > sndcnt) sndcnt = delivered_data;
    const limit: u32 = if (ssthresh > pipe) ssthresh - pipe else 0;
    if (sndcnt > limit) sndcnt = limit;
    return sndcnt;
}

/// Apply PRR after DeliveredData bytes arrive during recovery (SK-114).
fn applyPrr(tcb: *TcpTcb, delivered_data: u32) void {
    tcb.prr_delivered +%= delivered_data;
    const pipe = pipeBytes(tcb);
    const sndcnt = probePrrSndcnt(
        pipe,
        tcb.ssthresh,
        tcb.recover_fs,
        tcb.prr_delivered,
        tcb.prr_out,
        delivered_data,
    );
    tcb.cwnd = pipe + sndcnt;
}

/// RFC 1122 keepalive probe SEQ = SND.UNA − 1 (SK-109).
pub fn probeKeepaliveSeq(snd_una: u32) u32 {
    return snd_una -% 1;
}

/// Send an empty ACK with SEQ=SND.UNA-1 (SK-109). Does not advance snd_nxt.
fn sendKeepaliveProbe(tcb: *TcpTcb) bool {
    return sendSegmentSeq(tcb, ACK, undefined, 0, probeKeepaliveSeq(tcb.snd_una));
}

/// True when a zero-window persist timer should run (SK-110).
pub fn probePersistActive(snd_wnd: u32, unsent: u32) bool {
    return snd_wnd == 0 and unsent > 0;
}

/// True when the persist timer has reached its current interval (SK-110).
pub fn probePersistDue(timer_ms: u32, interval_ms: u32) bool {
    return interval_ms > 0 and timer_ms >= interval_ms;
}

/// Send a 1-byte window probe, bypassing the zero send window (SK-110).
fn sendPersistProbe(tcb: *TcpTcb) bool {
    const unsent = ringDataLen(tcb.send_unacked, tcb.send_tail, SEND_BUF_SIZE);
    if (unsent == 0) return false;
    var seg_buf: [1]u8 = undefined;
    ringRead(&tcb.send_buf, SEND_BUF_SIZE, tcb.send_unacked, &seg_buf, 1);
    if (!sendSegment(tcb, ACK | PSH, &seg_buf, 1)) return false;
    tcb.send_unacked = (tcb.send_unacked + 1) % SEND_BUF_SIZE;
    return true;
}
