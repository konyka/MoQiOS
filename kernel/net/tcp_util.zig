//! Arch-clean TCP pure helpers: ring-buffer math, RFC 793 modular sequence
//! comparisons, and the IPv4 pseudo-header TCP checksum.
//!
//! These carry no connection state, locks, timers, or scheduler/driver
//! dependencies — only `lib/byte_order.zig` + `net/ipv4.zig` (both portable) —
//! so they compile and run on every arch. `tcp.zig` delegates to them; keeping
//! them here lets the logic be exercised on non-x86 (SK-54) without dragging in
//! the full stateful TCP engine (idt/scheduler/locks).

const bo = @import("../lib/byte_order.zig");
const ipv4 = @import("ipv4.zig");

// ─── Ring-buffer occupancy (send/recv buffers are power-of-two rings) ────────

/// Bytes currently held in a ring of `size`, wrap-around safe.
pub fn ringDataLen(head: u32, tail: u32, size: u32) u32 {
    return (tail -% head) % size;
}

/// Free bytes in a ring of `size` (one slot reserved to disambiguate full/empty).
pub fn ringAvailable(head: u32, tail: u32, size: u32) u32 {
    return size - ringDataLen(head, tail, size) - 1;
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
