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
