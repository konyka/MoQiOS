const bo = @import("../lib/byte_order.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const netif = @import("netif.zig");

pub const PROTO_ICMP: u8 = 1;
pub const PROTO_TCP: u8 = 6;
pub const PROTO_UDP: u8 = 17;

/// IPv4 minimum reassembly MTU (RFC 791).
pub const MIN_MTU: u16 = 576;
/// Ethernet link MTU used as the default Path MTU.
pub const LINK_MTU: u16 = 1500;
/// How long a learned Path MTU stays without refresh (seconds) (SK-101).
pub const PMTU_LIFETIME_SEC: u32 = 600;
/// Lifetime between raise-probe steps after expiry (SK-103).
pub const PMTU_RAISE_LIFETIME_SEC: u32 = 60;
pub const MAX_PMTU_ENTRIES: u32 = 8;
/// IPv4 header (no options) for SMSS (SK-101).
pub const HEADER_LEN: u16 = 20;

pub const Ipv4Info = struct {
    src_ip: [4]u8,
    dst_ip: [4]u8,
    protocol: u8,
    payload_offset: u16,
    payload_len: u16,
};

pub fn buildHeader(buf: [*]u8, src_ip: [4]u8, dst_ip: [4]u8, protocol: u8, payload_len: u16) void {
    const total_len: u16 = 20 + payload_len;

    buf[0] = 0x45;
    buf[1] = 0x00;
    bo.writeU16BeAt(buf, 2, total_len);
    buf[4] = 0x00;
    buf[5] = 0x00;
    buf[6] = 0x40;
    buf[7] = 0x00;
    buf[8] = 0x40;
    buf[9] = protocol;
    buf[10] = 0x00;
    buf[11] = 0x00;
    @memcpy(buf[12..16], &src_ip);
    @memcpy(buf[16..20], &dst_ip);

    const csum = checksum(buf, 20);
    bo.writeU16BeAt(buf, 10, csum);
}

/// Internet checksum (RFC 1071) — optimized with u64 accumulator and 4-byte stride.
pub fn checksum(buf: [*]const u8, len: u16) u16 {
    var acc: u64 = 0;
    const l: usize = len;
    var i: usize = 0;

    // Process 4 bytes (two 16-bit words) per iteration
    while (i + 4 <= l) : (i += 4) {
        acc += (@as(u64, buf[i]) << 24) | (@as(u64, buf[i + 1]) << 16) |
            (@as(u64, buf[i + 2]) << 8) | @as(u64, buf[i + 3]);
    }
    // Remaining 16-bit word
    if (i + 2 <= l) {
        acc += (@as(u64, buf[i]) << 8) | @as(u64, buf[i + 1]);
        i += 2;
    }
    // Odd trailing byte
    if (i < l) {
        acc += @as(u64, buf[i]) << 8;
    }

    // Fold 64→32→16
    var sum: u32 = @truncate(acc);
    sum +|= @as(u32, @truncate(acc >> 32));
    sum = (sum & 0xFFFF) + (sum >> 16);
    sum = (sum & 0xFFFF) + (sum >> 16);
    return @truncate(~sum);
}

pub fn parseHeader(data: [*]const u8) ?Ipv4Info {
    const version = (data[0] >> 4) & 0xF;
    if (version != 4) return null;

    const ihl = @as(u16, data[0] & 0xF) * 4;
    if (ihl < 20) return null;

    const total_len = bo.readU16BeAt(data, 2);
    const payload_len = total_len - ihl;

    return .{
        .src_ip = .{ data[12], data[13], data[14], data[15] },
        .dst_ip = .{ data[16], data[17], data[18], data[19] },
        .protocol = data[9],
        .payload_offset = ihl,
        .payload_len = payload_len,
    };
}

fn addrEq(a: [4]u8, b: [4]u8) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3];
}

// ── SK-101: Path MTU cache (ICMP Fragmentation Needed) ────────────────────
const PmtuEntry = struct {
    dst: [4]u8 = .{ 0, 0, 0, 0 },
    mtu: u16 = LINK_MTU,
    lifetime_sec: u32 = 0,
    age_ms: u32 = 0,
    /// SK-105: allow one TX up to `probe_mtu` (> cached mtu).
    probe_armed: bool = false,
    probe_mtu: u16 = 0,
    valid: bool = false,
};
var pmtu_table: [MAX_PMTU_ENTRIES]PmtuEntry = @splat(.{});
var pmtu_lock: IrqSpinlock = .{};

/// Clear the IPv4 Path MTU cache (called from net.init).
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

/// Lower (or install) Path MTU for `dst` from Fragmentation Needed (SK-101).
pub fn updatePathMtu(dst: [4]u8, reported_mtu: u32) void {
    const mtu = clampMtu(reported_mtu);
    const flags = pmtu_lock.acquire();
    defer pmtu_lock.release(flags);
    for (0..MAX_PMTU_ENTRIES) |i| {
        const e = &pmtu_table[i];
        if (e.valid and addrEq(e.dst, dst)) {
            if (mtu < e.mtu) e.mtu = mtu;
            e.lifetime_sec = PMTU_LIFETIME_SEC;
            e.age_ms = 0;
            e.probe_armed = false;
            e.probe_mtu = 0;
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

/// Current Path MTU for `dst`, or interface MTU when unknown (SK-101/102).
pub fn getPathMtu(dst: [4]u8) u16 {
    const if_mtu = netif.getMtu();
    const flags = pmtu_lock.acquire();
    defer pmtu_lock.release(flags);
    for (0..MAX_PMTU_ENTRIES) |i| {
        const e = &pmtu_table[i];
        if (e.valid and addrEq(e.dst, dst)) return @min(e.mtu, if_mtu);
    }
    return if_mtu;
}

/// TX ceiling: Path MTU, or an armed oversized probe target (SK-105).
pub fn getSendMtu(dst: [4]u8) u16 {
    const if_mtu = netif.getMtu();
    const flags = pmtu_lock.acquire();
    defer pmtu_lock.release(flags);
    for (0..MAX_PMTU_ENTRIES) |i| {
        const e = &pmtu_table[i];
        if (!(e.valid and addrEq(e.dst, dst))) continue;
        if (e.probe_armed and e.probe_mtu > e.mtu) return @min(e.probe_mtu, if_mtu);
        return @min(e.mtu, if_mtu);
    }
    return if_mtu;
}

/// Arm one oversized raise probe up to the next plateau (SK-105).
pub fn armRaiseProbe(dst: [4]u8) bool {
    const if_mtu = netif.getMtu();
    const flags = pmtu_lock.acquire();
    defer pmtu_lock.release(flags);
    for (0..MAX_PMTU_ENTRIES) |i| {
        const e = &pmtu_table[i];
        if (!(e.valid and addrEq(e.dst, dst))) continue;
        if (e.mtu >= if_mtu) return false;
        e.probe_mtu = nextRaiseMtu(e.mtu, if_mtu);
        e.probe_armed = e.probe_mtu > e.mtu;
        return e.probe_armed;
    }
    return false;
}

/// Probe helper (SK-101).
pub fn probePathMtuCount() u32 {
    const flags = pmtu_lock.acquire();
    defer pmtu_lock.release(flags);
    var n: u32 = 0;
    for (0..MAX_PMTU_ENTRIES) |i| {
        if (pmtu_table[i].valid) n += 1;
    }
    return n;
}

/// Next raise-probe MTU toward `if_mtu` (RFC 1191/4821 plateaus) (SK-103).
pub fn nextRaiseMtu(current: u16, if_mtu: u16) u16 {
    if (current >= if_mtu) return if_mtu;
    const plateaus = [_]u16{ 576, 1006, 1280, 1400, 1492, 1500 };
    for (plateaus) |p| {
        if (p > current and p <= if_mtu) return p;
    }
    return if_mtu;
}

/// After a successful full-MTU TX, raise one plateau early (SK-104).
/// `ip_total_len` is the IPv4 packet length (header + payload).
pub fn noteFullSizeSend(dst: [4]u8, ip_total_len: u16) void {
    const if_mtu = netif.getMtu();
    const flags = pmtu_lock.acquire();
    defer pmtu_lock.release(flags);
    for (0..MAX_PMTU_ENTRIES) |i| {
        const e = &pmtu_table[i];
        if (!(e.valid and addrEq(e.dst, dst))) continue;
        if (ip_total_len < e.mtu) return;
        if (e.mtu >= if_mtu) return;
        e.mtu = nextRaiseMtu(e.mtu, if_mtu);
        e.lifetime_sec = PMTU_RAISE_LIFETIME_SEC;
        e.age_ms = 0;
        // SK-105: immediately arm the next oversized probe if room remains.
        if (e.mtu < if_mtu) {
            e.probe_mtu = nextRaiseMtu(e.mtu, if_mtu);
            e.probe_armed = e.probe_mtu > e.mtu;
        } else {
            e.probe_armed = false;
            e.probe_mtu = 0;
        }
        return;
    }
}

/// Age IPv4 Path MTU entries; on expiry raise toward interface MTU then clear (SK-101/103).
pub fn pathMtuTimerTick(ms_elapsed: u32) void {
    if (ms_elapsed == 0) return;
    const if_mtu = netif.getMtu();
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
        if (e.lifetime_sec != 0) continue;
        // SK-103: probe upward instead of jumping straight back to the link MTU.
        if (e.mtu >= if_mtu) {
            e.* = .{};
        } else {
            e.mtu = nextRaiseMtu(e.mtu, if_mtu);
            e.lifetime_sec = PMTU_RAISE_LIFETIME_SEC;
            e.age_ms = 0;
        }
    }
}

/// Probe helper: expire/raise until cleared or `max_steps` (SK-103).
pub fn probeDrainPathMtu(max_steps: u32) void {
    var n: u32 = 0;
    while (n < max_steps and probePathMtuCount() != 0) : (n += 1) {
        pathMtuTimerTick(PMTU_LIFETIME_SEC * 1000);
    }
}
