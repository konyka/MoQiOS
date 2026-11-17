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
/// are reported (soft ones, such as time exceeded or net unreachable, only through the error queue, which MoQiOS does not have).
/// Parameter problem is EPROTO; source quench and redirect are no error.
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
pub fn parseErrorQuote6(msg: []const u8) ?ErrorQuote6 {
    if (msg.len < 8 + V6_IP_HEADER_LEN + 8) return null;
    if ((msg[8] >> 4) != 6) return null;
    const p = 8 + V6_IP_HEADER_LEN;
    var dst: [16]u8 = undefined;
    @memcpy(&dst, msg[8 + 24 ..][0..16]);
    switch (msg[8 + 6]) {
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
