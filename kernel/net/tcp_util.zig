//! Arch-clean TCP pure helpers: ring-buffer math, RFC 793 modular sequence
//! comparisons, and IPv4/IPv6 pseudo-header TCP checksums.
//!
//! These carry no connection state, locks, timers, or scheduler/driver
//! dependencies — only `lib/byte_order.zig` + `net/ipv4.zig` / `ipv6.zig`
//! (all portable) — so they compile and run on every arch. `tcp.zig` delegates
//! to them; keeping them here lets the logic be exercised on non-x86 (SK-54 /
//! SK-74) without dragging in the full stateful TCP engine.

const bo = @import("../lib/byte_order.zig");
const ipv4 = @import("ipv4.zig");
const ipv6 = @import("ipv6.zig");

// ─── Ring-buffer occupancy (send/recv buffers are power-of-two rings) ────────

/// Bytes currently held in a ring of `size`, wrap-around safe.
pub fn ringDataLen(head: u32, tail: u32, size: u32) u32 {
    return (tail -% head) % size;
}

/// Free bytes in a ring of `size` (one slot reserved to disambiguate full/empty).
pub fn ringAvailable(head: u32, tail: u32, size: u32) u32 {
    return size - ringDataLen(head, tail, size) - 1;
}

/// Ring position of the next byte to send, derived from sequence state:
/// send_unacked must equal send_head + (snd_nxt -% snd_una) so flushSendBuffer
/// reads the payload that belongs to snd_nxt (prepareRexmitFromSeq sets the
/// same relation when rewinding for retransmit).
pub fn expectedSendUnacked(send_head: u32, snd_nxt: u32, snd_una: u32, size: u32) u32 {
    return (send_head + (snd_nxt -% snd_una)) % size;
}

/// Send-ring cursor after one flushed segment: the cursor may only advance
/// when the segment actually left (sendSegment advances snd_nxt on TX success
/// only). On TX failure the pre-send cursor is kept so the same bytes are
/// retried for the same snd_nxt on the next flush.
pub fn flushCommitCursor(unacked_before: u32, can_send: u32, size: u32, sent: bool) u32 {
    return if (sent) (unacked_before + can_send) % size else unacked_before;
}

// ─── RFC 793 modular sequence comparisons (32-bit wrap-around) ───────────────

/// a < b in sequence space.
pub fn seqLt(a: u32, b: u32) bool {
    return (a -% b) & 0x8000_0000 != 0;
}

/// a > b in sequence space.
pub fn seqGt(a: u32, b: u32) bool {
    return seqLt(b, a);
}

/// a <= b in sequence space.
pub fn seqLeq(a: u32, b: u32) bool {
    return !seqGt(a, b);
}

/// True when `seq` falls in the half-open window [left, right) modularly.
pub fn seqInWindow(seq: u32, left: u32, right: u32) bool {
    return (seq -% left) < (right -% left);
}

// ─── Connection bookkeeping (window, ephemeral ports, tuple match) ─────────

/// Advertised receive window: `window` minus the bytes buffered in the recv
/// ring, saturating at 0. RECV_BUF_SIZE exceeds TCP_WINDOW, so `buffered`
/// can be larger than `window` — a plain subtraction underflows u32.
pub fn rcvWindowFromBuffered(buffered: u32, window: u32) u32 {
    return if (buffered < window) window - buffered else 0;
}

/// Advance the ephemeral port counter with wrap: 65535 → 49152. Saturating
/// (`+|=`) would park the counter at 65535 and alias every later 4-tuple.
pub fn nextEphemeralPort(cur: u16) u16 {
    const next = cur +% 1;
    return if (next < 49152) 49152 else next;
}

/// TCP option-field bytes (4-aligned) for an outbound segment. Mirrors
/// fillTcpSegment's layout — SYN: MSS+WS+TS+SACK-permitted; data/ACK: TS (if
/// negotiated) + SACK blocks (if any, ACK only) — so sendSegment can run the
/// Path-MTU gate BEFORE fillTcpSegment consumes SACK state (sack_block_count)
/// that a PMTU bail would otherwise lose.
pub fn segmentOptLen(is_syn: bool, ts_enabled: bool, sack_permitted: bool, sack_block_count: u8, has_ack: bool) u8 {
    var opt_len: u8 = 0;
    if (is_syn) {
        opt_len = 4 + 3 + 10 + 2; // MSS + WS + TS + SACK-permitted
    } else {
        if (ts_enabled) opt_len += 10;
        if (sack_permitted and sack_block_count > 0 and has_ack) {
            opt_len += 2 + 8 * sack_block_count;
        }
    }
    while (opt_len % 4 != 0) opt_len += 1;
    return opt_len;
}

/// Duplicate-ACK counter step. The counter is a u3: a peer that keeps sending
/// duplicate ACKs (a zero-window receiver answering probes, a long recovery)
/// must saturate it, not overflow-panic the kernel.
pub fn bumpDupAck(count: u3) u3 {
    return count +| 1;
}

/// Congestion window after a PRR step (RFC 6937): the bytes in flight plus what
/// PRR allows to send now. With nothing in flight and sndcnt 0 that would be a
/// window of 0 — no segment, hence no ACK to leave recovery and no RTO armed:
/// the connection would sit there for good. Linux guarantees the same thing
/// (sndcnt >= 1 segment when the pipe is empty), so at least one SMSS may go.
pub fn prrCwnd(pipe: u32, sndcnt: u32, smss: u32) u32 {
    const w = pipe +| sndcnt;
    if (pipe == 0 and w < smss) return smss;
    return w;
}

/// Whether the retransmission timer has anything to guard: data (or a SYN/FIN)
/// sent and not yet acknowledged. `snd_max` is the highest sequence ever sent
/// and must start at the initial send sequence: left at 0 it compares below
/// every snd_una >= 2^31 in serial arithmetic, so an idle connection with a
/// high ISS looked permanently "unacked", fired spurious RTOs (cwnd reset,
/// backoff) and was finally closed after six of them.
pub fn unackedPending(snd_una: u32, snd_nxt: u32, snd_max: u32) bool {
    return seqLt(snd_una, snd_max) or snd_nxt != snd_una;
}

/// What the receiver reports for a data segment that is not at `rcv_nxt`.
/// The receive path keeps no out-of-order data, so a SACK block for a segment
/// ahead of `rcv_nxt` would promise bytes that are thrown away: the sender
/// would mark them delivered, never resend them once the hole is filled and
/// stall until the connection is given up. Only data the receiver really holds
/// may be reported (RFC 2883 DSACK of duplicates).
pub const OooReport = enum { none, dsack_whole, dsack_prefix };

pub fn oooReport(seq: u32, seg_end: u32, rcv_nxt: u32) OooReport {
    if (seqLeq(seg_end, rcv_nxt)) return .dsack_whole;
    if (seqLt(rcv_nxt, seq)) return .none;
    return .dsack_prefix;
}

/// A window derived from the bandwidth-delay product, never below two segments.
/// Delivery-rate x min-RTT is a handful of bytes on loopback (sub-millisecond
/// RTT, sparse samples); using it raw as cwnd/ssthresh left the sender
/// trickling out segments of a few bytes. Same floor as the CUBIC/Reno paths.
pub fn bdpWindow(bdp: u32, smss: u32) u32 {
    const floor = 2 *| @max(smss, 1);
    return @max(bdp, floor);
}

/// A connection the application already close()d (an orphan in FIN_WAIT_1 or
/// FIN_WAIT_2) can never deliver data to anyone: new payload arriving for it is
/// answered with RST (RFC 9293 §3.10.7.4), which is how the sender learns its
/// peer is gone (EPIPE on the next write) instead of writing into the void.
/// Pure duplicates of data already received are not "new" and are just ACKed.
pub fn orphanRejectsData(orphan: bool, fin_wait: bool, seq: u32, len: u32, rcv_nxt: u32) bool {
    if (!orphan or !fin_wait or len == 0) return false;
    return seqLt(rcv_nxt, seq +% len);
}

/// Payload bytes one data segment may carry: the MSS is the bound on TCP
/// payload, but every segment also carries its options (timestamps, SACK
/// blocks) inside the same MTU, so a full-MSS payload would be refused by the
/// Path-MTU gate and could never leave the send ring. Never below 1.
pub fn dataSegmentCap(mss: u32, opt_len: u32) u32 {
    if (opt_len >= mss) return 1;
    return mss - opt_len;
}

/// True when an IPv4 TCP 4-tuple matches (TIME_WAIT reuse / demux helper).
/// Mirrors `tupleMatchV6`: the remote address must match, not just ports.
pub fn tupleMatchV4(
    local_port: u16,
    remote_port: u16,
    remote_ip: [4]u8,
    cand_local: u16,
    cand_remote: u16,
    cand_ip: [4]u8,
) bool {
    return local_port == cand_local and remote_port == cand_remote and
        @as(u32, @bitCast(remote_ip)) == @as(u32, @bitCast(cand_ip));
}

// ─── TCP checksum (IPv4 pseudo-header + segment), RFC 793 §3.1 ───────────────

/// TCP checksum over the IPv4 pseudo-header and the TCP segment, reusing the
/// shared RFC 1071 folder in `ipv4.checksum`.
pub fn checksum(src_ip: [4]u8, dst_ip: [4]u8, tcp_hdr: [*]const u8, tcp_len: u16) u16 {
    var pseudo: [12]u8 = undefined;
    @memcpy(pseudo[0..4], &src_ip);
    @memcpy(pseudo[4..8], &dst_ip);
    pseudo[8] = 0; // zero
    pseudo[9] = 6; // TCP protocol
    bo.writeU16BeAt(&pseudo, 10, tcp_len);

    const pseudo_csum = ipv4.checksum(&pseudo, 12);
    const data_csum = ipv4.checksum(tcp_hdr, tcp_len);

    // Combine the two one's-complement sums and re-fold.
    var sum: u32 = @as(u32, ~pseudo_csum & 0xFFFF) + @as(u32, ~data_csum & 0xFFFF);
    sum = (sum & 0xFFFF) + (sum >> 16);
    return @truncate(~sum);
}

/// True when an IPv6 TCP 4-tuple matches (SK-75 demux helper).
pub fn tupleMatchV6(
    local_port: u16,
    remote_port: u16,
    remote_ip: [16]u8,
    cand_local: u16,
    cand_remote: u16,
    cand_ip: [16]u8,
) bool {
    return local_port == cand_local and remote_port == cand_remote and ipv6.addrEq(remote_ip, cand_ip);
}

/// TCP checksum over the IPv6 pseudo-header + segment (RFC 8200 §8.1).
/// Bytes 16..17 of `data` (on-wire checksum) are treated as zero so this works
/// for both building and verifying. A computed 0 is transmitted as 0xFFFF.
pub fn checksumV6(
    src: [16]u8,
    dst: [16]u8,
    data: [*]const u8,
    len: u16,
) u16 {
    var acc: u64 = ipv6.pseudoHeaderChecksum(src, dst, ipv6.PROTO_TCP, len);

    var i: usize = 0;
    while (i + 2 <= len) : (i += 2) {
        if (i == 16) continue; // skip TCP checksum field
        acc += (@as(u64, data[i]) << 8) | @as(u64, data[i + 1]);
    }
    if (i < len) {
        acc += @as(u64, data[i]) << 8;
    }

    var sum: u32 = @truncate(acc);
    sum +%= @as(u32, @truncate(acc >> 32));
    sum = (sum & 0xFFFF) + (sum >> 16);
    sum = (sum & 0xFFFF) + (sum >> 16);
    const folded: u16 = @truncate(~sum);
    return if (folded == 0) 0xFFFF else folded;
}

/// What to put in the reset sent for a segment that matches no connection
/// (RFC 9293 §3.10.7.1). A segment carrying ACK is answered with
/// SEQ = its ACK number and no ACK; one without gets SEQ 0 and an ACK that
/// covers it (its sequence number plus its length, a SYN counting as one).
/// A segment that is itself a RST is never answered.
pub const ResetReply = struct { seq: u32, ack: u32, with_ack: bool };

pub fn resetReply(has_ack: bool, ack_num: u32, seq_num: u32, payload_len: u32, syn: bool, fin: bool) ResetReply {
    if (has_ack) return .{ .seq = ack_num, .ack = 0, .with_ack = false };
    const extra: u32 = (if (syn) @as(u32, 1) else 0) +% (if (fin) @as(u32, 1) else 0);
    return .{ .seq = 0, .ack = seq_num +% payload_len +% extra, .with_ack = true };
}
