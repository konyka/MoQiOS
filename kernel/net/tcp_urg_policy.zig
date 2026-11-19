//! TCP urgent data (MSG_OOB) as pure rules over sequence numbers (Linux net/ipv4/tcp_input.c tcp_check_urg / tcp_urg,
//! net/ipv4/tcp.c tcp_recv_urg / tcp_recvmsg_locked / tcp_poll, include/net/tcp.h tcp_inq).
//!
//! The urgent byte stays in the receive ring at sequence `urg_seq`: a normal read stops in front of it, and once the reader is at
//! the mark a read skips the byte unless SO_OOBINLINE is set. recv(MSG_OOB) hands out the copy taken when it arrived. The sender
//! marks the byte before its write sequence end (snd_up): every segment that starts before snd_up carries URG and the offset to
//! snd_up (the BSD pointer, tcp_stdurg off), which the receiver turns back into the last byte.

const std = @import("std");

pub const URG: u8 = 0x20;
pub const MSG_OOB: u32 = 0x1;
/// SO_OOBINLINE's bit in the socket's option flags (sockopt_policy.flagBit).
pub const OOBINLINE_FLAG: u16 = 64;

/// Linux tp->urg_data: nothing, a mark whose byte has not arrived (TCP_URG_NOTYET), the byte is here (TCP_URG_VALID), or it was
/// taken by recv(MSG_OOB) (TCP_URG_READ; the mark stays until a normal read passes it).
pub const State = enum(u8) { none, notyet, valid, read };

fn before(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) < 0;
}

fn after(a: u32, b: u32) bool {
    return before(b, a);
}

/// The sequence number of the urgent byte a segment at `seq` with pointer `ptr` names (the pointer is one past it).
pub fn pointerSeq(seq: u32, ptr: u16) u32 {
    const p: u32 = if (ptr != 0) ptr - 1 else 0;
    return seq +% p;
}

pub const Check = enum {
    /// Ignore the pointer: the byte was read already, it is behind rcv_nxt, or it is the mark we know.
    ignore,
    /// A new mark: SIGURG the owner, and record urg_seq with the byte not yet seen.
    new_mark,
    /// As new_mark, and the old urgent byte sitting at the read position is dropped first (one sequence number skipped).
    new_mark_skip_old,
};

/// tcp_check_urg for urgent byte `ptr_seq` given the read position `copied`, `rcv_nxt`, and the current mark.
pub fn check(ptr_seq: u32, copied: u32, rcv_nxt: u32, state: State, urg_seq: u32, oobinline: bool) Check {
    if (after(copied, ptr_seq)) return .ignore;
    if (before(ptr_seq, rcv_nxt)) return .ignore;
    if (state != .none and !after(ptr_seq, urg_seq)) return .ignore;
    if (urg_seq == copied and state != .none and !oobinline and copied != rcv_nxt) return .new_mark_skip_old;
    return .new_mark;
}

/// The offset of the urgent byte in a segment at `seq` of `len` bytes while the byte is awaited, or null.
pub fn byteOffset(state: State, urg_seq: u32, seq: u32, len: u32) ?u32 {
    if (state != .notyet) return null;
    const off = urg_seq -% seq;
    return if (off < len) off else null;
}

pub const Limit = struct {
    /// Bytes to step over at the read position first (the urgent byte, when not inline).
    skip: u32,
    /// Bytes a read may return after that: up to the mark, or everything.
    avail: u32,
};

/// What a read may take from `available` ring bytes starting at sequence `copied` (tcp_recvmsg_locked): it stops in front of the
/// mark, and at the mark it skips the urgent byte unless SO_OOBINLINE.
pub fn readLimit(state: State, urg_seq: u32, copied: u32, available: u32, oobinline: bool) Limit {
    if (state == .none) return .{ .skip = 0, .avail = available };
    const off = urg_seq -% copied;
    if (off >= available) return .{ .skip = 0, .avail = available };
    if (off == 0) {
        if (oobinline) return .{ .skip = 0, .avail = available };
        return .{ .skip = 1, .avail = available - 1 };
    }
    return .{ .skip = 0, .avail = off };
}

/// The mark is behind the read position once a read passed it: the urgent state ends (urg_data = 0).
pub fn passed(state: State, urg_seq: u32, copied: u32) bool {
    return state != .none and after(copied, urg_seq);
}

/// FIONREAD / SIOCINQ (tcp_inq): the bytes up to the mark while it lies ahead in the ring, else all of them.
pub fn inq(state: State, urg_seq: u32, copied: u32, available: u32, oobinline: bool) u32 {
    if (oobinline or state == .none) return available;
    const off = urg_seq -% copied;
    return if (off < available) off else available;
}

/// SIOCATMARK: the next byte read is the urgent one.
pub fn atMark(state: State, urg_seq: u32, copied: u32) bool {
    return state != .none and urg_seq == copied;
}

/// tcp_poll: readable needs one byte more while the reader sits at a mark it will skip (POLLPRI is reported while the byte is valid,
/// inline or not).
pub fn readableBytes(state: State, urg_seq: u32, copied: u32, available: u32, oobinline: bool) u32 {
    if (state != .none and urg_seq == copied and !oobinline) return available -| 1;
    return available;
}

pub const Oob = union(enum) { byte: u8, err: i64 };

/// recv(MSG_OOB) (tcp_recv_urg), after the LISTEN check: EINVAL with SO_OOBINLINE or no unread byte, ENOTCONN on a socket that never
/// connected, the byte, 0 once nothing more can arrive, else EAGAIN (it never blocks).
pub fn recvOob(state: State, byte: u8, oobinline: bool, closed_never_connected: bool, read_done: bool) Oob {
    if (oobinline or state == .none or state == .read) return .{ .err = -22 };
    if (closed_never_connected) return .{ .err = -107 };
    if (state == .valid) return .{ .byte = byte };
    if (read_done) return .{ .err = 0 };
    return .{ .err = -11 };
}

/// The urgent pointer a segment starting at `seq` carries (tcp_transmit_skb), or null: only while the mark is unacknowledged,
/// the segment starts in front of it, and the offset fits 16 bits.
pub fn sendPointer(active: bool, snd_una: u32, snd_up: u32, seq: u32) ?u16 {
    if (!active or !before(snd_una, snd_up) or !before(seq, snd_up)) return null;
    const d = snd_up -% seq;
    return if (d < 0x10000) @intCast(d) else null;
}

test "the receiver finds the byte in front of the pointer" {
    try std.testing.expectEqual(@as(u32, 102), pointerSeq(100, 3));
    try std.testing.expectEqual(@as(u32, 100), pointerSeq(100, 0));
    try std.testing.expectEqual(Check.new_mark, check(102, 100, 100, .none, 0, false));
    try std.testing.expectEqual(Check.ignore, check(102, 100, 103, .valid, 102, false));
    try std.testing.expectEqual(Check.ignore, check(99, 100, 100, .none, 0, false));
    try std.testing.expectEqual(Check.new_mark_skip_old, check(105, 100, 101, .valid, 100, false));
    try std.testing.expectEqual(Check.new_mark, check(105, 100, 101, .valid, 100, true));
    try std.testing.expectEqual(@as(?u32, 2), byteOffset(.notyet, 102, 100, 3));
    try std.testing.expectEqual(@as(?u32, null), byteOffset(.notyet, 105, 100, 3));
}

test "reads stop at the mark and skip the byte there" {
    try std.testing.expectEqual(Limit{ .skip = 0, .avail = 2 }, readLimit(.valid, 102, 100, 5, false));
    try std.testing.expectEqual(Limit{ .skip = 1, .avail = 2 }, readLimit(.valid, 102, 102, 3, false));
    try std.testing.expectEqual(Limit{ .skip = 0, .avail = 3 }, readLimit(.valid, 102, 102, 3, true));
    try std.testing.expectEqual(@as(u32, 2), inq(.valid, 102, 100, 5, false));
    try std.testing.expectEqual(@as(u32, 0), inq(.read, 102, 102, 3, false));
    try std.testing.expect(atMark(.read, 102, 102));
    try std.testing.expect(passed(.read, 102, 103));
    try std.testing.expectEqual(@as(u32, 0), readableBytes(.valid, 102, 102, 1, false));
}

test "recv(MSG_OOB) and the sender's pointer" {
    try std.testing.expectEqual(Oob{ .byte = 'c' }, recvOob(.valid, 'c', false, false, false));
    try std.testing.expectEqual(Oob{ .err = -22 }, recvOob(.read, 'c', false, false, false));
    try std.testing.expectEqual(Oob{ .err = -22 }, recvOob(.valid, 'c', true, false, false));
    try std.testing.expectEqual(Oob{ .err = -11 }, recvOob(.notyet, 0, false, false, false));
    try std.testing.expectEqual(@as(?u16, 3), sendPointer(true, 100, 103, 100));
    try std.testing.expectEqual(@as(?u16, null), sendPointer(true, 103, 103, 103));
    try std.testing.expectEqual(@as(?u16, null), sendPointer(false, 100, 103, 100));
}
