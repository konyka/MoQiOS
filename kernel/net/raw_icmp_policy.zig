//! IPv4 raw ICMP sockets (socket(AF_INET, SOCK_RAW, IPPROTO_ICMP), Linux net/ipv4/raw.c) as pure decisions, measured in hello389.
//! A send gets its IP header from the kernel; every ICMP datagram this host receives is copied, IP header included, to each raw
//! socket whose bound address and connected peer match it.

pub const IPPROTO_ICMP: u32 = 1;
pub const SOCKADDR_IN_LEN: u32 = 16;
const AF_INET: u16 = 2;
const EPROTONOSUPPORT: i64 = -93;
const EINVAL: i64 = -22;
const EAFNOSUPPORT: i64 = -97;
const EDESTADDRREQ: i64 = -89;

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
