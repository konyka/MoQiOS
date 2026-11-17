//! Raw ICMP sockets as pure decisions: IPv4 (socket(AF_INET, SOCK_RAW, IPPROTO_ICMP), Linux net/ipv4/raw.c, measured in hello389)
//! and IPv6 (socket(AF_INET6, SOCK_RAW, IPPROTO_ICMPV6), Linux net/ipv6/raw.c, measured in hello391).
//! A send gets its IP header from the kernel; every ICMP datagram this host receives is copied to each raw socket of its family
//! whose bound address and connected peer match it: an IPv4 one with its IP header, an IPv6 one without (and only when its
//! ICMP6_FILTER lets the type through).

pub const IPPROTO_ICMP: u32 = 1;
pub const SOCKADDR_IN_LEN: u32 = 16;
const AF_INET: u16 = 2;
const EPROTONOSUPPORT: i64 = -93;
const EINVAL: i64 = -22;
const EAFNOSUPPORT: i64 = -97;
const EDESTADDRREQ: i64 = -89;
const EFAULT: i64 = -14;
const ENOTCONN: i64 = -107;
pub const IPPROTO_ICMPV6: u32 = 58;
pub const SOCKADDR_IN6_LEN: u32 = 28;
/// The part of a sockaddr_in6 rawv6_sendmsg needs (SIN6_LEN_RFC2133: everything but sin6_scope_id).
const SOCKADDR_IN6_MIN: u32 = 24;
const AF_INET6: u16 = 10;
/// struct icmp6_filter: 256 type bits, a set bit blocks the type.
pub const FILTER_LEN = 32;

/// socket(AF_INET, SOCK_RAW, protocol): MoQiOS carries ICMP only. IPPROTO_IP (0) is EPROTONOSUPPORT on Linux too; other protocols
/// Linux would accept are refused the same way.
pub fn protocolErrno(protocol: u32) i64 {
    return if (protocol == IPPROTO_ICMP) 0 else EPROTONOSUPPORT;
}

/// raw_v4_match: a socket takes a datagram when it is bound to the wildcard or to the datagram's destination, and is unconnected or
/// connected to its source.
pub fn matches(bound: [4]u8, peer: [4]u8, src: [4]u8, dst: [4]u8) bool {
    const any = [4]u8{ 0, 0, 0, 0 };
    if (!eql(bound, any) and !eql(bound, dst)) return false;
    if (!eql(peer, any) and !eql(peer, src)) return false;
    return true;
}

/// raw_sendmsg's destination: a given address must be a whole sockaddr_in (EINVAL) of family AF_INET, AF_UNSPEC being accepted for
/// old programs (EAFNOSUPPORT otherwise); without one the socket must be connected (EDESTADDRREQ).
pub fn sendtoErrno(have_addr: bool, addr_len: u32, family: u16, connected: bool) i64 {
    if (have_addr) {
        if (addr_len < SOCKADDR_IN_LEN) return EINVAL;
        if (family != AF_INET and family != 0) return EAFNOSUPPORT;
        return 0;
    }
    return if (connected) 0 else EDESTADDRREQ;
}

/// raw_bind and connect want a whole sockaddr_in.
pub fn addrLenErrno(addr_len: u32) i64 {
    return if (addr_len < SOCKADDR_IN_LEN) EINVAL else 0;
}

/// The source address of a received datagram (its IP header, bytes 12..16).
pub fn sourceOf(dgram: []const u8) [4]u8 {
    if (dgram.len < 20) return .{ 0, 0, 0, 0 };
    return dgram[12..16].*;
}

/// What getsockname reports: AF_INET, the protocol as the port (inet_num), the bound address.
pub fn sockName(bound: [4]u8) [16]u8 {
    var out: [16]u8 = @splat(0);
    out[0] = AF_INET;
    out[3] = IPPROTO_ICMP;
    @memcpy(out[4..8], &bound);
    return out;
}

/// What recvfrom reports as the sender: AF_INET, port 0, the datagram's source.
pub fn fromName(src: [4]u8) [16]u8 {
    var out: [16]u8 = @splat(0);
    out[0] = AF_INET;
    @memcpy(out[4..8], &src);
    return out;
}

fn eql(a: [4]u8, b: [4]u8) bool {
    return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
}

/// socket(AF_INET6, SOCK_RAW, protocol): MoQiOS carries ICMPv6 only (Linux takes any protocol but IPPROTO_IP).
pub fn protocolErrno6(protocol: u32) i64 {
    return if (protocol == IPPROTO_ICMPV6) 0 else EPROTONOSUPPORT;
}

/// raw_v6_match: bound to the wildcard or the destination, unconnected or connected to the source.
pub fn matches6(bound: [16]u8, peer: [16]u8, src: [16]u8, dst: [16]u8) bool {
    const any: [16]u8 = @splat(0);
    if (!eql6(bound, any) and !eql6(bound, dst)) return false;
    if (!eql6(peer, any) and !eql6(peer, src)) return false;
    return true;
}

/// icmpv6_filter: whether ICMP6_FILTER blocks ICMPv6 type `icmp_type` (bit `type & 31` of 32-bit word `type >> 5`).
pub fn filterBlocks(filter: [FILTER_LEN]u8, icmp_type: u8) bool {
    const word = @as(u32, filter[(icmp_type >> 5) * 4]) | (@as(u32, filter[(icmp_type >> 5) * 4 + 1]) << 8) |
        (@as(u32, filter[(icmp_type >> 5) * 4 + 2]) << 16) | (@as(u32, filter[(icmp_type >> 5) * 4 + 3]) << 24);
    return (word >> @intCast(icmp_type & 31)) & 1 != 0;
}

/// setsockopt(ICMP6_FILTER): at most 32 bytes are taken, the rest of the filter stays as it was (rawv6_seticmpfilter).
pub fn setFilter(filter: *[FILTER_LEN]u8, val: []const u8) void {
    const n = @min(val.len, FILTER_LEN);
    @memcpy(filter[0..n], val[0..n]);
}

/// getsockopt(ICMP6_FILTER) copies at most the whole filter.
pub fn filterGetLen(user_len: u32) u32 {
    return @min(user_len, FILTER_LEN);
}

/// rawv6_sendmsg's destination: a given address needs the first 24 bytes of a sockaddr_in6 (EINVAL), family AF_INET6 or AF_UNSPEC
/// (EAFNOSUPPORT), and sin6_port 0 or the socket's protocol (EINVAL); without one the socket must be connected (EDESTADDRREQ).
pub fn sendtoErrno6(have_addr: bool, addr_len: u32, family: u16, port: u16, connected: bool) i64 {
    if (have_addr) {
        if (addr_len < SOCKADDR_IN6_MIN) return EINVAL;
        if (family != AF_INET6 and family != 0) return EAFNOSUPPORT;
        if (port != 0 and port != IPPROTO_ICMPV6) return EINVAL;
        return 0;
    }
    return if (connected) 0 else EDESTADDRREQ;
}

/// The message length, checked after the destination: fewer than 2 bytes cannot hold the type and code the kernel reads from the
/// user buffer (EFAULT), and an ICMPv6 message shorter than its checksum offset + 2 is EINVAL (rawv6_push_pending_frames).
pub fn lengthErrno(v6: bool, len: usize) i64 {
    if (len < 2) return EFAULT;
    if (v6 and len < 4) return EINVAL;
    return 0;
}

pub fn isMapped6(addr: [16]u8) bool {
    for (addr[0..10]) |b| if (b != 0) return false;
    return addr[10] == 0xff and addr[11] == 0xff;
}

/// Where a send to `dst` goes: :: means ::1 (ip6_datagram_dst_update), a v4-mapped address has no IPv6 route (null: ENETUNREACH).
pub fn dest6(dst: [16]u8) ?[16]u8 {
    if (isMapped6(dst)) return null;
    const any: [16]u8 = @splat(0);
    if (!eql6(dst, any)) return dst;
    var l: [16]u8 = @splat(0);
    l[15] = 1;
    return l;
}

/// What getsockname reports: AF_INET6, the protocol as the port (inet_num), flowinfo 0, the bound address, scope 0.
pub fn sockName6(bound: [16]u8) [28]u8 {
    var out: [28]u8 = @splat(0);
    out[0] = AF_INET6;
    out[3] = IPPROTO_ICMPV6;
    @memcpy(out[8..24], &bound);
    return out;
}

/// What recvfrom reports as the sender: AF_INET6, port 0, flowinfo 0, the source, and its scope.
pub fn fromName6(src: [16]u8, scope: u32) [28]u8 {
    var out: [28]u8 = @splat(0);
    out[0] = AF_INET6;
    @memcpy(out[8..24], &src);
    out[24] = @truncate(scope);
    out[25] = @truncate(scope >> 8);
    out[26] = @truncate(scope >> 16);
    out[27] = @truncate(scope >> 24);
    return out;
}

/// shutdown of a raw socket (inet_shutdown): ENOTCONN unless connected, but the flags take effect either way.
pub fn shutdownErrno(connected: bool) i64 {
    return if (connected) 0 else ENOTCONN;
}

/// poll bits of a raw socket (datagram_poll): always writable; readable with a datagram queued or after SHUT_RD, which also
/// reports POLLRDHUP; both directions shut is POLLHUP.
pub fn pollBits(has_data: bool, shut_rd: bool, shut_wr: bool) u32 {
    var ev: u32 = 0x004;
    if (has_data or shut_rd) ev |= 0x001;
    if (shut_rd) ev |= 0x2000;
    if (shut_rd and shut_wr) ev |= 0x010;
    return ev;
}

pub const EmptyRecv = enum { eagain, eof, wait };

/// A receive that finds the queue empty: EAGAIN when it may not wait, 0 (end of file) once SHUT_RD, otherwise it waits.
pub fn emptyRecv(nonblock: bool, shut_rd: bool) EmptyRecv {
    if (nonblock) return .eagain;
    if (shut_rd) return .eof;
    return .wait;
}

fn eql6(a: [16]u8, b: [16]u8) bool {
    return @as(u128, @bitCast(a)) == @as(u128, @bitCast(b));
}
