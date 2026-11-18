//! The IPv4 identification field of headers the kernel writes, as pure decisions (Linux include/net/ip.h ip_select_ident_segs,
//! net/ipv4/route.c __ip_select_ident, measured in hello418). A connected TCP socket or a UDP socket numbers its datagrams from its
//! own counter (inet_id, random at connect and accept) and keeps DF; a SYN-ACK leaves with id 0 under DF
//! (ip_build_and_send_pkt); other packets (an unconnected UDP socket's datagrams, ICMP errors, echo replies, raw and IP_HDRINCL
//! sends) take the next value of one of BUCKETS counters chosen by hashing (daddr, saddr, protocol) with a boot secret, which jumps
//! ahead at random after a quiet spell (reserve), so an observer can neither read one flow's id off another nor count a flow's packets.

pub const BUCKETS: u32 = 64;

/// The id a socket's counter hands out now; the counter moves on by one and wraps through 0 (atomic_add_return on inet_id).
pub fn take(cur: *u16) u16 {
    const id = cur.*;
    cur.* = id +% 1;
    return id;
}

/// The id a shared counter hands out at time `now` (ticks) when it was last used at `stamp.*` (ip_idents_reserve): after a quiet
/// spell the counter first jumps ahead by `rand` below the ticks that passed, so its users' traffic cannot be counted off it.
pub fn reserve(cur: *u16, stamp: *u32, now: u32, rand: u32) u16 {
    var delta: u32 = 0;
    if (stamp.* != now) {
        delta = rand % (now -% stamp.*);
        stamp.* = now;
    }
    const id = cur.* +% @as(u16, @truncate(delta));
    cur.* = id +% 1;
    return id;
}

/// The counter bucket of a datagram from `saddr` to `daddr` of `protocol` (siphash(daddr, saddr, protocol) in __ip_select_ident).
pub fn bucket(daddr: [4]u8, saddr: [4]u8, protocol: u8, secret: u32) u32 {
    var h: u32 = secret ^ 0x9e3779b9;
    for (daddr ++ saddr ++ [1]u8{protocol}) |b| {
        h ^= b;
        h *%= 0x01000193;
        h ^= h >> 15;
    }
    h *%= 0x85ebca6b;
    h ^= h >> 13;
    h *%= 0xc2b2ae35;
    h ^= h >> 16;
    return h % BUCKETS;
}

/// ip_select_ident_segs for a datagram no connected socket numbers: one with DF that the stack may not fragment keeps id 0; any other
/// takes a value from the shared counters.
pub fn numbersUnowned(df: bool, ignore_df: bool) bool {
    return !df or ignore_df;
}

/// A TCP segment with these `flags` takes the connection's id; only a SYN-ACK (sent like ip_build_and_send_pkt, DF and id 0) does not.
pub fn tcpUsesSocketId(flags: u8) bool {
    return flags & 0x12 != 0x12;
}
