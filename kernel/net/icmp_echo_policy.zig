//! ICMPv4 echo-reply sizing policy (RFC 792). Pure: no arch/netif imports.
//!
//! RFC 792 requires the echo reply to return the request's data verbatim, so
//! the reply ICMP message is the full request, bounded only by what fits in
//! one unfragmented IPv4 datagram on the interface (MTU - 20-byte IPv4
//! header) and by the caller's frame buffer (minus 14-byte Ethernet + 20-byte
//! IPv4 headers).

pub const ETH_HDR_LEN: u32 = 14;
pub const IPV4_HDR_LEN: u32 = 20;
/// Ethernet + IPv4 header bytes in front of the ICMP message.
pub const ICMP_OFFSET: u32 = ETH_HDR_LEN + IPV4_HDR_LEN;
/// Echo reply frame buffer size (max Ethernet frame incl. FCS room).
pub const FRAME_BUF_LEN: u32 = 1518;

/// ICMP message length of the echo reply for a `req_len`-byte request on an
/// interface with `mtu`, written into a `frame_cap`-byte frame buffer.
pub fn replyIcmpLen(req_len: u32, mtu: u32, frame_cap: u32) u16 {
    const by_mtu: u32 = if (mtu > IPV4_HDR_LEN) mtu - IPV4_HDR_LEN else 0;
    const by_buf: u32 = if (frame_cap > ICMP_OFFSET) frame_cap - ICMP_OFFSET else 0;
    const n = @min(req_len, @min(by_mtu, by_buf));
    return @intCast(@min(n, @as(u32, 0xFFFF)));
}
