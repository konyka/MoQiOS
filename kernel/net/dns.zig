/// DNS Resolver — Domain Name System query/resolution.
///
/// Implements:
///   - DNS A record queries (IPv4)
///   - Response parsing with header, question, answer sections
///   - Simple 16-entry LRU cache with TTL expiry
///   - Kernel API: dnsResolve(hostname) → [4]u8
const serial = @import("../arch/x86_64/serial.zig");
const udp = @import("udp.zig");
const netif = @import("netif.zig");
const idt = @import("../arch/x86_64/idt.zig");
const bo = @import("../lib/byte_order.zig");

const DNS_PORT: u16 = 53;
const DNS_CACHE_SIZE: u32 = 16;
const DNS_QUERY_TIMEOUT: u64 = 200; // ticks (~2 seconds)

// DNS record types
const TYPE_A: u16 = 1;
const CLASS_IN: u16 = 1;

/// DNS cache entry
const DnsCacheEntry = struct {
    name: [64]u8,
    name_len: u8,
    ip: [4]u8,
    ttl: u32, // Expiry tick count
    valid: bool = false,
    last_used: u64 = 0, // For LRU eviction
};

var cache: [DNS_CACHE_SIZE]DnsCacheEntry = @splat(.{
    .name = @splat(0),
    .name_len = 0,
    .ip = .{ 0, 0, 0, 0 },
    .ttl = 0,
});
var query_id: u16 = 0x1234;

/// Resolve a hostname to an IPv4 address.
/// Returns [4]u8 on success, or .{0,0,0,0} on failure.
/// Checks cache first, then sends DNS query.
pub fn resolve(hostname: []const u8) [4]u8 {
    if (hostname.len == 0 or hostname.len > 63) return .{ 0, 0, 0, 0 };

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
                return queryDns(hostname, dhcp_dns);
            }
        }
        // Fallback to Google DNS
        return queryDns(hostname, .{ 8, 8, 8, 8 });
    }

    return queryDns(hostname, dns_server);
}

/// Get the DNS server address (from DHCP or default).
pub fn getDnsServer() [4]u8 {
    const dhcp = @import("dhcp.zig");
    if (dhcp.isConfigured()) {
        return dhcp.getDnsServer();
    }
    return .{ 8, 8, 8, 8 }; // Default: Google DNS
}

/// Send a DNS query and wait for response.
fn queryDns(hostname: []const u8, dns_server: [4]u8) [4]u8 {
    var pkt: [512]u8 = @splat(0);
    var offset: usize = 0;

    // DNS Header (big-endian / network byte order)
    bo.writeU16BeAt(&pkt, 0, query_id); // id
    query_id +%= 1;
    bo.writeU16BeAt(&pkt, 2, 0x0100); // flags: standard query, recursion desired
    bo.writeU16BeAt(&pkt, 4, 1); // qdcount
    // ancount, nscount, arcount already zero (@splat)
    offset += 12;

    // Question section: encode hostname as DNS name
    offset += encodeDnsName(hostname, pkt[offset..]);

    // Question type and class
    pkt[offset] = 0x00;
    pkt[offset + 1] = 0x01; // TYPE_A
    pkt[offset + 2] = 0x00;
    pkt[offset + 3] = 0x01; // CLASS_IN
    offset += 4;

    // Send query
    const sent = udp.sendTo(dns_server, DNS_PORT, 12345, &pkt, @intCast(offset));
    if (!sent) {
        serial.writeString("[DNS] Failed to send query\n");
        return .{ 0, 0, 0, 0 };
    }

    // Wait for response
    const start = idt.getTickCount();
    while (idt.getTickCount() - start < DNS_QUERY_TIMEOUT) {
        var buf: [512]u8 = @splat(0);
        var src_ip: [4]u8 = .{ 0, 0, 0, 0 };
        var src_port: u16 = 0;

        const n = udp.recvFrom(12345, &buf, &src_ip, &src_port);
        if (n > 0 and src_port == DNS_PORT) {
            const resp_id = bo.readU16BeAt(&buf, 0);
            const result = parseResponse(&buf, @intCast(n), resp_id);
            if (result[0] != 0 or result[1] != 0 or result[2] != 0 or result[3] != 0) {
                // Cache the result
                addToCache(hostname, result, 300); // Default TTL 5 minutes
                return result;
            }
        }
        asm volatile ("pause");
    }

    serial.writeString("[DNS] Query timeout for ");
    serial.writeString(hostname);
    serial.writeString("\n");
    return .{ 0, 0, 0, 0 };
}

/// Parse DNS response, extract first A record answer.
fn parseResponse(data: [*]const u8, len: u16, expected_id: u16) [4]u8 {
    if (len < 12) return .{ 0, 0, 0, 0 };

    // Read DNS header fields in big-endian
    const resp_id = bo.readU16BeAt(data, 0);
    const flags = bo.readU16BeAt(data, 2);
    const qdcount = bo.readU16BeAt(data, 4);
    const ancount = bo.readU16BeAt(data, 6);

    // Verify ID matches
    if (resp_id != expected_id) return .{ 0, 0, 0, 0 };

    // Check for response (QR bit = 1) and no error (RCODE = 0)
    if ((flags & 0x8000) == 0) return .{ 0, 0, 0, 0 }; // Not a response
    if ((flags & 0x000F) != 0) return .{ 0, 0, 0, 0 }; // Error

    if (ancount == 0) return .{ 0, 0, 0, 0 };

    var offset: usize = 12;

    // Skip question section
    for (0..qdcount) |_| {
        offset = skipName(data, len, offset);
        if (offset + 4 > len) return .{ 0, 0, 0, 0 };
        offset += 4; // QTYPE + QCLASS
    }

    // Parse answer section
    for (0..ancount) |_| {
        offset = skipName(data, len, offset);
        if (offset + 10 > len) return .{ 0, 0, 0, 0 };

        const atype = bo.readU16BeAt(data, offset);
        const aclass = bo.readU16BeAt(data, offset + 2);
        // const attl = bo.readU32BeAt(data, offset + 4);
        const rdlength = bo.readU16BeAt(data, offset + 8);
        offset += 10;

        if (atype == TYPE_A and aclass == CLASS_IN and rdlength == 4) {
            if (offset + 4 > len) return .{ 0, 0, 0, 0 };
            return .{ data[offset], data[offset + 1], data[offset + 2], data[offset + 3] };
        }

        offset += rdlength;
    }

    return .{ 0, 0, 0, 0 };
}

/// Skip a DNS name (handles compression pointers).
fn skipName(data: [*]const u8, len: u16, start: usize) usize {
    var offset = start;
    while (offset < len) {
        const b = data[offset];
        if (b == 0) {
            offset += 1;
            break;
        }
        if ((b & 0xC0) == 0xC0) {
            // Compression pointer
            offset += 2;
            break;
        }
        offset += 1 + @as(usize, b); // label length + label
    }
    return offset;
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
fn parseIpV4(s: []const u8) [4]u8 {
    var ip: [4]u8 = .{ 0, 0, 0, 0 };
    var idx: u8 = 0;
    var val: u8 = 0;

    for (s) |c| {
        if (c == '.') {
            if (idx < 4) ip[idx] = val;
            idx += 1;
            val = 0;
        } else if (c >= '0' and c <= '9') {
            val = val * 10 + (c - '0');
        }
    }
    if (idx < 4) ip[idx] = val;

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
    @memset(cache[s].name[0..64], 0);
    @memcpy(cache[s].name[0..hostname.len], hostname);
    cache[s].name_len = @intCast(hostname.len);
    cache[s].ip = ip;
    cache[s].ttl = expiry;
    cache[s].valid = true;
    cache[s].last_used = now;
}
