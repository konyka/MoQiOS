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
