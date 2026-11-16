//! IPv4 ping sockets (socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)), Linux net/ipv4/ping.c: the user writes an ICMP echo request, the
//! kernel puts the socket's ident (its "port") in the id field and checksums it, and the echo replies whose id is that ident are
//! queued on the socket.

const EINVAL: i64 = -22;
const EMSGSIZE: i64 = -90;

pub const ICMP_ECHOREPLY: u8 = 0;
pub const ICMP_ECHO: u8 = 8;
pub const ICMP_EXT_ECHO: u8 = 42;
pub const ICMP_EXT_ECHOREPLY: u8 = 43;
pub const HEADER_LEN: usize = 8;
/// SO_REUSEADDR in sockopt_policy.Stored.flags.
const REUSEADDR_FLAG: u16 = 1;
/// The largest message one datagram carries here (the UDP payload limit; Linux allows up to 0xffff with fragmentation).
pub const MAX_MESSAGE: usize = 1472;

/// ping_common_sendmsg: the message must hold a whole ICMP header and be an echo request (or an extended one) with code 0.
pub fn sendErrno(len: usize, icmp_type: u8, code: u8) i64 {
    if (len > MAX_MESSAGE) return EMSGSIZE;
    if (len < HEADER_LEN) return EINVAL;
    if ((icmp_type != ICMP_ECHO and icmp_type != ICMP_EXT_ECHO) or code != 0) return EINVAL;
    return 0;
}

/// ping_v4_sendmsg: the id field is the socket's ident and the checksum covers the whole message (header and data).
pub fn finishRequest(msg: []u8, ident: u16) void {
    msg[2] = 0;
    msg[3] = 0;
    msg[4] = @truncate(ident >> 8);
    msg[5] = @truncate(ident);
    const sum = checksum(msg);
    msg[2] = @truncate(sum >> 8);
    msg[3] = @truncate(sum);
}

/// The ident of the ping socket an ICMP message is for (ping_rcv via icmp_rcv: echo replies and extended echo replies with code 0),
/// null for anything else.
pub fn replyIdent(msg: []const u8) ?u16 {
    if (msg.len < HEADER_LEN) return null;
    if ((msg[0] != ICMP_ECHOREPLY and msg[0] != ICMP_EXT_ECHOREPLY) or msg[1] != 0) return null;
    return (@as(u16, msg[4]) << 8) | msg[5];
}

/// ping_get_port: two ping sockets share an ident only when both set SO_REUSEADDR (Linux checks sk_reuse, whatever the addresses).
pub fn mayShareIdent(new_flags: u16, holder_flags: u16) bool {
    return (new_flags & REUSEADDR_FLAG) != 0 and (holder_flags & REUSEADDR_FLAG) != 0;
}

/// ping_check_bind_addr: a ping socket binds the wildcard or one of this host's unicast addresses; a group or a broadcast address is
/// EADDRNOTAVAIL even though UDP may bind those.
pub fn bindAddrAllowed(addr: [4]u8, local: bool) bool {
    if (@as(u32, @bitCast(addr)) == 0) return true;
    if (addr[0] >= 224) return false;
    return local;
}

/// ping_bind: a socket that already has an ident (bound, or given one by its first send) cannot bind again.
pub fn bindErrno(has_ident: bool) i64 {
    return if (has_ident) EINVAL else 0;
}

/// ping_lookup: a socket bound to an address takes only replies sent to that address.
pub fn takesReply(bound: [4]u8, dst: [4]u8) bool {
    return @as(u32, @bitCast(bound)) == 0 or @as(u32, @bitCast(bound)) == @as(u32, @bitCast(dst));
}

fn checksum(buf: []const u8) u16 {
    var acc: u32 = 0;
    var i: usize = 0;
    while (i + 1 < buf.len) : (i += 2) acc += (@as(u32, buf[i]) << 8) | buf[i + 1];
    if (i < buf.len) acc += @as(u32, buf[i]) << 8;
    while (acc > 0xffff) acc = (acc & 0xffff) + (acc >> 16);
    return ~@as(u16, @truncate(acc));
}
