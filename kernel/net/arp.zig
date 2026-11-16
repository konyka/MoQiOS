const nic = @import("nic.zig");
const netif = @import("netif.zig");
const eth = @import("eth.zig");
const bo = @import("../lib/byte_order.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

const MAX_ARP_ENTRIES: usize = 16;

const ArpEntry = struct {
    ip: [4]u8,
    mac: [6]u8,
    valid: bool,
    /// Set with SIOCSARP and ATF_PERM (NUD_PERMANENT): received ARP no longer changes it.
    perm: bool = false,
};

var cache: [MAX_ARP_ENTRIES]ArpEntry = @splat(.{ .ip = @splat(0), .mac = @splat(0), .valid = false });
// addToCache runs in IRQ context while resolve runs from syscall context.
var arp_lock: IrqSpinlock = .{};

const policy = @import("arp_policy.zig");
const FRAME_MAX: usize = 1518;
/// Frames waiting for their next hop's MAC (arp_policy: Linux queues them on the neighbour while ARP asks for it).
var pending: [policy.MAX_PENDING]policy.Slot = @splat(.{});
var pending_frame: [policy.MAX_PENDING][FRAME_MAX]u8 = undefined;
var pending_len: [policy.MAX_PENDING]u32 = @splat(0);

fn nowNs() u64 {
    return @import("../arch/arch.zig").tsc.nanos();
}

/// Keep the Ethernet frame `frame` (its destination MAC still unset) until `hop` answers ARP, asking for it when no other frame
/// is already waiting on it; it goes out when the reply comes (addToCache) and is dropped silently when none comes within
/// arp_policy.HOLD_NS. The send that produced it counts as done, as in Linux.
pub fn queueFrame(hop: [4]u8, frame: [*]const u8, len: u32) void {
    if (len > FRAME_MAX) return;
    const now = nowNs();
    var ask = false;
    {
        const saved = arp_lock.acquire();
        defer arp_lock.release(saved);
        ask = policy.firstForHop(&pending, hop, now);
        const i = policy.pickSlot(&pending, now);
        pending[i] = .{ .used = true, .hop = hop, .queued_ns = now, .next_probe_ns = now + policy.PROBE_INTERVAL_NS };
        @memcpy(pending_frame[i][0..len], frame[0..len]);
        pending_len[i] = len;
    }
    if (ask) sendArpRequest(hop);
}

/// Send the frames waiting for `ip`, now at `mac`.
fn flushPending(ip: [4]u8, mac: [6]u8) void {
    var out: [FRAME_MAX]u8 = undefined;
    while (true) {
        var n: u32 = 0;
        {
            const saved = arp_lock.acquire();
            defer arp_lock.release(saved);
            const now = nowNs();
            for (0..policy.MAX_PENDING) |i| {
                if (!pending[i].used or policy.expired(pending[i], now)) continue;
                if (@as(u32, @bitCast(pending[i].hop)) != @as(u32, @bitCast(ip))) continue;
                n = pending_len[i];
                @memcpy(out[0..n], pending_frame[i][0..n]);
                pending[i].used = false;
                break;
            }
        }
        if (n == 0) return;
        @memcpy(out[0..6], &mac);
        _ = nic.sendPacket(&out, n);
    }
}

/// Called every 100 ms: ask again for the neighbours frames still wait on (arp_solicit every retrans_time) and drop the frames
/// whose neighbour did not answer in time (NUD_FAILED).
pub fn timerTick() void {
    var ask: [policy.MAX_PENDING][4]u8 = undefined;
    var n: usize = 0;
    {
        const saved = arp_lock.acquire();
        defer arp_lock.release(saved);
        const now = nowNs();
        for (0..policy.MAX_PENDING) |i| {
            if (policy.expired(pending[i], now)) {
                pending[i].used = false;
                continue;
            }
            if (!policy.probeDue(pending[i], now)) continue;
            pending[i].next_probe_ns = now + policy.PROBE_INTERVAL_NS;
            var dup = false;
            for (ask[0..n]) |h| dup = dup or @as(u32, @bitCast(h)) == @as(u32, @bitCast(pending[i].hop));
            if (!dup) {
                ask[n] = pending[i].hop;
                n += 1;
            }
        }
    }
    for (ask[0..n]) |h| sendArpRequest(h);
}

/// Remove the entry for `ip` (SIOCDARP); false when there is none.
pub fn deleteEntry(ip: [4]u8) bool {
    const saved = arp_lock.acquire();
    defer arp_lock.release(saved);
    for (0..MAX_ARP_ENTRIES) |i| {
        if (cache[i].valid and @as(u32, @bitCast(cache[i].ip)) == @as(u32, @bitCast(ip))) {
            cache[i].valid = false;
            return true;
        }
    }
    return false;
}

pub fn init() void {
    const saved = arp_lock.acquire();
    defer arp_lock.release(saved);
    for (0..MAX_ARP_ENTRIES) |i| {
        cache[i].valid = false;
    }
}

pub fn handlePacket(data: [*]const u8, len: u32) void {
    if (len < 42) return;

    const htype = bo.readU16BeAt(data, 14);
    const ptype = bo.readU16BeAt(data, 16);
    const opcode = bo.readU16BeAt(data, 20);

    if (htype != 1 or ptype != 0x0800) return;

    const sender_mac: [6]u8 = .{ data[22], data[23], data[24], data[25], data[26], data[27] };
    const sender_ip: [4]u8 = .{ data[28], data[29], data[30], data[31] };
    const target_ip: [4]u8 = .{ data[38], data[39], data[40], data[41] };

    // Cache sender's MAC regardless, and send what waited for it.
    addToCache(sender_ip, sender_mac);
    flushPending(sender_ip, sender_mac);

    if (opcode == 1) {
        // ARP request — is it for our IP?
        const our_ip = netif.getOurIp();
        if (@as(u32, @bitCast(target_ip)) == @as(u32, @bitCast(our_ip))) {
            sendArpReply(sender_ip, sender_mac);
        }
    }
}

pub const Entry = struct { mac: [6]u8, perm: bool };

/// The entry for `ip` with its state (SIOCGARP).
pub fn lookupEntry(ip: [4]u8) ?Entry {
    const saved = arp_lock.acquire();
    defer arp_lock.release(saved);
    for (0..MAX_ARP_ENTRIES) |i| {
        if (cache[i].valid and @as(u32, @bitCast(cache[i].ip)) == @as(u32, @bitCast(ip))) return .{ .mac = cache[i].mac, .perm = cache[i].perm };
    }
    return null;
}

/// SIOCSARP (arp_req_set → neigh_update with NEIGH_UPDATE_F_ADMIN): install `mac` for `ip`, permanent or not, replacing what is
/// there; with no MAC given the entry keeps its MAC and only its state changes, and a new entry cannot be made (EINVAL). A full
/// table gives up its first non-permanent entry; when every entry is permanent the request fails with ENOBUFS. Frames waiting for
/// `ip` go out once it has a MAC.
pub fn setEntry(ip: [4]u8, mac: ?[6]u8, perm: bool) i64 {
    var installed: ?[6]u8 = null;
    {
        const saved = arp_lock.acquire();
        defer arp_lock.release(saved);
        var slot: ?usize = null;
        for (0..MAX_ARP_ENTRIES) |i| {
            if (cache[i].valid and @as(u32, @bitCast(cache[i].ip)) == @as(u32, @bitCast(ip))) slot = i;
        }
        if (slot == null) {
            const m = mac orelse return -22; // EINVAL
            for (0..MAX_ARP_ENTRIES) |i| {
                if (!cache[i].valid) {
                    slot = i;
                    break;
                }
            }
            if (slot == null) {
                for (0..MAX_ARP_ENTRIES) |i| {
                    if (!cache[i].perm) {
                        slot = i;
                        break;
                    }
                }
            }
            const i = slot orelse return -105; // ENOBUFS
            cache[i] = .{ .ip = ip, .mac = m, .valid = true, .perm = perm };
            installed = m;
        } else {
            const i = slot.?;
            if (mac) |m| cache[i].mac = m;
            cache[i].perm = perm;
            installed = cache[i].mac;
        }
    }
    if (installed) |m| flushPending(ip, m);
    return 0;
}

/// /proc/net/arp: the header and one line per entry (arp_policy.formatProcLine), all on the NIC. Returns the bytes written.
pub fn formatProc(out: []u8) usize {
    var snap: [MAX_ARP_ENTRIES]ArpEntry = undefined;
    {
        const saved = arp_lock.acquire();
        defer arp_lock.release(saved);
        snap = cache;
    }
    if (out.len < policy.PROC_HEADER.len) return 0;
    @memcpy(out[0..policy.PROC_HEADER.len], policy.PROC_HEADER);
    var n: usize = policy.PROC_HEADER.len;
    for (snap) |e| {
        if (!e.valid) continue;
        n += policy.formatProcLine(out[n..], e.ip, e.mac, e.perm, "eth0");
    }
    return n;
}

pub fn resolve(ip: [4]u8) ?[6]u8 {
    const saved = arp_lock.acquire();
    defer arp_lock.release(saved);
    for (0..MAX_ARP_ENTRIES) |i| {
        if (cache[i].valid and @as(u32, @bitCast(cache[i].ip)) == @as(u32, @bitCast(ip))) {
            return cache[i].mac;
        }
    }
    return null;
}

pub fn sendArpRequest(target_ip: [4]u8) void {
    var pkt: [64]u8 = @splat(0);
    const our_mac = netif.getMac();
    const our_ip = netif.getOurIp();

    // Ethernet header: broadcast
    for (0..6) |i| pkt[i] = 0xFF;
    @memcpy(pkt[6..12], &our_mac);
    pkt[12] = 0x08;
    pkt[13] = 0x06; // Ethertype ARP

    // ARP payload
    pkt[14] = 0x00;
    pkt[15] = 0x01; // HTYPE=Ethernet
    pkt[16] = 0x08;
    pkt[17] = 0x00; // PTYPE=IPv4
    pkt[18] = 6; // HLEN
    pkt[19] = 4; // PLEN
    pkt[20] = 0x00;
    pkt[21] = 0x01; // Opcode=request
    @memcpy(pkt[22..28], &our_mac);
    @memcpy(pkt[28..32], &our_ip);
    for (32..38) |i| pkt[i] = 0; // Target MAC = 0
    @memcpy(pkt[38..42], &target_ip);

    _ = nic.sendPacket(&pkt, 42);
}

fn addToCache(ip: [4]u8, mac: [6]u8) void {
    const saved = arp_lock.acquire();
    defer arp_lock.release(saved);
    // Update existing entry
    for (0..MAX_ARP_ENTRIES) |i| {
        if (cache[i].valid and @as(u32, @bitCast(cache[i].ip)) == @as(u32, @bitCast(ip))) {
            if (!cache[i].perm) cache[i].mac = mac;
            return;
        }
    }
    // Add new entry
    for (0..MAX_ARP_ENTRIES) |i| {
        if (!cache[i].valid) {
            cache[i] = .{ .ip = ip, .mac = mac, .valid = true, .perm = false };
            return;
        }
    }
}

fn sendArpReply(target_ip: [4]u8, target_mac: [6]u8) void {
    var pkt: [64]u8 = @splat(0);
    const our_mac = netif.getMac();
    const our_ip = netif.getOurIp();

    @memcpy(pkt[0..6], &target_mac);
    @memcpy(pkt[6..12], &our_mac);
    pkt[12] = 0x08;
    pkt[13] = 0x06;

    pkt[14] = 0x00;
    pkt[15] = 0x01;
    pkt[16] = 0x08;
    pkt[17] = 0x00;
    pkt[18] = 6;
    pkt[19] = 4;
    pkt[20] = 0x00;
    pkt[21] = 0x02; // Opcode=reply
    @memcpy(pkt[22..28], &our_mac);
    @memcpy(pkt[28..32], &our_ip);
    @memcpy(pkt[32..38], &target_mac);
    @memcpy(pkt[38..42], &target_ip);

    _ = nic.sendPacket(&pkt, 42);
}
