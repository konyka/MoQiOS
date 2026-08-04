const nic = @import("nic.zig");
const netif = @import("netif.zig");
const lo = @import("lo.zig");
const eth = @import("eth.zig");
const ipv4 = @import("ipv4.zig");
const ipv6 = @import("ipv6.zig");
const arp = @import("arp.zig");
const ndp = @import("ndp.zig");
const icmpv6 = @import("icmpv6.zig");
const udp_util = @import("udp_util.zig");
const bo = @import("../lib/byte_order.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

const MAX_PORTS = 16;
const QUEUE_DEPTH = 8;
/// IPv4 Ethernet MTU 1500 − 20 − 8.
const MAX_UDP_PAYLOAD = 1472;
/// IPv6 minimum MTU 1280 − 40 − 8.
const MAX_UDP_PAYLOAD_V6 = 1232;

const UdpEntry = struct {
    src_ip: [16]u8,
    src_port: u16,
    dst_port: u16,
    data_len: u16,
    data: [MAX_UDP_PAYLOAD]u8,
    valid: bool,
    is_v6: bool,
};

var ports: [MAX_PORTS]u16 = @splat(0);
/// Cross-process references per registered port (fork/clone fd-table copy) —
/// releasePort frees the slot only when the count reaches 0.
var port_refs: [MAX_PORTS]u16 = @splat(0);
var queues: [MAX_PORTS][QUEUE_DEPTH]UdpEntry = @splat(@splat(.{
    .src_ip = @splat(0),
    .src_port = 0,
    .dst_port = 0,
    .data_len = 0,
    .data = @splat(0),
    .valid = false,
    .is_v6 = false,
}));
var num_ports: u16 = 0;
var udp_lock: IrqSpinlock = .{};

/// Lookup with the lock already held. Callers that use the returned index to
/// touch `queues` MUST stay in the same critical section: releasePort's
/// swap-remove reshuffles slots, so an index computed under a previous lock
/// hold can name a different port's queue by the time it is used (J1).
fn findPortIdxLocked(port: u16) ?u16 {
    for (0..num_ports) |i| {
        if (ports[i] == port) return @intCast(i);
    }
    return null;
}

pub fn ensurePort(port: u16) u16 {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);

    // Check for existing registration
    for (0..num_ports) |i| {
        if (ports[i] == port) return @intCast(i);
    }

    if (num_ports >= MAX_PORTS) return 0xFFFF;
    const idx = num_ports;
    ports[idx] = port;
    port_refs[idx] = 1;
    num_ports += 1;
    return @intCast(idx);
}

/// Register `port` only when no socket owns it yet. Returns the new slot
/// index, 0xFFFE when the port is already registered, 0xFFFF when full.
pub fn ensurePortExclusive(port: u16) u16 {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);

    for (0..num_ports) |i| {
        if (ports[i] == port) return 0xFFFE;
    }

    if (num_ports >= MAX_PORTS) return 0xFFFF;
    const idx = num_ports;
    ports[idx] = port;
    port_refs[idx] = 1;
    num_ports += 1;
    return @intCast(idx);
}

/// Add a cross-process reference to a registered port (fork/clone).
pub fn retainPort(port: u16) void {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    for (0..num_ports) |i| {
        if (ports[i] == port) {
            port_refs[i] += 1;
            return;
        }
    }
}

/// Deregister `port`, freeing its slot and dropping any queued datagrams.
/// Swap-remove keeps slots dense; each queue travels with its port.
/// A port shared across fork/clone survives until the last reference drops.
pub fn releasePort(port: u16) void {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);

    for (0..num_ports) |i| {
        if (ports[i] == port) {
            if (port_refs[i] > 1) {
                port_refs[i] -= 1;
                return;
            }
            num_ports -= 1;
            ports[i] = ports[num_ports];
            port_refs[i] = port_refs[num_ports];
            queues[i] = queues[num_ports];
            ports[num_ports] = 0;
            port_refs[num_ports] = 0;
            // Invalidate the vacated tail so a future registration on that
            // slot never delivers stale datagrams to a new owner.
            for (0..QUEUE_DEPTH) |j| queues[num_ports][j].valid = false;
            return;
        }
    }
}

/// True when a datagram is queued for `port` (epoll readiness).
pub fn hasQueuedDatagram(port: u16) bool {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    const port_idx = findPortIdxLocked(port) orelse return false;
    for (0..QUEUE_DEPTH) |i| {
        if (queues[port_idx][i].valid) return true;
    }
    return false;
}

/// J1: the port lookup and the queue insert share one critical section.
/// Previously the caller looked the index up under its own lock hold and
/// passed it here; a concurrent releasePort swap-remove in between could
/// point the index at a different port's queue, delivering the datagram to
/// the wrong socket (or effectively dropping it for the real owner).
fn enqueue(port: u16, src_ip: [16]u8, src_port: u16, dst_port: u16, payload: []const u8, is_v6: bool) void {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);

    const port_idx = findPortIdxLocked(port) orelse return;
    const actual = @min(payload.len, MAX_UDP_PAYLOAD);
    for (0..QUEUE_DEPTH) |i| {
        if (!queues[port_idx][i].valid) {
            queues[port_idx][i].src_ip = src_ip;
            queues[port_idx][i].src_port = src_port;
            queues[port_idx][i].dst_port = dst_port;
            queues[port_idx][i].data_len = @intCast(actual);
            @memcpy(queues[port_idx][i].data[0..actual], payload[0..actual]);
            queues[port_idx][i].is_v6 = is_v6;
            queues[port_idx][i].valid = true;
            return;
        }
    }
    // Queue full - packet dropped (no accounting yet)
}

pub fn handlePacket(src_ip: [4]u8, dst_ip: [4]u8, data: [*]const u8, len: u32) void {
    const hdr = udp_util.parseHeader(data, len) orelse return;

    // RFC 768: checksum 0 means "no checksum" for IPv4 UDP; verify when present.
    const wire_csum = bo.readU16BeAt(data, 6);
    if (wire_csum != 0) {
        if (hdr.udp_len < udp_util.HEADER_LEN or hdr.udp_len > len) return;
        const expect = udp_util.checksumV4(src_ip, dst_ip, data, hdr.udp_len);
        if (wire_csum != expect) return;
    }

    const actual_payload = @min(hdr.payload_len, @as(u16, MAX_UDP_PAYLOAD));
    if (8 + actual_payload > len) return;
    var ip16: [16]u8 = @splat(0);
    @memcpy(ip16[0..4], &src_ip);
    enqueue(hdr.dst_port, ip16, hdr.src_port, hdr.dst_port, data[8..][0..actual_payload], false);
}

/// IPv6 UDP receive (SK-70). Bound-port-only; checksum verified when non-zero.
pub fn handlePacketV6(src_ip: [16]u8, dst_ip: [16]u8, data: [*]const u8, len: u32) void {
    const hdr = udp_util.parseHeader(data, len) orelse return;
    if (hdr.udp_len < udp_util.HEADER_LEN or hdr.udp_len > len) return;

    // IPv6 UDP checksum is mandatory; reject if the field is zero or wrong.
    const wire_csum = bo.readU16BeAt(data, 6);
    if (wire_csum == 0) return;
    const expect = udp_util.checksumV6(src_ip, dst_ip, data, hdr.udp_len);
    if (wire_csum != expect) return;

    const actual_payload = @min(hdr.payload_len, @as(u16, MAX_UDP_PAYLOAD_V6));
    if (8 + actual_payload > len) return;
    enqueue(hdr.dst_port, src_ip, hdr.src_port, hdr.dst_port, data[8..][0..actual_payload], true);
}

pub fn recvFrom(port: u16, out_buf: [*]u8, out_len: u16, out_src_ip: *[4]u8, out_src_port: *u16) i64 {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);

    // J1: lookup and dequeue in one critical section (see enqueue).
    const port_idx = findPortIdxLocked(port) orelse return 0;
    for (0..QUEUE_DEPTH) |i| {
        const entry = &queues[port_idx][i];
        if (entry.valid and !entry.is_v6) {
            const n = @min(entry.data_len, out_len);
            @memcpy(out_buf[0..n], entry.data[0..n]);
            out_src_ip.* = entry.src_ip[0..4].*;
            out_src_port.* = entry.src_port;
            entry.valid = false;
            return n;
        }
    }
    return 0;
}

/// Drain one IPv6 datagram for `port` (SK-70).
pub fn recvFromV6(port: u16, out_buf: [*]u8, out_src_ip: *[16]u8, out_src_port: *u16) i64 {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);

    const port_idx = findPortIdxLocked(port) orelse return 0;
    for (0..QUEUE_DEPTH) |i| {
        const entry = &queues[port_idx][i];
        if (entry.valid and entry.is_v6) {
            const n = entry.data_len;
            @memcpy(out_buf[0..n], entry.data[0..n]);
            out_src_ip.* = entry.src_ip;
            out_src_port.* = entry.src_port;
            entry.valid = false;
            return n;
        }
    }
    return 0;
}

pub fn sendTo(dst_ip: [4]u8, dst_port: u16, src_port: u16, data: [*]const u8, data_len: u16) bool {
    if (data_len > MAX_UDP_PAYLOAD) return false;

    const our_mac = netif.getMac();
    // F2: 127.0.0.0/8 goes to the loopback device — no ARP, no hardware NIC.
    const loopback = netif.isLoopback(dst_ip);
    // Limited broadcast has no ARP entry (arp.resolve would fail and nothing
    // would ever be transmitted) — use the broadcast MAC directly. DHCP
    // DISCOVER/REQUEST depend on this.
    const dst_mac = if (loopback)
        our_mac
    else if (dst_ip[0] == 255 and dst_ip[1] == 255 and dst_ip[2] == 255 and dst_ip[3] == 255)
        [6]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }
    else
        arp.resolve(dst_ip) orelse {
            arp.sendArpRequest(dst_ip);
            return false;
        };

    // Loopback datagrams also carry the 127/8 destination as source, so the
    // peer's replies stay on lo and both directions are symmetric.
    const our_ip = if (loopback) dst_ip else netif.getOurIp();
    const udp_total: u16 = 8 + data_len;
    // SK-101/105: honor Path MTU (or armed oversized raise probe).
    if (ipv4.HEADER_LEN + udp_total > ipv4.getSendMtu(dst_ip)) return false;

    // Stack-local frame buffer: concurrent sends on other CPUs must not tear it.
    var send_pkt: [1518]u8 = @splat(0);

    // Build UDP header at offset 34 (14 eth + 20 ipv4)
    bo.writeU16BeAt(&send_pkt, 34, src_port);
    bo.writeU16BeAt(&send_pkt, 36, dst_port);
    bo.writeU16BeAt(&send_pkt, 38, udp_total);
    send_pkt[40] = 0x00;
    send_pkt[41] = 0x00;

    // Copy payload after UDP header
    @memcpy(send_pkt[42 .. 42 + data_len], data[0..data_len]);

    // Build IPv4 header at offset 14 (after ethernet header)
    ipv4.buildHeader(send_pkt[14..].ptr, our_ip, dst_ip, ipv4.PROTO_UDP, udp_total);

    // Build ethernet frame
    const frame_len = eth.buildFrame(&send_pkt, dst_mac, our_mac, eth.ETHERTYPE_IPV4, 20 + udp_total);

    const ok = if (loopback) lo.sendPacket(&send_pkt, frame_len) else nic.sendPacket(&send_pkt, frame_len);
    // SK-104: full-MTU TX success can raise the Path MTU early.
    if (ok) ipv4.noteFullSizeSend(dst_ip, ipv4.HEADER_LEN + udp_total);
    return ok;
}

/// Send a UDP datagram over IPv6 (SK-70/87). On-link via NDP; off-link via default router.
pub fn sendToV6(dst_ip: [16]u8, dst_port: u16, src_port: u16, data: [*]const u8, data_len: u16) bool {
    if (data_len > MAX_UDP_PAYLOAD_V6) return false;

    const nh = ndp.resolveNextHop(dst_ip);
    // K3: ::1 short-circuits NDP and the wire — loop back via lo.
    const is_loop = netif.isLoopbackV6(dst_ip);
    const dst_mac = if (is_loop) netif.getMac() else nh.mac orelse {
        if (nh.solicit) |t| icmpv6.sendNeighborSolicitation(t);
        return false;
    };

    const our_mac = netif.getMac();
    // Loopback: src = dst = ::1 (mirrors the IPv4 lo choice), keeping TX/RX
    // pseudo-headers consistent on both sides.
    const our_ip = if (is_loop) dst_ip else ndp.selectSourceAddress(dst_ip, our_mac);
    const udp_total: u16 = 8 + data_len;
    // SK-97/105: honor Path MTU (or armed oversized raise probe).
    if (ipv6.HEADER_LEN + udp_total > ipv6.getSendMtu(dst_ip)) return false;

    // Stack-local frame buffer: concurrent sends on other CPUs must not tear it.
    var send_pkt: [1518]u8 = @splat(0);

    // Offsets: eth 14 + ipv6 40 → UDP at 54.
    const udp_off: u16 = 14 + ipv6.HEADER_LEN;
    bo.writeU16BeAt(&send_pkt, udp_off, src_port);
    bo.writeU16BeAt(&send_pkt, udp_off + 2, dst_port);
    bo.writeU16BeAt(&send_pkt, udp_off + 4, udp_total);
    send_pkt[udp_off + 6] = 0;
    send_pkt[udp_off + 7] = 0;
    @memcpy(send_pkt[udp_off + 8 ..][0..data_len], data[0..data_len]);

    const csum = udp_util.checksumV6(our_ip, dst_ip, send_pkt[udp_off..].ptr, udp_total);
    bo.writeU16BeAt(&send_pkt, udp_off + 6, csum);

    ipv6.buildHeader(send_pkt[14..].ptr, our_ip, dst_ip, ipv6.PROTO_UDP, udp_total);
    const frame_len = eth.buildFrame(&send_pkt, dst_mac, our_mac, eth.ETHERTYPE_IPV6, ipv6.HEADER_LEN + udp_total);
    const ok = if (is_loop) lo.sendPacket(&send_pkt, frame_len) else nic.sendPacket(&send_pkt, frame_len);
    // SK-104: full-MTU TX success can raise the Path MTU early.
    if (ok) ipv6.noteFullSizeSend(dst_ip, ipv6.HEADER_LEN + udp_total);
    return ok;
}
