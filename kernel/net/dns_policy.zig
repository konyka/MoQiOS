//! DNS response acceptance (anti-spoofing). Pure: no arch/udp imports.
//!
//! A response is only considered when it comes from the exact server and
//! port the query was sent to and echoes the query's (random) ID.

pub const DNS_PORT: u16 = 53;

pub fn acceptResponse(
    src_ip: [4]u8,
    src_port: u16,
    server_ip: [4]u8,
    resp_id: u16,
    query_id: u16,
) bool {
    if (src_port != DNS_PORT) return false;
    for (src_ip, server_ip) |a, b| {
        if (a != b) return false;
    }
    return resp_id == query_id;
}

/// acceptResponse for a server with an IPv6 address.
pub fn acceptResponse6(src_ip: [16]u8, src_port: u16, server_ip: [16]u8, resp_id: u16, query_id: u16) bool {
    if (src_port != DNS_PORT) return false;
    for (src_ip, server_ip) |a, b| {
        if (a != b) return false;
    }
    return resp_id == query_id;
}

/// Whether an IPv6 nameserver from /etc/resolv.conf is an address a query can go to: unicast. :: and multicast (ff00::/8) are not.
pub fn serverUsable6(ip: [16]u8) bool {
    if (ip[0] == 0xff) return false;
    for (ip) |b| if (b != 0) return true;
    return false;
}

/// The IPv4 address of an IPv4-mapped IPv6 address (::ffff:a.b.c.d), else null: such a nameserver is asked over IPv4.
pub fn mappedV4(ip: [16]u8) ?[4]u8 {
    for (ip[0..10]) |b| if (b != 0) return null;
    if (ip[10] != 0xff or ip[11] != 0xff) return null;
    return ip[12..16].*;
}

/// Bit 31 of the timeout_ms argument of dns_query, dns_query6 and dns_ptr: `server` points to 16 bytes (an IPv6 nameserver)
/// instead of 4. The limit is the low bits.
pub const SERVER6_FLAG: u64 = 0x8000_0000;

/// Bit 30, with SERVER6_FLAG: the 16 bytes are followed by a u32 scope id (/etc/resolv.conf "nameserver fe80::1%eth0").
pub const SCOPE6_FLAG: u64 = 0x4000_0000;

/// Bit 29: ask only over TCP, with no UDP query first (/etc/resolv.conf "options use-vc"; glibc 2.44 sends no UDP then, measured).
pub const VC_FLAG: u64 = 0x2000_0000;

/// Bit 28: every query carries an EDNS(0) OPT record (/etc/resolv.conf "options edns0"; glibc 2.44 adds it to UDP and TCP queries
/// alike, measured).
pub const EDNS0_FLAG: u64 = 0x1000_0000;

/// Bit 27: every query has the AD bit set (/etc/resolv.conf "options trust-ad"; glibc 2.44 sends header flags 0x0120, measured).
pub const AD_FLAG: u64 = 0x0800_0000;

/// Every flag bit of the timeout argument; the limit is what is left.
pub const ARG_FLAGS: u64 = SERVER6_FLAG | SCOPE6_FLAG | VC_FLAG | EDNS0_FLAG | AD_FLAG;

/// The resolv.conf options a query carries in its timeout argument.
pub const QueryFlags = struct { vc: bool = false, edns0: bool = false, ad: bool = false };

pub fn queryFlags(timeout_arg: u64) QueryFlags {
    return .{ .vc = timeout_arg & VC_FLAG != 0, .edns0 = timeout_arg & EDNS0_FLAG != 0, .ad = timeout_arg & AD_FLAG != 0 };
}

/// The flags word of a query's header: a standard query with recursion desired, and the AD bit with trust-ad.
pub fn queryHeaderFlags(qf: QueryFlags) u16 {
    return if (qf.ad) 0x0120 else 0x0100;
}

/// The UDP payload size glibc 2.44 advertises in its OPT record (measured: 0x04b0).
pub const EDNS_UDP_SIZE: u16 = 1200;

/// Append the OPT record of "options edns0" to the `len`-byte query in `pkt` (RFC 6891 6.1.2: root owner, TYPE 41, CLASS the UDP
/// payload size, TTL 0 for extended RCODE, version 0 and no DO bit, no options) and count it in ARCOUNT, as glibc 2.44 sends it
/// (measured). The new length; `len` unchanged when the record does not fit.
pub fn appendOpt(pkt: []u8, len: usize) usize {
    if (len < 12 or len + 11 > pkt.len) return len;
    const rec = [11]u8{ 0, 0, 41, @intCast(EDNS_UDP_SIZE >> 8), @intCast(EDNS_UDP_SIZE & 0xff), 0, 0, 0, 0, 0, 0 };
    @memcpy(pkt[len..][0..11], &rec);
    const ar = (@as(u16, pkt[10]) << 8 | pkt[11]) + 1;
    pkt[10] = @intCast(ar >> 8);
    pkt[11] = @intCast(ar & 0xff);
    return len + 11;
}

/// Whether a scoped IPv6 server can be asked: a link-local one only through the NIC (interface 2 while it is up, the only interface
/// with a link-local address); glibc 2.44 fails such a server at once otherwise (measured), here -ENETUNREACH. Any other address
/// ignores the scope.
pub fn scopedServerErrno(ip: [16]u8, scope: u32, nic_active: bool) i64 {
    if (!(ip[0] == 0xfe and (ip[1] & 0xc0) == 0x80)) return 0;
    if (scope == 2 and nic_active) return 0;
    return -101; // ENETUNREACH
}

/// What an accepted reply (right server, port and id) means for the query: it carries answers to look through, it settles that
/// there is no address (an error RCODE such as NXDOMAIN, SERVFAIL or REFUSED, or NOERROR with no answers), or it is not a response.
pub const Verdict = enum { answer, no_address, ignore };

/// `flags` is the reply's second header word, `ancount` its answer count (RFC 1035 4.1.1).
pub fn verdict(flags: u16, ancount: u16) Verdict {
    if ((flags & 0x8000) == 0) return .ignore;
    if ((flags & 0x000F) != 0) return .no_address;
    return if (ancount == 0) .no_address else .answer;
}

/// Whether a caller-named nameserver (dns_resolve_via, from /etc/resolv.conf) is an address a query can go to: unicast IPv4.
/// 0.0.0.0, the limited broadcast and multicast (224/4) are refused.
pub fn serverUsable(ip: [4]u8) bool {
    if (ip[0] == 0 and ip[1] == 0 and ip[2] == 0 and ip[3] == 0) return false;
    if (ip[0] == 255 and ip[1] == 255 and ip[2] == 255 and ip[3] == 255) return false;
    if (ip[0] >= 224 and ip[0] <= 239) return false;
    return true;
}

/// How long one DNS query may wait for its server (in nanoseconds of real time).
pub const QUERY_TIMEOUT_NS: u64 = 2_000_000_000;

/// Hard cap on poll iterations of one wait. A system call runs with interrupts masked (SFMASK clears IF), so the
/// timer interrupt that advances the tick counter does not run inside it: a wait measured in ticks never expires.
/// Time comes from the TSC instead; the cap covers the case where the TSC is not calibrated and reads as 0.
pub const MAX_POLL_ITERS: u32 = 50_000_000;

/// Whether a wait that began at clock reading `start_ns` has run out at reading `now_ns`, after `iters` polls.
/// Wrapping subtraction keeps a counter that wrapped from either expiring at once or lasting forever.
pub fn waitExpired(start_ns: u64, now_ns: u64, iters: u32) bool {
    return waitExpiredAfter(start_ns, now_ns, iters, QUERY_TIMEOUT_NS);
}

/// waitExpired with a limit of `limit_ns` instead of QUERY_TIMEOUT_NS.
pub fn waitExpiredAfter(start_ns: u64, now_ns: u64, iters: u32, limit_ns: u64) bool {
    if (iters >= MAX_POLL_ITERS) return true;
    return now_ns -% start_ns >= limit_ns;
}

/// Longest wait dns_query (507) accepts for one query, in milliseconds. glibc caps resolv.conf "options timeout" at 30 s, and
/// res_send waits (timeout << i) / nservers for server i > 0: up to 40 s for the third of three servers.
pub const MAX_QUERY_TIMEOUT_MS: u64 = 60_000;

pub fn timeoutValid(ms: u64) bool {
    return ms >= 1 and ms <= MAX_QUERY_TIMEOUT_MS;
}

/// How one query to one server ended, as a resolver acting on it (glibc res_send/res_search, measured) needs to know:
/// - answer: NOERROR with an address;
/// - nodata: NOERROR without an A record (the name exists);
/// - nxdomain: RCODE 3, the name does not exist;
/// - next_server: SERVFAIL (2), which glibc takes as "ask the next server" and, in a search list, as "try the next domain";
/// - refused: NOTIMP (4) or REFUSED (5): the next server too, but a search list stops there;
/// - failed: any other RCODE (FORMERR 1, 6..15), which ends the query for this name;
/// - timeout, interrupted: no reply in time, or a signal ended the wait;
/// - ignore: the packet is not a response (keep waiting);
/// - truncated: TC is set; the answers are not used and the query is asked again over TCP (glibc, measured);
/// - tcp_failed: that TCP connection was refused, closed or reset before a whole reply: no reply from this server (TRY_AGAIN).
pub const Outcome = enum { answer, nodata, nxdomain, next_server, refused, failed, timeout, interrupted, ignore, truncated, tcp_failed };

/// The outcome of an accepted reply from its header: `flags` the second header word, `ancount` the answer count. `answer` only
/// says there are answers to look through; the caller turns it into `nodata` when none of them is an A record.
pub fn classify(flags: u16, ancount: u16) Outcome {
    if ((flags & 0x8000) == 0) return .ignore;
    if ((flags & 0x0200) != 0) return .truncated;
    return switch (flags & 0x000F) {
        0 => if (ancount == 0) .nodata else .answer,
        3 => .nxdomain,
        2 => .next_server,
        4, 5 => .refused,
        else => .failed,
    };
}

/// The result of dns_query for `o`: 0, or -ENOENT, -ENODATA, -EAGAIN (SERVFAIL), -ECONNREFUSED (NOTIMP, REFUSED), -EPROTO,
/// -ETIMEDOUT, -EINTR.
pub fn queryResult(o: Outcome) i64 {
    return switch (o) {
        .answer => 0,
        .nxdomain => -2,
        .nodata => -61,
        .next_server => -11,
        .refused => -111,
        .failed => -71,
        .timeout => -110,
        .interrupted => -4,
        .ignore => -110,
        .truncated => -110,
        .tcp_failed => -11,
    };
}

/// One result for the A (`a`) and AAAA (`b`) halves of an AF_UNSPEC lookup's pair of queries to one name, as -errno values
/// (queryResult), which the search list then treats like a single query's (glibc 2.44, measured with every pair of reply codes):
/// either half answering is an answer; else an A failure that is not NXDOMAIN, NODATA, SERVFAIL or REFUSED (FORMERR, no reply)
/// wins, then NXDOMAIN from either, then any such AAAA failure, then NODATA from either, then the A result.
pub fn pairResult(a: i64, b: i64) i64 {
    if (a == 0 or b == 0) return 0;
    const soft = struct {
        fn f(r: i64) bool {
            return r == -2 or r == -61 or r == -11 or r == -111;
        }
    }.f;
    if (!soft(a)) return a;
    if (a == -2 or b == -2) return -2;
    if (!soft(b)) return b;
    if (a == -61 or b == -61) return -61;
    return a;
}

/// dns_query2's return value for the two results (0 or -errno each): the A errno in bits 0-7, the AAAA one in bits 8-15.
pub fn packPair(a: i64, b: i64) i64 {
    return (@as(i64, @intCast(-a)) & 0xff) | (@as(i64, @intCast(-b)) & 0xff) << 8;
}

/// The 2-byte big-endian length a DNS message carries over TCP (RFC 1035 4.2.2), into `out[0..2]`.
pub fn tcpLength(out: []u8, len: u16) void {
    out[0] = @intCast(len >> 8);
    out[1] = @intCast(len & 0xff);
}

/// The message length a TCP stream announces in its first two bytes; null until both have arrived.
pub fn tcpFrameLen(got: []const u8) ?usize {
    if (got.len < 2) return null;
    return @as(usize, got[0]) << 8 | got[1];
}

/// The bytes a TCP reply takes in all (the prefix and the message, at most 2 + 65535) once its prefix is in; null until then.
/// glibc 2.44 reads such a reply whole however long it is (measured: 64029 bytes), so the reader sizes its buffer by this.
pub fn tcpFrameNeed(got: []const u8) ?usize {
    const n = tcpFrameLen(got) orelse return null;
    return 2 + n;
}

/// Which of the queries sharing one TCP connection (ids `ids`, `done` once answered) a reply with id `id` belongs to; null for
/// none. glibc 2.44 sends an AF_UNSPEC pair on one use-vc connection and takes the replies in either order (measured).
pub fn pendingFor(ids: []const u16, done: []const bool, id: u16) ?usize {
    for (ids, 0..) |q, k| {
        if (!done[k] and q == id) return k;
    }
    return null;
}

/// Whether `got` holds the length prefix and the whole message it announces.
pub fn tcpFrameComplete(got: []const u8) bool {
    const n = tcpFrameLen(got) orelse return false;
    return got.len >= 2 + n;
}
