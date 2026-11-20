//! ICMP destination-unreachable for UDP (RFC 792) as pure decisions.
//!
//! A datagram that reaches a host with nothing bound to its destination port
//! is answered with "port unreachable" quoting the offending IP header plus
//! the first 8 bytes of the datagram (the UDP header, which carries both
//! ports). The sender matches that quote back to its socket; a connected
//! socket then fails its next operation with ECONNREFUSED.

const std = @import("std");

pub const TYPE_DEST_UNREACH: u8 = 3;
pub const CODE_PORT_UNREACH: u8 = 3;

/// Bytes of the offending datagram carried in the message: its IP header and
/// the first 8 bytes of the payload.
pub fn quoteLen(ip_header_len: u16, datagram_len: u32) u32 {
    return @min(@as(u32, ip_header_len) + 8, datagram_len);
}

/// Whether an unreachable reply is sent for a datagram that found no socket.
/// Loopback only (needs no ARP, and answering unsolicited traffic from remote
/// hosts is a reflection vector); never in answer to ICMP, broadcast or a
/// non-first fragment.
pub fn shouldReply(is_loopback: bool, is_broadcast: bool, port_bound: bool) bool {
    return is_loopback and !is_broadcast and !port_bound;
}

pub const Quoted = struct { src_port: u16, dst_port: u16 };

/// The ports in the quoted UDP header of a port-unreachable message.
/// `msg` starts at the ICMP header; the quote follows the 8-byte ICMP header.
pub fn parseQuote(msg: []const u8) ?Quoted {
    if (msg.len < 8 + 20 + 8) return null;
    if (msg[0] != TYPE_DEST_UNREACH or msg[1] != CODE_PORT_UNREACH) return null;
    const ihl: usize = @as(usize, msg[8] & 0x0F) * 4;
    if (ihl < 20 or msg.len < 8 + ihl + 8) return null;
    if (msg[8 + 9] != 17) return null; // the quoted datagram must be UDP
    const u = 8 + ihl;
    return .{
        .src_port = std.mem.readInt(u16, msg[u..][0..2], .big),
        .dst_port = std.mem.readInt(u16, msg[u + 2 ..][0..2], .big),
    };
}

/// Whether a quoted datagram belongs to a socket connected to `peer_port`
/// (the destination port of what it sent).
pub fn matchesConnected(q: Quoted, local_port: u16, connected: bool, peer_port: u16) bool {
    return connected and q.src_port == local_port and q.dst_port == peer_port;
}

pub const V6_TYPE_DEST_UNREACH: u8 = 1;
pub const V6_CODE_PORT_UNREACH: u8 = 4;
const V6_IP_HEADER_LEN: usize = 40;

/// ICMPv6 destination-unreachable / port-unreachable (RFC 4443 §3.1) quoting
/// a UDP datagram. `msg` starts at the ICMPv6 header; the invoking IPv6 header
/// follows the 8-byte ICMPv6 header, then the UDP header.
pub fn parseQuoteV6(msg: []const u8) ?Quoted {
    if (msg.len < 8 + V6_IP_HEADER_LEN + 8) return null;
    if (msg[0] != V6_TYPE_DEST_UNREACH or msg[1] != V6_CODE_PORT_UNREACH) return null;
    if ((msg[8] >> 4) != 6) return null;
    if (msg[8 + 6] != 17) return null; // the quoted packet must carry UDP directly
    const u = 8 + V6_IP_HEADER_LEN;
    return .{
        .src_port = std.mem.readInt(u16, msg[u..][0..2], .big),
        .dst_port = std.mem.readInt(u16, msg[u + 2 ..][0..2], .big),
    };
}

/// Whether an IPv6 datagram that found no socket is answered: ::1 to ::1 only
/// (no neighbour discovery needed, and no reflection of unsolicited traffic
/// from remote hosts), never when a socket is bound to the port.
pub fn shouldReplyV6(src_is_loopback: bool, dst_is_loopback: bool, port_bound: bool) bool {
    return src_is_loopback and dst_is_loopback and !port_bound;
}


// ── ICMP errors for UDP and ping sockets (Linux icmp_err_convert, udp_err, ping_err) ──

/// ICMP types that report an error about a datagram this host sent (each quotes it): destination unreachable, source quench,
/// redirect, time exceeded, parameter problem.
pub fn isError(icmp_type: u8) bool {
    return icmp_type == 3 or icmp_type == 4 or icmp_type == 5 or icmp_type == 11 or icmp_type == 12;
}

/// Destination unreachable codes 0..15: the errno and whether it is a hard error (icmp_err_convert). Fragmentation needed is
/// EMSGSIZE and hard for a socket that does path MTU discovery, the default.
const unreach_errno = [16]struct { errno: i32, hard: bool }{
    .{ .errno = 101, .hard = false }, // net unreachable: ENETUNREACH
    .{ .errno = 113, .hard = false }, // host unreachable: EHOSTUNREACH
    .{ .errno = 92, .hard = true }, // protocol unreachable: ENOPROTOOPT
    .{ .errno = 111, .hard = true }, // port unreachable: ECONNREFUSED
    .{ .errno = 90, .hard = true }, // fragmentation needed: EMSGSIZE
    .{ .errno = 95, .hard = false }, // source route failed: EOPNOTSUPP
    .{ .errno = 101, .hard = true }, // destination network unknown: ENETUNREACH
    .{ .errno = 112, .hard = true }, // destination host unknown: EHOSTDOWN
    .{ .errno = 64, .hard = true }, // source host isolated: ENONET
    .{ .errno = 101, .hard = true }, // network administratively prohibited: ENETUNREACH
    .{ .errno = 113, .hard = true }, // host administratively prohibited: EHOSTUNREACH
    .{ .errno = 101, .hard = false }, // network unreachable for TOS: ENETUNREACH
    .{ .errno = 113, .hard = false }, // host unreachable for TOS: EHOSTUNREACH
    .{ .errno = 113, .hard = true }, // communication administratively prohibited: EHOSTUNREACH
    .{ .errno = 113, .hard = true }, // host precedence violation: EHOSTUNREACH
    .{ .errno = 113, .hard = true }, // precedence cutoff: EHOSTUNREACH
};

/// The errno a connected UDP or ping socket without IP_RECVERR takes from an ICMP error, 0 when it takes none: only hard errors
/// are reported (soft ones, such as time exceeded or net unreachable, only through the IP_RECVERR error queue: errorFor).
/// Parameter problem is EPROTO; source quench and redirect are no error.
/// The errno an ICMP error gives a datagram socket and whether it is hard (__udp4_lib_err), null when it is none: time exceeded is a
/// soft EHOSTUNREACH, source quench and redirect are nothing, an unknown unreachable code is a soft EHOSTUNREACH.
pub fn errorFor(icmp_type: u8, code: u8) ?struct { errno: i32, hard: bool } {
    return switch (icmp_type) {
        3 => if (code < unreach_errno.len) .{ .errno = unreach_errno[code].errno, .hard = unreach_errno[code].hard } else .{ .errno = 113, .hard = false },
        11 => .{ .errno = 113, .hard = false },
        12 => .{ .errno = 71, .hard = true },
        else => null,
    };
}

/// ping_err's conversion for an IPv4 ping socket: as errorFor, except source quench and redirect, which ping wants to see, are a soft
/// EREMOTEIO (121), and any other type a soft EHOSTUNREACH. Only a socket with IP_RECVERR takes the soft ones.
pub fn pingErrorFor(icmp_type: u8, code: u8) struct { errno: i32, hard: bool } {
    return switch (icmp_type) {
        4, 5 => .{ .errno = 121, .hard = false },
        else => if (errorFor(icmp_type, code)) |e| .{ .errno = e.errno, .hard = e.hard } else .{ .errno = 113, .hard = false },
    };
}

/// raw_err's conversion for a raw socket: source quench and redirect are none; parameter problem a hard EPROTO; an unreachable code
/// 0..15 from icmp_err_convert, except fragmentation needed, EMSGSIZE and hard only when the socket does not have IP_PMTUDISC_DONT;
/// time exceeded, an unknown unreachable code and any other type a soft EHOSTUNREACH.
pub fn rawErrorFor(icmp_type: u8, code: u8, pmtudisc_dont: bool) ?struct { errno: i32, hard: bool } {
    return switch (icmp_type) {
        4, 5 => null,
        12 => .{ .errno = 71, .hard = true },
        3 => if (code == 4) .{ .errno = 90, .hard = !pmtudisc_dont } else if (code < unreach_errno.len) .{ .errno = unreach_errno[code].errno, .hard = unreach_errno[code].hard } else .{ .errno = 113, .hard = false },
        else => .{ .errno = 113, .hard = false },
    };
}

pub fn errnoFor(icmp_type: u8, code: u8) i32 {
    return switch (icmp_type) {
        3 => if (code < unreach_errno.len and unreach_errno[code].hard) unreach_errno[code].errno else 0,
        12 => 71, // EPROTO
        else => 0,
    };
}

pub const QuoteKind = enum { udp, echo };
/// What an ICMP error quotes: a UDP datagram (its ports) or an echo request a ping socket sent (`src_port` is its ident).
pub const ErrorQuote = struct { kind: QuoteKind, src_port: u16, dst_port: u16 = 0 };

/// The datagram quoted by an ICMP error. `msg` starts at the ICMP header; the quoted IP header follows the 8-byte ICMP header,
/// then at least 8 bytes of its payload. An echo reply or other ICMP is for no socket (ping_err only looks at echo requests).
pub fn parseErrorQuote(msg: []const u8) ?ErrorQuote {
    if (msg.len < 8 + 20 + 8) return null;
    const ihl: usize = @as(usize, msg[8] & 0x0F) * 4;
    if (ihl < 20 or msg.len < 8 + ihl + 8) return null;
    const p = 8 + ihl;
    switch (msg[8 + 9]) {
        17 => return .{
            .kind = .udp,
            .src_port = std.mem.readInt(u16, msg[p..][0..2], .big),
            .dst_port = std.mem.readInt(u16, msg[p + 2 ..][0..2], .big),
        },
        1 => {
            if (msg[p] != 8 or msg[p + 1] != 0) return null;
            return .{ .kind = .echo, .src_port = std.mem.readInt(u16, msg[p + 4 ..][0..2], .big) };
        },
        else => return null,
    }
}

// ── ICMPv6 errors for IPv6 UDP and ping sockets (Linux icmpv6_err_convert, __udp6_lib_err, icmpv6_err → ping_err) ──

/// ICMPv6 types below 128 are errors (RFC 4443 §2.1, ICMPV6_INFOMSG_MASK); each quotes the packet that caused it.
pub fn isError6(icmp_type: u8) bool {
    return icmp_type & 0x80 == 0;
}

/// Destination unreachable codes 0..6: the errno and whether it is a hard error (tab_unreach). A larger code is EPROTO, hard.
const unreach6_errno = [7]struct { errno: i32, hard: bool }{
    .{ .errno = 101, .hard = false }, // no route: ENETUNREACH
    .{ .errno = 13, .hard = true }, // administratively prohibited: EACCES
    .{ .errno = 113, .hard = false }, // beyond the scope of the source (was not a neighbour): EHOSTUNREACH
    .{ .errno = 113, .hard = false }, // address unreachable: EHOSTUNREACH
    .{ .errno = 111, .hard = true }, // port unreachable: ECONNREFUSED
    .{ .errno = 13, .hard = true }, // source address failed policy: EACCES
    .{ .errno = 13, .hard = true }, // reject route: EACCES
};

/// The errno a connected IPv6 UDP (`ping` false) or ping socket without IPV6_RECVERR takes from an ICMPv6 error, 0 when it takes
/// none: only hard errors are reported. Packet too big is EMSGSIZE and hard for a UDP socket doing path MTU discovery (the
/// default), soft for a ping socket; time exceeded and error types Linux does not know are soft; parameter problem is EPROTO.
/// The errno an ICMPv6 error gives an IPv6 UDP socket and whether it is hard (__udp6_lib_err via icmpv6_err_convert), null when it is
/// none of the errors Linux converts. Soft ones only reach a socket with IPV6_RECVERR.
pub fn errorFor6(icmp_type: u8, code: u8) ?struct { errno: i32, hard: bool } {
    return switch (icmp_type) {
        1 => if (code < unreach6_errno.len) .{ .errno = unreach6_errno[code].errno, .hard = unreach6_errno[code].hard } else .{ .errno = 71, .hard = true },
        2 => .{ .errno = 90, .hard = true },
        3 => .{ .errno = 113, .hard = false },
        4 => .{ .errno = 71, .hard = true },
        else => null,
    };
}

/// ping_err's conversion for an IPv6 ping socket (icmpv6_err_convert): as errorFor6, except packet too big is soft for ping and an
/// error type it does not know is a soft EPROTO. Only a socket with IPV6_RECVERR takes the soft ones.
pub fn pingErrorFor6(icmp_type: u8, code: u8) struct { errno: i32, hard: bool } {
    if (icmp_type == 2) return .{ .errno = 90, .hard = false };
    return if (errorFor6(icmp_type, code)) |e| .{ .errno = e.errno, .hard = e.hard } else .{ .errno = 71, .hard = false };
}

/// rawv6_err's conversion (icmpv6_err_convert): as errorFor6 for the known types, except packet too big, hard only for a socket with
/// IPV6_PMTUDISC_DO, and an unknown error type, a soft EPROTO.
pub fn rawErrorFor6(icmp_type: u8, code: u8, pmtudisc_do: bool) struct { errno: i32, hard: bool } {
    if (icmp_type == 2) return .{ .errno = 90, .hard = pmtudisc_do };
    return if (errorFor6(icmp_type, code)) |e| .{ .errno = e.errno, .hard = e.hard } else .{ .errno = 71, .hard = false };
}

pub fn errnoFor6(icmp_type: u8, code: u8, ping: bool) i32 {
    return switch (icmp_type) {
        1 => if (code < unreach6_errno.len) (if (unreach6_errno[code].hard) unreach6_errno[code].errno else 0) else 71,
        2 => if (ping) 0 else 90,
        4 => 71,
        else => 0,
    };
}

/// What an ICMPv6 error quotes: a UDP datagram (its ports and destination) or an echo request a ping socket sent (`src_port` is
/// its ident).
pub const ErrorQuote6 = struct { kind: QuoteKind, src_port: u16, dst_port: u16 = 0, dst: [16]u8 = @splat(0) };

/// The packet quoted by an ICMPv6 error. `msg` starts at the ICMPv6 header; the quoted IPv6 header follows the 8-byte ICMPv6
/// header, then at least 8 bytes of its payload. Only a packet carrying UDP or ICMPv6 directly is matched (Linux icmpv6_notify
/// would also skip extension headers); an echo reply or a request with a nonzero code is for no socket (ping_supported).
/// Linux ipv6_ext_hdr: the next-header values that are IPv6 extension headers (hop-by-hop, routing, fragment, AH, none, destination
/// options) rather than an upper-layer protocol.
pub fn isExtHdr6(nh: u8) bool {
    return nh == 0 or nh == 43 or nh == 44 or nh == 51 or nh == 59 or nh == 60;
}

pub const ExtSkip6 = struct { off: usize, nh: u8 };

/// Linux ipv6_skip_exthdr over `pkt` (an IPv6 packet) from `start` with next header `nh`: steps over extension headers (AH counts
/// 4-byte units plus 2, the others 8-byte units plus 1, a fragment header is 8 bytes) and returns the offset and next header of the
/// first non-extension header. A non-first fragment stops the walk at its fragment header; "no next header" or a header that does not
/// fit gives null.
pub fn skipExtHdr6(pkt: []const u8, start: usize, nh: u8) ?ExtSkip6 {
    var off = start;
    var next = nh;
    while (isExtHdr6(next)) {
        if (next == 59) return null;
        if (off + 2 > pkt.len) return null;
        var len: usize = undefined;
        if (next == 44) {
            if (off + 4 > pkt.len) return null;
            if (std.mem.readInt(u16, pkt[off + 2 ..][0..2], .big) & ~@as(u16, 7) != 0) break;
            len = 8;
        } else if (next == 51) {
            len = (@as(usize, pkt[off + 1]) + 2) << 2;
        } else {
            len = (@as(usize, pkt[off + 1]) + 1) << 3;
        }
        next = pkt[off];
        off += len;
    }
    return .{ .off = off, .nh = next };
}

pub fn parseErrorQuote6(msg: []const u8) ?ErrorQuote6 {
    if (msg.len < 8 + V6_IP_HEADER_LEN) return null;
    if ((msg[8] >> 4) != 6) return null;
    const inner = skipExtHdr6(msg[8..], V6_IP_HEADER_LEN, msg[8 + 6]) orelse return null;
    const p = 8 + inner.off;
    if (msg.len < p + 8) return null;
    var dst: [16]u8 = undefined;
    @memcpy(&dst, msg[8 + 24 ..][0..16]);
    switch (inner.nh) {
        17 => return .{
            .kind = .udp,
            .src_port = std.mem.readInt(u16, msg[p..][0..2], .big),
            .dst_port = std.mem.readInt(u16, msg[p + 2 ..][0..2], .big),
            .dst = dst,
        },
        58 => {
            if (msg[p] != 128 or msg[p + 1] != 0) return null;
            return .{ .kind = .echo, .src_port = std.mem.readInt(u16, msg[p + 4 ..][0..2], .big), .dst = dst };
        },
        else => return null,
    }
}

// ── ICMP errors for TCP (Linux tcp_v4_err, tcp_v6_err) ──

/// The errno an ICMP error gives a TCP connection, 0 when it gives none: destination unreachable codes 0..15 through
/// icmp_err_convert (hard or soft alike), except fragmentation needed, which only lowers the path MTU; time exceeded EHOSTUNREACH,
/// parameter problem EPROTO. Source quench, redirect and anything else are no error.
pub fn tcpErrno(icmp_type: u8, code: u8) i32 {
    return switch (icmp_type) {
        3 => if (code == 4 or code >= unreach_errno.len) 0 else unreach_errno[code].errno,
        11 => 113,
        12 => 71,
        else => 0,
    };
}

/// tcp_v6_err (icmpv6_err_convert): destination unreachable by code (an unknown code EPROTO), time exceeded EHOSTUNREACH,
/// parameter problem EPROTO. Packet too big only lowers the path MTU; redirect and informational messages are no error.
pub fn tcpErrno6(icmp_type: u8, code: u8) i32 {
    return switch (icmp_type) {
        1 => if (code < unreach6_errno.len) unreach6_errno[code].errno else 71,
        3 => 113,
        4 => 71,
        else => 0,
    };
}

/// The quoted segment counts only when its sequence number lies in [snd_una, snd_nxt] (tcp_v4_err's `between`), so a blind error
/// cannot end a connection.
pub fn tcpSeqOk(seq: u32, snd_una: u32, snd_nxt: u32) bool {
    return seq -% snd_una <= snd_nxt -% snd_una;
}

pub const TcpErrAction = enum { ignore, abort, request, soft };

/// What an error with an errno does to a connection in `state`: SYN_SENT ends with it (tcp_done_with_error: connect fails, POLLERR);
/// SYN_RECEIVED is a connection a listener has not handed out yet, which tcp_req_err drops silently or keeps (`request`, see
/// tcpReqAborts); an established or closing connection keeps it as the soft error (sk_err_soft), which SO_ERROR reports once;
/// TIME_WAIT, LISTEN and CLOSED take nothing.
pub fn tcpErrAction(state: @import("tcp_recv_policy.zig").TcpState) TcpErrAction {
    return switch (state) {
        .syn_sent => .abort,
        .syn_received => .request,
        .closed, .listen, .time_wait => .ignore,
        else => .soft,
    };
}

/// tcp_v4_err / tcp_v6_err for an established connection: a socket with IP_RECVERR (IPV6_RECVERR) takes the error as sk_err at once,
/// which the next recv or send reports and poll shows as POLLERR; one without keeps it as sk_err_soft (SO_ERROR, or the timeout's
/// errno).
pub fn tcpSoftIsHard(recverr: bool) bool {
    return recverr;
}

/// tcp_req_err: a connection still in the listener's queue is dropped (no error reaches anyone: accept() must not report network
/// errors) when the error quotes its SYN-ACK (sequence = its ISN) and is parameter problem, time exceeded, or net or host
/// unreachable; for ICMPv6 when icmpv6_err_convert calls it fatal (destination unreachable but no route, beyond scope and address
/// unreachable; parameter problem). Any other error leaves it alone.
pub fn tcpReqAborts(icmp_type: u8, code: u8) bool {
    return icmp_type == 12 or icmp_type == 11 or (icmp_type == 3 and (code == 0 or code == 1));
}

pub fn tcpReqAborts6(icmp_type: u8, code: u8) bool {
    return switch (icmp_type) {
        1 => code >= unreach6_errno.len or unreach6_errno[code].hard,
        4 => true,
        else => false,
    };
}

/// What an ICMP error quotes of a TCP segment: its ports, sequence number, source (this host) and destination.
pub const TcpQuote = struct { src_port: u16, dst_port: u16, seq: u32, src4: [4]u8 = @splat(0), dst4: [4]u8 = @splat(0), src: [16]u8 = @splat(0), dst: [16]u8 = @splat(0) };

/// The TCP segment quoted by an ICMP error (`msg` starts at the ICMP header): the quoted IPv4 header, then at least 8 bytes of TCP.
pub fn parseTcpQuote(msg: []const u8) ?TcpQuote {
    if (msg.len < 8 + 20 + 8) return null;
    const ihl: usize = @as(usize, msg[8] & 0x0F) * 4;
    if (ihl < 20 or msg.len < 8 + ihl + 8 or msg[8 + 9] != 6) return null;
    const p = 8 + ihl;
    return .{
        .src_port = std.mem.readInt(u16, msg[p..][0..2], .big),
        .dst_port = std.mem.readInt(u16, msg[p + 2 ..][0..2], .big),
        .seq = std.mem.readInt(u32, msg[p + 4 ..][0..4], .big),
        .src4 = msg[8 + 12 ..][0..4].*,
        .dst4 = msg[8 + 16 ..][0..4].*,
    };
}

/// The TCP segment quoted by an ICMPv6 error, after the quoted IPv6 header and its extension headers.
pub fn parseTcpQuote6(msg: []const u8) ?TcpQuote {
    if (msg.len < 8 + V6_IP_HEADER_LEN or (msg[8] >> 4) != 6) return null;
    const inner = skipExtHdr6(msg[8..], V6_IP_HEADER_LEN, msg[8 + 6]) orelse return null;
    const p = 8 + inner.off;
    if (inner.nh != 6 or msg.len < p + 8) return null;
    return .{
        .src_port = std.mem.readInt(u16, msg[p..][0..2], .big),
        .dst_port = std.mem.readInt(u16, msg[p + 2 ..][0..2], .big),
        .seq = std.mem.readInt(u32, msg[p + 4 ..][0..4], .big),
        .src = msg[8 + 8 ..][0..16].*,
        .dst = msg[8 + 24 ..][0..16].*,
    };
}
