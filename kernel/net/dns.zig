/// DNS Resolver — Domain Name System query/resolution.
///
/// Implements:
///   - Static built-in host table (net/static_hosts.zig, consulted first)
///   - DNS A record queries (IPv4)
///   - Response parsing with header, question, answer sections
///   - Simple 16-entry LRU cache with TTL expiry
///   - Kernel API: dnsResolve(hostname) → [4]u8
const serial = @import("../arch/arch.zig").serial;
const cpu = @import("../arch/arch.zig").cpu;
const udp = @import("udp.zig");
const netif = @import("netif.zig");
const idt = @import("../arch/arch.zig").interrupts;
const tsc = @import("../arch/arch.zig").tsc;
const bo = @import("../lib/byte_order.zig");
const dns_policy = @import("dns_policy.zig");
const dns_answer = @import("dns_answer.zig");

/// Largest reply read: a reply over 512 bytes reaches us whole over UDP (glibc reads such replies too, measured: 984 bytes, 60
/// addresses), so the buffer must not cut it at the classic 512.
const MAX_REPLY: usize = 4096;

const DNS_PORT: u16 = dns_policy.DNS_PORT;
const DNS_CACHE_SIZE: u32 = 16;


/// Longest name the resolver takes, as text without the trailing dot (hostname_policy.MAX_NAME: 253; a 255-octet wire name).
/// A name with a search domain appended (/etc/resolv.conf "search") easily passes the old 63.
const MAX_NAME: usize = @import("hostname_policy.zig").MAX_NAME;

/// DNS cache entry
const DnsCacheEntry = struct {
    name: [MAX_NAME]u8,
    name_len: u8,
    ip: [4]u8,
    ttl: u64, // Expiry tick count
    valid: bool = false,
    last_used: u64 = 0, // For LRU eviction
};

var cache: [DNS_CACHE_SIZE]DnsCacheEntry = @splat(.{
    .name = @splat(0),
    .name_len = 0,
    .ip = .{ 0, 0, 0, 0 },
    .ttl = 0,
});
fn newQueryId() u16 {
    const random = @import("../drivers/random.zig");
    var b: [2]u8 = undefined;
    random.getRandomBytes(&b, 2);
    return bo.readU16BeAt(&b, 0);
}

/// Resolve a hostname to an IPv4 address.
/// Returns [4]u8 on success, or .{0,0,0,0} on failure.
/// Order: static host table → dotted-decimal parse → cache → network
/// query. The static table (net/static_hosts.zig) answers names the
/// kernel knows authoritatively (localhost, the slirp gateway) without
/// depending on a reachable DNS server.
pub fn resolve(hostname: []const u8) [4]u8 {
    return resolveYield(hostname, null);
}

/// How a query waits between polls. A system call passes a function that sleeps for a moment and returns false when a signal
/// ends the wait: the reply may come from a process on this very CPU (a local DNS server), and spinning inside the system call
/// would keep it from running until the timeout. null spins (kernel-internal callers, which cannot sleep).
pub const Yield = ?*const fn () bool;

/// resolve() whose waits go through `yield`.
pub fn resolveYield(hostname: []const u8, yield: Yield) [4]u8 {
    if (hostname.len == 0 or hostname.len > MAX_NAME) return .{ 0, 0, 0, 0 };

    // Static built-in names first: no NIC, server, or ~2s query timeout.
    const static_hosts = @import("static_hosts.zig");
    if (static_hosts.lookup(hostname)) |ip| {
        return ip;
    }

    // Check if it's already an IP address (dotted decimal)
    if (isIpV4(hostname)) {
        return parseIpV4(hostname);
    }

    // Check cache
    if (lookupCache(hostname)) |ip| {
        return ip;
    }

    // Send DNS query
    const dns_server = getDnsServer();
    if (dns_server[0] == 0 and dns_server[1] == 0 and dns_server[2] == 0 and dns_server[3] == 0) {
        // Use DHCP DNS if available, otherwise fall back to 8.8.8.8
        const dhcp = @import("dhcp.zig");
        if (dhcp.isConfigured()) {
            const dhcp_dns = dhcp.getDnsServer();
            if (dhcp_dns[0] != 0) {
                return queryDns(hostname, dhcp_dns, yield);
            }
        }
        // Fallback to Google DNS
        return queryDns(hostname, .{ 8, 8, 8, 8 }, yield);
    }

    return queryDns(hostname, dns_server, yield);
}

/// Get the DNS server address (from DHCP or default).
pub fn getDnsServer() [4]u8 {
    const dhcp = @import("dhcp.zig");
    if (dhcp.isConfigured()) {
        return dhcp.getDnsServer();
    }
    return .{ 8, 8, 8, 8 }; // Default: Google DNS
}

/// Resolve `hostname` through `server` (a nameserver from /etc/resolv.conf, dns_resolve_via). The static table and dotted
/// literals still answer first, as in resolve(); the shared cache is neither read nor written: an answer from a server one
/// caller chose must not reach other processes, and a cached answer would not have come from `server`.
pub fn resolveVia(hostname: []const u8, server: [4]u8, yield: Yield) [4]u8 {
    if (hostname.len == 0 or hostname.len > MAX_NAME) return .{ 0, 0, 0, 0 };
    if (@import("static_hosts.zig").lookup(hostname)) |ip| return ip;
    if (isIpV4(hostname)) return parseIpV4(hostname);
    return queryDnsCache(hostname, server, false, yield);
}

/// Send a DNS query and wait for response; the answer goes into the shared cache.
fn queryDns(hostname: []const u8, dns_server: [4]u8, yield: Yield) [4]u8 {
    return queryDnsCache(hostname, dns_server, true, yield);
}

/// Send a DNS query and wait for response, caching the answer only when `cache_result`.
fn queryDnsCache(hostname: []const u8, dns_server: [4]u8, cache_result: bool, yield: Yield) [4]u8 {
    var ans: dns_answer.Answer = .{};
    const r = queryCore(hostname, dns_server, dns_policy.QUERY_TIMEOUT_NS, yield, &ans);
    if (r.outcome != .answer) return .{ 0, 0, 0, 0 };
    // Default TTL 5 minutes.
    if (cache_result) addToCache(hostname, r.ip, 300);
    return r.ip;
}

/// How one query ended, with the address when it answered.
pub const Result = struct { outcome: dns_policy.Outcome, ip: [4]u8 = .{ 0, 0, 0, 0 } };

/// One query for `hostname` to `server`, waiting at most `timeout_ns` (dns_query, 507): what the reply said, for a resolver in
/// user space that applies resolv.conf's timeout, attempts and server order itself. Literals and the static table answer
/// first, as in resolveVia; the shared cache is neither read nor written.
/// `ans` receives every address of the reply and the CNAME chain (dns_answer), or the one address of a literal or static name.
pub fn queryVia(hostname: []const u8, server: [4]u8, timeout_ns: u64, yield: Yield, ans: *dns_answer.Answer) Result {
    if (hostname.len == 0 or hostname.len > MAX_NAME) return .{ .outcome = .nxdomain };
    const local: ?[4]u8 = @import("static_hosts.zig").lookup(hostname) orelse if (isIpV4(hostname)) parseIpV4(hostname) else null;
    if (local) |ip| {
        dns_answer.single(ans, hostname, ip);
        return .{ .outcome = .answer, .ip = ip };
    }
    return queryCore(hostname, server, timeout_ns, yield, ans);
}

/// A PTR query to `server` for `addr` (4 bytes IPv4 or 16 bytes IPv6), waiting at most `timeout_ns` (dns_ptr, 508): the host name
/// lands in ans.canonName(). The shared cache is not used.
pub fn queryPtr(addr: []const u8, server: [4]u8, timeout_ns: u64, yield: Yield, ans: *dns_answer.Answer) Result {
    var nb: [80]u8 = undefined;
    const qname = if (addr.len == 4) dns_answer.reverseName4(addr[0..4].*, &nb) else dns_answer.reverseName6(addr[0..16].*, &nb);
    return queryType(qname, server, timeout_ns, yield, ans, TYPE_PTR);
}

const TYPE_A_Q: u16 = 1;
const TYPE_PTR: u16 = 12;

fn queryCore(hostname: []const u8, dns_server: [4]u8, timeout_ns: u64, yield: Yield, ans: *dns_answer.Answer) Result {
    return queryType(hostname, dns_server, timeout_ns, yield, ans, TYPE_A_Q);
}

fn queryType(hostname: []const u8, dns_server: [4]u8, timeout_ns: u64, yield: Yield, ans: *dns_answer.Answer, qtype: u16) Result {
    var pkt: [512]u8 = @splat(0);
    var offset: usize = 0;

    // Register the reply port first — without it the UDP demux drops the
    // response before recvFrom can ever see it.
    // A port of its own for this query: two queries at once (two threads, two processes) must not take each other's replies.
    const src_port = udp.reserveEphemeral() orelse {
        serial.writeString("[DNS] Failed to register reply port\n");
        return .{ .outcome = .failed };
    };
    defer udp.releasePort(src_port);

    // DNS Header (big-endian / network byte order)
    const query_id = newQueryId();
    bo.writeU16BeAt(&pkt, 0, query_id); // id
    bo.writeU16BeAt(&pkt, 2, 0x0100); // flags: standard query, recursion desired
    bo.writeU16BeAt(&pkt, 4, 1); // qdcount
    // ancount, nscount, arcount already zero (@splat)
    offset += 12;

    // Question section: encode hostname as DNS name
    offset += encodeDnsName(hostname, pkt[offset..]);

    // Question type and class
    bo.writeU16BeAt(&pkt, offset, qtype); // TYPE_A or TYPE_PTR
    pkt[offset + 2] = 0x00;
    pkt[offset + 3] = 0x01; // CLASS_IN
    offset += 4;

    // Send query. udp.sendTo does not wait: with no ARP entry for the server it only broadcasts an ARP request
    // and returns false, so the first attempt on a cold ARP cache always fails. Pump the NIC so the reply is
    // processed and try again until the query goes out or the deadline passes.
    const send_start = tsc.nanos();
    var send_iters: u32 = 0;
    var sent = false;
    while (!sent and !dns_policy.waitExpiredAfter(send_start, tsc.nanos(), send_iters, timeout_ns)) : (send_iters += 1) {
        sent = udp.sendTo(dns_server, DNS_PORT, src_port, &pkt, @intCast(offset));
        if (sent) break;
        pumpRx();
        if (yield) |y| (if (!y()) return .{ .outcome = .interrupted }) else cpu.pause();
    }
    if (!sent) {
        serial.writeString("[DNS] Failed to send query\n");
        return .{ .outcome = .timeout };
    }

    // Wait for response
    const start = tsc.nanos();
    var wait_iters: u32 = 0;
    while (!dns_policy.waitExpiredAfter(start, tsc.nanos(), wait_iters, timeout_ns)) : (wait_iters += 1) {
        pumpRx(); // replies only reach the UDP queue when the NIC is polled
        var buf: [MAX_REPLY]u8 = undefined;
        var from_ip: [4]u8 = .{ 0, 0, 0, 0 };
        var from_port: u16 = 0;

        const n = udp.recvFrom(src_port, &buf, @intCast(buf.len), &from_ip, &from_port);
        if (n >= 12 and dns_policy.acceptResponse(from_ip, from_port, dns_server, bo.readU16BeAt(&buf, 0), query_id)) {
            // Any reply settles the query, without waiting out the limit for another: an error RCODE (NXDOMAIN, SERVFAIL, ...), a
            // reply with no answers (NODATA), or answers with no address for the name after following its CNAMEs (glibc's
            // NO_RECOVERY: `failed`).
            const o = dns_policy.classify(bo.readU16BeAt(&buf, 2), bo.readU16BeAt(&buf, 6));
            if (o != .ignore) {
                if (o != .answer) return .{ .outcome = o };
                if (qtype == TYPE_PTR) {
                    if (!dns_answer.parsePtr(buf[0..@intCast(n)], hostname, ans)) return .{ .outcome = .failed };
                    return .{ .outcome = .answer };
                }
                if (!dns_answer.parse(buf[0..@intCast(n)], hostname, ans)) return .{ .outcome = .failed };
                return .{ .outcome = .answer, .ip = ans.addrs[0] };
            }
        }
        if (yield) |y| (if (!y()) return .{ .outcome = .interrupted }) else cpu.pause();
    }

    serial.writeString("[DNS] Query timeout for ");
    serial.writeString(hostname);
    serial.writeString("\n");
    return .{ .outcome = .timeout };
}

/// Drain pending NIC RX frames into the network stack so replies reach the
/// UDP queue (mirrors the netPoll loop in socket_syscall.zig).
fn pumpRx() void {
    const nic = @import("nic.zig");
    if (!nic.isActive()) return;
    const net_mod = @import("mod.zig");
    var rx_tmp: [2048]u8 = undefined;
    var poll_limit: u32 = 0;
    while (poll_limit < 16) {
        const n = nic.receivePacket(&rx_tmp, 2048);
        if (n == 0) break;
        net_mod.handleRxPacket(&rx_tmp, n);
        poll_limit += 1;
    }
}

/// Encode a hostname into DNS name format (length-prefixed labels).
fn encodeDnsName(hostname: []const u8, buf: []u8) usize {
    var offset: usize = 0;
    var label_start: usize = 0;

    for (0..hostname.len + 1) |i| {
        if (i == hostname.len or hostname[i] == '.') {
            const label_len = i - label_start;
            if (label_len > 0 and label_len <= 63 and offset + 1 + label_len <= buf.len) {
                buf[offset] = @intCast(label_len);
                offset += 1;
                @memcpy(buf[offset..][0..label_len], hostname[label_start..i]);
                offset += label_len;
            }
            label_start = i + 1;
        }
    }

    // Terminating zero-length label
    if (offset < buf.len) {
        buf[offset] = 0;
        offset += 1;
    }

    return offset;
}

/// Check if a string is a dotted decimal IPv4 address.
fn isIpV4(s: []const u8) bool {
    var dot_count: u8 = 0;
    for (s) |c| {
        if (c == '.') {
            dot_count += 1;
        } else if (c < '0' or c > '9') {
            return false;
        }
    }
    return dot_count == 3;
}

/// Parse a dotted decimal IPv4 address string.
/// Returns .{0,0,0,0} for malformed input (octet > 255 or too many octets).
fn parseIpV4(s: []const u8) [4]u8 {
    var ip: [4]u8 = .{ 0, 0, 0, 0 };
    var idx: u8 = 0;
    var val: u32 = 0; // u32 accumulator: u8 would overflow-panic on "999..."

    for (s) |c| {
        if (c == '.') {
            if (val > 255 or idx >= 4) return .{ 0, 0, 0, 0 };
            ip[idx] = @intCast(val);
            idx += 1;
            val = 0;
        } else if (c >= '0' and c <= '9') {
            val = val * 10 + (c - '0');
            // Reject early so a long digit run cannot overflow the u32.
            if (val > 255) return .{ 0, 0, 0, 0 };
        } else {
            return .{ 0, 0, 0, 0 };
        }
    }
    if (val > 255 or idx >= 4) return .{ 0, 0, 0, 0 };
    ip[idx] = @intCast(val);

    return ip;
}

/// Look up hostname in the cache.
fn lookupCache(hostname: []const u8) ?[4]u8 {
    const now = idt.getTickCount();

    for (0..DNS_CACHE_SIZE) |i| {
        if (!cache[i].valid) continue;
        if (cache[i].name_len != hostname.len) continue;
        var name_match = true;
        for (cache[i].name[0..hostname.len], hostname) |a, b| {
            if (a != b) {
                name_match = false;
                break;
            }
        }
        if (name_match) {
            // Check TTL
            if (now > cache[i].ttl) {
                cache[i].valid = false; // Expired
                continue;
            }
            cache[i].last_used = now;
            return cache[i].ip;
        }
    }
    return null;
}

/// Add a hostname → IP mapping to the cache.
fn addToCache(hostname: []const u8, ip: [4]u8, ttl_seconds: u32) void {
    const now = idt.getTickCount();
    const expiry = now + ttl_seconds * 100; // Approximate: 100 ticks/sec

    // Find free slot or evict LRU
    var slot: ?u32 = null;
    var oldest: u64 = @constCast(&now).*; // Just use max value
    oldest = 0xFFFFFFFFFFFFFFFF;

    for (0..DNS_CACHE_SIZE) |i| {
        if (!cache[i].valid) {
            slot = @intCast(i);
            break;
        }
        if (cache[i].last_used < oldest) {
            oldest = cache[i].last_used;
            slot = @intCast(i);
        }
    }

    const s = slot orelse return;
    @memset(&cache[s].name, 0);
    @memcpy(cache[s].name[0..hostname.len], hostname);
    cache[s].name_len = @intCast(hostname.len);
    cache[s].ip = ip;
    cache[s].ttl = expiry;
    cache[s].valid = true;
    cache[s].last_used = now;
}
