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
    if (iters >= MAX_POLL_ITERS) return true;
    return now_ns -% start_ns >= QUERY_TIMEOUT_NS;
}
