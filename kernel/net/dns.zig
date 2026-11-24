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

/// A nameserver: IPv4, or IPv6 (/etc/resolv.conf "nameserver ::1"; glibc asks it over IPv6, measured).
pub const Server = union(enum) { v4: [4]u8, v6: [16]u8 };

/// How one query ended, with the address when it answered.
pub const Result = struct { outcome: dns_policy.Outcome, ip: [4]u8 = .{ 0, 0, 0, 0 } };

/// One query for `hostname` to `server`, waiting at most `timeout_ns` (dns_query, 507): what the reply said, for a resolver in
/// user space that applies resolv.conf's timeout, attempts and server order itself. Literals and the static table answer
/// first, as in resolveVia; the shared cache is neither read nor written.
/// `ans` receives every address of the reply and the CNAME chain (dns_answer), or the one address of a literal or static name.
pub fn queryVia(hostname: []const u8, server: Server, timeout_ns: u64, yield: Yield, ans: *dns_answer.Answer) Result {
    if (hostname.len == 0 or hostname.len > MAX_NAME) return .{ .outcome = .nxdomain };
    const local: ?[4]u8 = @import("static_hosts.zig").lookup(hostname) orelse if (isIpV4(hostname)) parseIpV4(hostname) else null;
    if (local) |ip| {
        dns_answer.single(ans, hostname, ip);
        return .{ .outcome = .answer, .ip = ip };
    }
    return queryType(hostname, server, timeout_ns, yield, ans, TYPE_A_Q);
}

/// queryVia for AAAA records (dns_query6, 509): every IPv6 address of the reply lands in `ans` (alen 16). An IPv4 literal or a static
/// name has no AAAA record: NODATA, as for a name that exists without one.
pub fn queryVia6(hostname: []const u8, server: Server, timeout_ns: u64, yield: Yield, ans: *dns_answer.Answer) Result {
    if (hostname.len == 0 or hostname.len > MAX_NAME) return .{ .outcome = .nxdomain };
    if (@import("static_hosts.zig").lookup(hostname) != null or isIpV4(hostname)) return .{ .outcome = .nodata };
    return queryType(hostname, server, timeout_ns, yield, ans, TYPE_AAAA);
}

/// A PTR query to `server` for `addr` (4 bytes IPv4 or 16 bytes IPv6), waiting at most `timeout_ns` (dns_ptr, 508): the host name
/// lands in ans.canonName(). The shared cache is not used.
pub fn queryPtr(addr: []const u8, server: Server, timeout_ns: u64, yield: Yield, ans: *dns_answer.Answer) Result {
    var nb: [80]u8 = undefined;
    const qname = if (addr.len == 4) dns_answer.reverseName4(addr[0..4].*, &nb) else dns_answer.reverseName6(addr[0..16].*, &nb);
    return queryType(qname, server, timeout_ns, yield, ans, TYPE_PTR);
}

/// The A and AAAA queries for `hostname` sent back to back from one port to `server`, as glibc 2.44 sends an AF_UNSPEC lookup's
/// pair (measured), waiting at most `timeout_ns` for both replies: how each ended, the A half first. A truncated reply asks that
/// half again over TCP. Literals and static names answer the A half and are NODATA for AAAA, without a query.
pub fn queryPair(hostname: []const u8, server: Server, timeout_ns: u64, yield: Yield, ans4: *dns_answer.Answer, ans6: *dns_answer.Answer) [2]dns_policy.Outcome {
    if (hostname.len == 0 or hostname.len > MAX_NAME) return .{ .nxdomain, .nxdomain };
    const local: ?[4]u8 = @import("static_hosts.zig").lookup(hostname) orelse if (isIpV4(hostname)) parseIpV4(hostname) else null;
    if (local) |ip| {
        dns_answer.single(ans4, hostname, ip);
        return .{ .answer, .nodata };
    }
    var out: [2]dns_policy.Outcome = .{ .timeout, .timeout };
    var done = [2]bool{ false, false };
    const qtypes = [2]u16{ TYPE_A_Q, TYPE_AAAA };
    const answers = [2]*dns_answer.Answer{ ans4, ans6 };
    const src_port = udp.reserveEphemeralFor(server == .v6) orelse return .{ .failed, .failed };
    defer udp.releasePort(src_port);
    const ids = [2]u16{ newQueryId(), newQueryId() };
    var pkts: [2][512]u8 = undefined;
    var lens: [2]usize = undefined;
    for (0..2) |k| lens[k] = buildQuery(&pkts[k], hostname, qtypes[k], ids[k]);
    // Both go out before any reply is read (see queryUdp for why a send is retried).
    const send_start = tsc.nanos();
    var send_iters: u32 = 0;
    var sent = [2]bool{ false, false };
    while (!(sent[0] and sent[1]) and !dns_policy.waitExpiredAfter(send_start, tsc.nanos(), send_iters, timeout_ns)) : (send_iters += 1) {
        for (0..2) |k| {
            if (sent[k]) continue;
            sent[k] = switch (server) {
                .v4 => |s4| udp.sendTo(s4, DNS_PORT, src_port, &pkts[k], @intCast(lens[k])),
                .v6 => |s6| udp.sendToV6(s6, DNS_PORT, src_port, &pkts[k], @intCast(lens[k])),
            };
        }
        if (sent[0] and sent[1]) break;
        pumpRx();
        if (yield) |y| (if (!y()) return .{ .interrupted, .interrupted }) else cpu.pause();
    }
    if (!(sent[0] and sent[1])) return .{ .timeout, .timeout };
    const start = tsc.nanos();
    var wait_iters: u32 = 0;
    while (!(done[0] and done[1]) and !dns_policy.waitExpiredAfter(start, tsc.nanos(), wait_iters, timeout_ns)) : (wait_iters += 1) {
        pumpRx();
        var buf: [MAX_REPLY]u8 = undefined;
        var from_ip: [4]u8 = .{ 0, 0, 0, 0 };
        var from6: [16]u8 = @splat(0);
        var from_port: u16 = 0;
        var full: u16 = 0;
        const n = switch (server) {
            .v4 => udp.recvFrom(src_port, &buf, @intCast(buf.len), &from_ip, &from_port),
            .v6 => udp.recvFromV6Ex(src_port, &buf, @intCast(buf.len), &from6, &from_port, &full, false),
        };
        if (n >= 12) {
            const id = bo.readU16BeAt(&buf, 0);
            for (0..2) |k| {
                if (done[k]) continue;
                const accepted = switch (server) {
                    .v4 => |s4| dns_policy.acceptResponse(from_ip, from_port, s4, id, ids[k]),
                    .v6 => |s6| dns_policy.acceptResponse6(from6, from_port, s6, id, ids[k]),
                };
                if (!accepted) continue;
                if (readReply(buf[0..@intCast(n)], hostname, qtypes[k], answers[k])) |res| {
                    out[k] = res.outcome;
                    done[k] = true;
                }
            }
            continue; // another datagram may be queued
        }
        if (yield) |y| (if (!y()) return .{ if (done[0]) out[0] else .interrupted, if (done[1]) out[1] else .interrupted }) else cpu.pause();
    }
    for (0..2) |k| {
        if (out[k] == .truncated) out[k] = queryTcp(hostname, server, timeout_ns, yield, answers[k], qtypes[k]).outcome;
    }
    return out;
}

const TYPE_A_Q: u16 = 1;
const TYPE_PTR: u16 = 12;
const TYPE_AAAA: u16 = 28;

fn queryCore(hostname: []const u8, dns_server: [4]u8, timeout_ns: u64, yield: Yield, ans: *dns_answer.Answer) Result {
    return queryType(hostname, .{ .v4 = dns_server }, timeout_ns, yield, ans, TYPE_A_Q);
}

fn queryType(hostname: []const u8, dns_server: Server, timeout_ns: u64, yield: Yield, ans: *dns_answer.Answer, qtype: u16) Result {
    const r = queryUdp(hostname, dns_server, timeout_ns, yield, ans, qtype);
    // A truncated reply is not used: the same query goes to the same server over TCP (glibc res_send, measured).
    if (r.outcome == .truncated) return queryTcp(hostname, dns_server, timeout_ns, yield, ans, qtype);
    return r;
}

/// The question for `hostname`/`qtype` with id `query_id` into `pkt`; its length.
fn buildQuery(pkt: []u8, hostname: []const u8, qtype: u16, query_id: u16) usize {
    @memset(pkt[0..12], 0);
    bo.writeU16BeAt(pkt.ptr, 0, query_id); // id
    bo.writeU16BeAt(pkt.ptr, 2, 0x0100); // flags: standard query, recursion desired
    bo.writeU16BeAt(pkt.ptr, 4, 1); // qdcount
    var offset: usize = 12;
    offset += encodeDnsName(hostname, pkt[offset..]);
    bo.writeU16BeAt(pkt.ptr, offset, qtype); // TYPE_A, TYPE_PTR or TYPE_AAAA
    pkt[offset + 2] = 0x00;
    pkt[offset + 3] = 0x01; // CLASS_IN
    return offset + 4;
}

/// What an accepted reply `msg` says for `hostname`/`qtype`: an error RCODE, NODATA, truncation, or the answer (into `ans`); a
/// reply with answers but no address for the name after its CNAMEs is glibc's NO_RECOVERY (`failed`). null: not a response.
fn readReply(msg: []const u8, hostname: []const u8, qtype: u16, ans: *dns_answer.Answer) ?Result {
    const o = dns_policy.classify(bo.readU16BeAt(msg.ptr, 2), bo.readU16BeAt(msg.ptr, 6));
    if (o == .ignore) return null;
    if (o != .answer) return .{ .outcome = o };
    if (qtype == TYPE_PTR) {
        if (!dns_answer.parsePtr(msg, hostname, ans)) return .{ .outcome = .failed };
        return .{ .outcome = .answer };
    }
    if (!dns_answer.parseType(msg, hostname, qtype, ans)) return .{ .outcome = .failed };
    return .{ .outcome = .answer, .ip = ans.addrs[0][0..4].* };
}

/// The query over TCP to `dns_server`:53 (RFC 1035 4.2.2: a 2-byte length, then the message), waiting at most `timeout_ns` for the
/// connection and the whole reply. A refused, reset or closed connection is `tcp_failed`.
fn queryTcp(hostname: []const u8, dns_server: Server, timeout_ns: u64, yield: Yield, ans: *dns_answer.Answer, qtype: u16) Result {
    const tcp = @import("tcp.zig");
    const sched = @import("../proc/sched.zig");
    var pkt: [2 + 512]u8 = undefined;
    const query_id = newQueryId();
    const qlen = buildQuery(pkt[2..], hostname, qtype, query_id);
    dns_policy.tcpLength(&pkt, @intCast(qlen));
    const owner = sched.currentTaskIndex() orelse 0;
    const idx: u32 = switch (dns_server) {
        .v4 => |s4| blk: {
            const raw = tcp.tcpConnect(s4, DNS_PORT, owner);
            if (raw < 0) return .{ .outcome = .tcp_failed };
            break :blk @intCast(raw);
        },
        .v6 => |s6| blk: {
            const raw = tcp.tcpSocket(owner);
            if (raw < 0) return .{ .outcome = .tcp_failed };
            const i: u32 = @intCast(raw);
            if (tcp.tcpSetIpv6(i) != 0 or tcp.tcpConnectSocketV6(i, s6, DNS_PORT) != 0) {
                _ = tcp.tcpClose(i);
                return .{ .outcome = .tcp_failed };
            }
            break :blk i;
        },
    };
    defer _ = tcp.tcpClose(idx);
    const start = tsc.nanos();
    var iters: u32 = 0;
    var sent: usize = 0;
    var buf: [2 + MAX_REPLY]u8 = undefined;
    var got: usize = 0;
    while (!dns_policy.waitExpiredAfter(start, tsc.nanos(), iters, timeout_ns)) : (iters += 1) {
        pumpRx();
        _ = @import("lo.zig").drain();
        const st = tcp.tcpPoll(idx);
        if (st < 0) return .{ .outcome = .tcp_failed }; // refused or reset
        if (st == 1 and sent < 2 + qlen) {
            const w = tcp.tcpSend(idx, pkt[sent..].ptr, @intCast(2 + qlen - sent));
            if (w < 0) return .{ .outcome = .tcp_failed };
            sent += @intCast(w);
            _ = @import("lo.zig").drain();
        }
        if (sent == 2 + qlen) {
            const r = tcp.tcpRecv(idx, buf[got..].ptr, @intCast(buf.len - got));
            if (r > 0) {
                got += @intCast(r);
                if (dns_policy.tcpFrameComplete(buf[0..got])) {
                    const n = dns_policy.tcpFrameLen(buf[0..got]).?;
                    const msg = buf[2 .. 2 + n];
                    if (n < 12 or bo.readU16BeAt(msg.ptr, 0) != query_id) return .{ .outcome = .failed };
                    if (readReply(msg, hostname, qtype, ans)) |res| {
                        // A truncated TCP reply has nowhere further to go.
                        return if (res.outcome == .truncated) .{ .outcome = .failed } else res;
                    }
                    return .{ .outcome = .failed };
                }
                if (got == buf.len) return .{ .outcome = .failed }; // longer than we read
                continue;
            }
            if (r == 0) return .{ .outcome = .tcp_failed }; // closed before the whole reply
            if (r != -11) return .{ .outcome = .tcp_failed };
        }
        if (yield) |y| (if (!y()) return .{ .outcome = .interrupted }) else cpu.pause();
    }
    return .{ .outcome = .timeout };
}

fn queryUdp(hostname: []const u8, dns_server: Server, timeout_ns: u64, yield: Yield, ans: *dns_answer.Answer, qtype: u16) Result {
    var pkt: [512]u8 = @splat(0);
    var offset: usize = 0;

    // Register the reply port first — without it the UDP demux drops the
    // response before recvFrom can ever see it.
    // A port of its own for this query: two queries at once (two threads, two processes) must not take each other's replies.
    const src_port = udp.reserveEphemeralFor(dns_server == .v6) orelse {
        serial.writeString("[DNS] Failed to register reply port\n");
        return .{ .outcome = .failed };
    };
    defer udp.releasePort(src_port);

    const query_id = newQueryId();
    offset = buildQuery(&pkt, hostname, qtype, query_id);

    // Send query. udp.sendTo does not wait: with no ARP entry for the server it only broadcasts an ARP request
    // and returns false, so the first attempt on a cold ARP cache always fails. Pump the NIC so the reply is
    // processed and try again until the query goes out or the deadline passes.
    const send_start = tsc.nanos();
    var send_iters: u32 = 0;
    var sent = false;
    while (!sent and !dns_policy.waitExpiredAfter(send_start, tsc.nanos(), send_iters, timeout_ns)) : (send_iters += 1) {
        sent = switch (dns_server) {
            .v4 => |s4| udp.sendTo(s4, DNS_PORT, src_port, &pkt, @intCast(offset)),
            .v6 => |s6| udp.sendToV6(s6, DNS_PORT, src_port, &pkt, @intCast(offset)),
        };
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
        var from6: [16]u8 = @splat(0);
        var from_port: u16 = 0;
        var full: u16 = 0;
        const n = switch (dns_server) {
            .v4 => udp.recvFrom(src_port, &buf, @intCast(buf.len), &from_ip, &from_port),
            .v6 => udp.recvFromV6Ex(src_port, &buf, @intCast(buf.len), &from6, &from_port, &full, false),
        };
        const accepted = n >= 12 and switch (dns_server) {
            .v4 => |s4| dns_policy.acceptResponse(from_ip, from_port, s4, bo.readU16BeAt(&buf, 0), query_id),
            .v6 => |s6| dns_policy.acceptResponse6(from6, from_port, s6, bo.readU16BeAt(&buf, 0), query_id),
        };
        if (accepted) {
            // Any reply settles the query, without waiting out the limit for another.
            if (readReply(buf[0..@intCast(n)], hostname, qtype, ans)) |res| return res;
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
