//! IPv4 ping sockets (socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)), Linux net/ipv4/ping.c: the user writes an ICMP echo request, the
//! kernel puts the socket's ident (its "port") in the id field and checksums it, and the echo replies whose id is that ident are
//! queued on the socket.

const std = @import("std");

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

/// A ping socket holding the ident of a reply: when it was hashed (later = larger), the address it is bound to and the peer it is
/// connected to (0.0.0.0 for none; ping_lookup does not look at it).
pub const Holder = struct { seq: u32, bound: [4]u8, peer: [4]u8 = .{ 0, 0, 0, 0 } };

/// Which holder an echo reply from `src` to `dst` goes to (ping_lookup): the hash chain is walked from its head and a socket is put
/// at the head when it is hashed, so the most recently hashed holder whose bound address takes the reply wins.
pub fn pickReceiver(holders: []const Holder, src: [4]u8, dst: [4]u8) ?usize {
    _ = src;
    var best: ?usize = null;
    for (holders, 0..) |h, i| {
        if (!takesReply(h.bound, dst)) continue;
        if (best == null or h.seq > holders[best.?].seq) best = i;
    }
    return best;
}

// ── IPv6 ping sockets (socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6), net/ipv6/ping.c) ──

pub const ICMPV6_ECHO_REQUEST: u8 = 128;
pub const ICMPV6_ECHO_REPLY: u8 = 129;
pub const ICMPV6_EXT_ECHO_REQUEST: u8 = 160;
pub const ICMPV6_EXT_ECHO_REPLY: u8 = 161;
const EAFNOSUPPORT: i64 = -97;
const EADDRNOTAVAIL: i64 = -99;
const ENODEV: i64 = -19;

/// ping_common_sendmsg for AF_INET6: a whole ICMPv6 header, an echo request (or an extended one) with code 0.
pub fn sendErrno6(len: usize, icmp_type: u8, code: u8) i64 {
    if (len > MAX_MESSAGE) return EMSGSIZE;
    if (len < HEADER_LEN) return EINVAL;
    if ((icmp_type != ICMPV6_ECHO_REQUEST and icmp_type != ICMPV6_EXT_ECHO_REQUEST) or code != 0) return EINVAL;
    return 0;
}

/// ping_v6_sendmsg: the id field is the socket's ident (the checksum, over the IPv6 pseudo-header, is set once the source is known).
pub fn setIdent(msg: []u8, ident: u16) void {
    msg[4] = @truncate(ident >> 8);
    msg[5] = @truncate(ident);
}

/// ping_v6_sendmsg: a destination that needs a scope sent with no interface, or a v4-mapped one, is EINVAL.
pub fn destErrno6(dst: [16]u8, scoped: bool, oif: u8) i64 {
    if (scoped and oif == 0) return EINVAL;
    if (std.mem.allEqual(u8, dst[0..10], 0) and dst[10] == 0xff and dst[11] == 0xff) return EINVAL;
    return 0;
}

/// The ident of the IPv6 ping socket an ICMPv6 message is for (icmpv6_rcv → ping_rcv: echo replies and extended echo replies
/// with code 0), null for anything else.
pub fn replyIdent6(msg: []const u8) ?u16 {
    if (msg.len < HEADER_LEN) return null;
    if ((msg[0] != ICMPV6_ECHO_REPLY and msg[0] != ICMPV6_EXT_ECHO_REPLY) or msg[1] != 0) return null;
    return (@as(u16, msg[4]) << 8) | msg[5];
}

/// ping_check_bind_addr for AF_INET6 (after the length and family checks): a group is EINVAL, as is an address that needs a scope
/// without one; a scope naming no interface is ENODEV; an address of another host EADDRNOTAVAIL. `scoped`: the address needs a
/// scope; `dev_ok`: the scope names an interface; `local`: the address is this host's.
pub fn bindAddrErrno6(addr: [16]u8, scoped: bool, scope_id: u32, dev_ok: bool, local: bool) i64 {
    const any = std.mem.allEqual(u8, &addr, 0);
    if (!any and addr[0] == 0xff) return EINVAL;
    if (scoped and scope_id == 0) return EINVAL;
    if (scope_id != 0 and !dev_ok) return ENODEV;
    if (!any and !local) return EADDRNOTAVAIL;
    return 0;
}

/// An IPv6 ping socket holding the ident of a reply: when it was hashed and the address it is bound to (:: for none).
pub const Holder6 = struct { seq: u32, bound: [16]u8 };

/// ping_lookup for an IPv6 reply to `dst`: the most recently hashed holder whose bound address is :: or `dst`.
pub fn pickReceiver6(holders: []const Holder6, dst: [16]u8) ?usize {
    var best: ?usize = null;
    for (holders, 0..) |h, i| {
        if (!std.mem.allEqual(u8, &h.bound, 0) and !std.mem.eql(u8, &h.bound, &dst)) continue;
        if (best == null or h.seq > holders[best.?].seq) best = i;
    }
    return best;
}

/// The address family errno of a sockaddr given to an IPv6 ping socket (EAFNOSUPPORT for anything but AF_INET6).
pub fn family6Errno(family: u16) i64 {
    return if (family == 10) 0 else EAFNOSUPPORT;
}

/// net.ipv4.ping_group_range: the groups (inclusive) that may create ping sockets. The default, 1 0, is empty: nobody may.
pub const GroupRange = struct { low: u32 = 1, high: u32 = 0 };

/// The overflow gid shown for an empty range (from_kgid_munged of an unmapped gid).
const OVERFLOW_GID: u32 = 65534;
/// GID_T_MAX: (gid_t)-1 is the invalid gid, so the largest value accepted is one below it.
const GID_T_MAX: u64 = 0xffff_fffe;

/// ping_init_sock: the caller's egid or one of its supplementary groups lies in the range.
pub fn groupAllowed(r: GroupRange, egid: u32, groups: []const u32) bool {
    if (r.low > r.high) return false;
    if (egid >= r.low and egid <= r.high) return true;
    for (groups) |g| {
        if (g >= r.low and g <= r.high) return true;
    }
    return false;
}

/// The text a read of the file gives: the two gids separated by a tab and ended by a newline; an empty range reads as the overflow
/// gid twice. Returns the length written to `out` (at least 23 bytes).
pub fn formatRange(r: GroupRange, out: []u8) usize {
    const lo: u32 = if (r.low > r.high) OVERFLOW_GID else r.low;
    const hi: u32 = if (r.low > r.high) OVERFLOW_GID else r.high;
    var n = putDecimal(out, 0, lo);
    out[n] = '\t';
    n = putDecimal(out, n + 1, hi);
    out[n] = '\n';
    return n + 1;
}

/// A write of `text` (ipv4_ping_group_range through proc_doulongvec_minmax): up to two unsigned values (decimal, 0x hex or 0 octal)
/// separated by blanks; a missing second value keeps the old high end; a value past GID_T_MAX, a negative one or a non-number is
/// EINVAL and changes nothing; an inverted range is stored as the empty one. Returns the bytes consumed (through the blanks after the
/// last value taken) or -EINVAL.
pub fn writeRange(r: *GroupRange, text: []const u8) i64 {
    var vals: [2]u64 = .{ r.low, r.high };
    var i: usize = 0;
    var got: usize = 0;
    while (got < 2) {
        while (i < text.len and isSpace(text[i])) i += 1;
        if (i >= text.len) break;
        if (text[i] == '-') return EINVAL;
        const v = parseUlong(text, &i) orelse return EINVAL;
        if (i < text.len and !isSep(text[i])) return EINVAL;
        if (v > GID_T_MAX) return EINVAL;
        vals[got] = v;
        got += 1;
    }
    if (got == 0) return if (text.len == 0) 0 else EINVAL;
    // The trailing blanks are consumed too; anything after them (a third value) is left, so the write returns less than it was given.
    while (i < text.len and isSpace(text[i])) i += 1;
    if (vals[1] < vals[0]) {
        r.* = .{};
    } else {
        r.* = .{ .low = @intCast(vals[0]), .high = @intCast(vals[1]) };
    }
    return @intCast(i);
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

fn isSep(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

/// strtoul with base 0: 0x/0X hex, a leading 0 octal, else decimal. Null when no digit follows or the value overflows 64 bits.
fn parseUlong(text: []const u8, pos: *usize) ?u64 {
    var i = pos.*;
    var base: u64 = 10;
    if (i + 1 < text.len and text[i] == '0' and (text[i + 1] == 'x' or text[i + 1] == 'X')) {
        base = 16;
        i += 2;
    } else if (i < text.len and text[i] == '0') {
        base = 8;
    }
    const start = i;
    var v: u64 = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        const d: u64 = if (c >= '0' and c <= '9') c - '0' else if (c >= 'a' and c <= 'f') c - 'a' + 10 else if (c >= 'A' and c <= 'F') c - 'A' + 10 else break;
        if (d >= base) break;
        v = std.math.mul(u64, v, base) catch return null;
        v = std.math.add(u64, v, d) catch return null;
    }
    if (i == start) return null;
    pos.* = i;
    return v;
}

fn putDecimal(out: []u8, at: usize, v: u32) usize {
    var tmp: [10]u8 = undefined;
    var n: usize = 0;
    var x = v;
    while (true) {
        tmp[n] = @intCast('0' + x % 10);
        n += 1;
        x /= 10;
        if (x == 0) break;
    }
    for (0..n) |k| out[at + k] = tmp[n - 1 - k];
    return at + n;
}

fn checksum(buf: []const u8) u16 {
    var acc: u32 = 0;
    var i: usize = 0;
    while (i + 1 < buf.len) : (i += 2) acc += (@as(u32, buf[i]) << 8) | buf[i + 1];
    if (i < buf.len) acc += @as(u32, buf[i]) << 8;
    while (acc > 0xffff) acc = (acc & 0xffff) + (acc >> 16);
    return ~@as(u16, @truncate(acc));
}
