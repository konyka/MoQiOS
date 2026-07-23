// kernel/net/ipv6.zig — IPv6 core header build/parse + pseudo-header checksum
//
// IPv6 header is fixed at 40 bytes (no IHL like IPv4). There is no header
// checksum: integrity is delegated to upper-layer protocols (TCP/UDP/ICMPv6),
// all of which include an IPv6 pseudo-header in their checksum computation.

const bo = @import("../lib/byte_order.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const netif = @import("netif.zig");

pub const PROTO_ICMPV6: u8 = 58;
pub const PROTO_TCP: u8 = 6;
pub const PROTO_UDP: u8 = 17;

/// Fixed IPv6 header length in bytes.
pub const HEADER_LEN: u16 = 40;
/// IPv6 minimum link MTU (RFC 8200).
pub const MIN_MTU: u16 = 1280;
/// Ethernet link MTU used as the default Path MTU.
pub const LINK_MTU: u16 = 1500;
/// How long a learned Path MTU stays without refresh (seconds) (SK-97).
pub const PMTU_LIFETIME_SEC: u32 = 600;
pub const MAX_PMTU_ENTRIES: u32 = 8;

/// Default Hop Limit for outbound packets (analogous to IPv4 TTL=64).
pub const DEFAULT_HOP_LIMIT: u8 = 64;

pub const Ipv6Info = struct {
    src_ip: [16]u8,
    dst_ip: [16]u8,
    next_header: u8,
    hop_limit: u8,
    payload_offset: u16, // always 40 for fixed header
    payload_len: u16,
};

/// Build a fixed 40-byte IPv6 header at `buf`.
/// Layout (RFC 8200):
///   Byte  0      : Version(4) | Traffic Class hi(4)
///   Byte  1      : Traffic Class lo(4) | Flow Label hi(4)
///   Bytes 2..3   : Flow Label lo(16)
///   Bytes 4..5   : Payload Length (u16 BE)
///   Byte  6      : Next Header
///   Byte  7      : Hop Limit
///   Bytes 8..23  : Source Address (16)
///   Bytes 24..39 : Destination Address (16)
pub fn buildHeader(
    buf: [*]u8,
    src_ip: [16]u8,
    dst_ip: [16]u8,
    next_header: u8,
    payload_len: u16,
) void {
    // Version=6, Traffic Class=0, Flow Label=0
    buf[0] = 0x60;
    buf[1] = 0x00;
    buf[2] = 0x00;
    buf[3] = 0x00;

    bo.writeU16BeAt(buf, 4, payload_len);
    buf[6] = next_header;
    buf[7] = DEFAULT_HOP_LIMIT;

    @memcpy(buf[8..24], &src_ip);
    @memcpy(buf[24..40], &dst_ip);
}

/// Parse a fixed IPv6 header. Returns null when version != 6.
pub fn parseHeader(data: [*]const u8) ?Ipv6Info {
    const version = (data[0] >> 4) & 0xF;
    if (version != 6) return null;

    var info: Ipv6Info = .{
        .src_ip = undefined,
        .dst_ip = undefined,
        .next_header = data[6],
        .hop_limit = data[7],
        .payload_offset = HEADER_LEN,
        .payload_len = bo.readU16BeAt(data, 4),
    };

    inline for (0..16) |i| info.src_ip[i] = data[8 + i];
    inline for (0..16) |i| info.dst_ip[i] = data[24 + i];

    return info;
}

/// Compute the IPv6 pseudo-header partial checksum (RFC 8200 §8.1).
///
/// The pseudo-header consists of:
///   - 16 bytes source address
///   - 16 bytes destination address
///   - 4 bytes upper-layer packet length (zero-extended payload_len)
///   - 3 zero bytes
///   - 1 byte next header
///
/// This returns the *unfolded* 32-bit accumulator so callers can keep summing
/// the actual TCP/UDP/ICMPv6 payload before final folding (~sum) at the end.
pub fn pseudoHeaderChecksum(
    src: [16]u8,
    dst: [16]u8,
    next_header: u8,
    payload_len: u16,
) u32 {
    var acc: u64 = 0;

    // Both addresses as 8 × u16 big-endian words.
    var i: usize = 0;
    while (i < 16) : (i += 2) {
        acc += (@as(u64, src[i]) << 8) | @as(u64, src[i + 1]);
    }
    i = 0;
    while (i < 16) : (i += 2) {
        acc += (@as(u64, dst[i]) << 8) | @as(u64, dst[i + 1]);
    }

    // Upper-layer packet length is a u32 in the pseudo-header.
    acc += @as(u64, payload_len);

    // Next header occupies the low byte of the final 32-bit word.
    acc += @as(u64, next_header);

    // Fold to 32 bits but DO NOT take complement — caller continues summing.
    var sum: u32 = @truncate(acc);
    sum +|= @as(u32, @truncate(acc >> 32));
    return sum;
}

/// Check whether an IPv6 address is the all-zero unspecified address (::).
pub fn isUnspecified(addr: [16]u8) bool {
    for (addr) |b| if (b != 0) return false;
    return true;
}

/// Check whether an IPv6 address is link-local (fe80::/10).
pub fn isLinkLocal(addr: [16]u8) bool {
    return addr[0] == 0xFE and (addr[1] & 0xC0) == 0x80;
}

/// Check whether an IPv6 address is multicast (ff00::/8).
pub fn isMulticast(addr: [16]u8) bool {
    return addr[0] == 0xFF;
}

/// Check whether an IPv6 address is the solicited-node multicast for the
/// given target unicast address (ff02::1:ff00:0/104 + low 24 bits of target).
pub fn isSolicitedNodeMulticast(addr: [16]u8, target: [16]u8) bool {
    if (addr[0] != 0xFF or addr[1] != 0x02) return false;
    if (addr[11] != 0x01 or addr[12] != 0xFF) return false;
    return addr[13] == target[13] and addr[14] == target[14] and addr[15] == target[15];
}

/// Build the solicited-node multicast address for a unicast target.
pub fn solicitedNodeMulticast(target: [16]u8) [16]u8 {
    var out: [16]u8 = @splat(0);
    out[0] = 0xFF;
    out[1] = 0x02;
    out[11] = 0x01;
    out[12] = 0xFF;
    out[13] = target[13];
    out[14] = target[14];
    out[15] = target[15];
    return out;
}

/// All-routers link-local multicast (ff02::2) — Router Solicitation dest (SK-82).
pub fn allRoutersLinkLocalMulticast() [16]u8 {
    var out: [16]u8 = @splat(0);
    out[0] = 0xFF;
    out[1] = 0x02;
    out[15] = 0x02;
    return out;
}

/// True when `addr` matches `prefix`/`prefix_len` (SK-83 on-link checks).
pub fn prefixMatch(addr: [16]u8, prefix: [16]u8, prefix_len: u8) bool {
    if (prefix_len > 128) return false;
    if (prefix_len == 0) return true;
    const full_bytes: usize = prefix_len / 8;
    const rem_bits: u3 = @intCast(prefix_len % 8);
    var i: usize = 0;
    while (i < full_bytes) : (i += 1) {
        if (addr[i] != prefix[i]) return false;
    }
    if (rem_bits == 0) return true;
    const mask: u8 = @as(u8, 0xFF) << @intCast(8 - @as(u8, rem_bits));
    return (addr[full_bytes] & mask) == (prefix[full_bytes] & mask);
}

/// Compare two IPv6 addresses for equality.
pub inline fn addrEq(a: [16]u8, b: [16]u8) bool {
    for (0..16) |i| if (a[i] != b[i]) return false;
    return true;
}

/// Map an IPv6 multicast address to its Ethernet MAC (RFC 2464 §7):
/// `33:33` + the low 32 bits of the IPv6 address.
pub fn multicastMac(addr: [16]u8) [6]u8 {
    return .{ 0x33, 0x33, addr[12], addr[13], addr[14], addr[15] };
}

// ── SK-97: Path MTU cache (ICMPv6 Packet Too Big) ─────────────────────────
const PmtuEntry = struct {
    dst: [16]u8 = @splat(0),
    mtu: u16 = LINK_MTU,
    lifetime_sec: u32 = 0,
    age_ms: u32 = 0,
    valid: bool = false,
};
var pmtu_table: [MAX_PMTU_ENTRIES]PmtuEntry = @splat(.{});
var pmtu_lock: IrqSpinlock = .{};

/// Clear the Path MTU cache (called from net.init).
pub fn initPmtu() void {
    const flags = pmtu_lock.acquire();
    defer pmtu_lock.release(flags);
    for (0..MAX_PMTU_ENTRIES) |i| {
        pmtu_table[i] = .{};
    }
}

fn clampMtu(reported: u32) u16 {
    const cap = netif.getMtu();
    if (reported < MIN_MTU) return MIN_MTU;
    if (reported > cap) return cap;
    return @intCast(reported);
}

/// Lower (or install) Path MTU for `dst` from a Packet Too Big (SK-97).
pub fn updatePathMtu(dst: [16]u8, reported_mtu: u32) void {
    const mtu = clampMtu(reported_mtu);
    const flags = pmtu_lock.acquire();
    defer pmtu_lock.release(flags);
    for (0..MAX_PMTU_ENTRIES) |i| {
        const e = &pmtu_table[i];
        if (e.valid and addrEq(e.dst, dst)) {
            if (mtu < e.mtu) e.mtu = mtu;
            e.lifetime_sec = PMTU_LIFETIME_SEC;
            e.age_ms = 0;
            return;
        }
    }
    for (0..MAX_PMTU_ENTRIES) |i| {
        const e = &pmtu_table[i];
        if (!e.valid) {
            e.* = .{
                .dst = dst,
                .mtu = mtu,
                .lifetime_sec = PMTU_LIFETIME_SEC,
                .age_ms = 0,
                .valid = true,
            };
            return;
        }
    }
    pmtu_table[0] = .{
        .dst = dst,
        .mtu = mtu,
        .lifetime_sec = PMTU_LIFETIME_SEC,
        .age_ms = 0,
        .valid = true,
    };
}

/// Current Path MTU for `dst`, or interface MTU when unknown (SK-97/102).
pub fn getPathMtu(dst: [16]u8) u16 {
    const if_mtu = netif.getMtu();
    const flags = pmtu_lock.acquire();
    defer pmtu_lock.release(flags);
    for (0..MAX_PMTU_ENTRIES) |i| {
        const e = &pmtu_table[i];
        if (e.valid and addrEq(e.dst, dst)) return @min(e.mtu, if_mtu);
    }
    return if_mtu;
}

/// Probe helper (SK-97): number of Path MTU cache entries.
pub fn probePathMtuCount() u32 {
    const flags = pmtu_lock.acquire();
    defer pmtu_lock.release(flags);
    var n: u32 = 0;
    for (0..MAX_PMTU_ENTRIES) |i| {
        if (pmtu_table[i].valid) n += 1;
    }
    return n;
}

/// Age Path MTU entries; expired destinations revert to LINK_MTU (SK-97).
pub fn pathMtuTimerTick(ms_elapsed: u32) void {
    if (ms_elapsed == 0) return;
    const flags = pmtu_lock.acquire();
    defer pmtu_lock.release(flags);
    for (0..MAX_PMTU_ENTRIES) |i| {
        const e = &pmtu_table[i];
        if (!e.valid) continue;
        e.age_ms +%= ms_elapsed;
        while (e.age_ms >= 1000 and e.lifetime_sec > 0) {
            e.age_ms -= 1000;
            e.lifetime_sec -= 1;
        }
        if (e.lifetime_sec == 0) e.* = .{};
    }
}
