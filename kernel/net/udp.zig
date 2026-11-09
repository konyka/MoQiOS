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
const ip_opt_policy = @import("ip_opt_policy.zig");
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

/// Socket key per slot: the local port in the low 16 bits and a discriminator in the high 16 bits. The discriminator is 0 for the first
/// socket on a port; sockets that share the port (SO_REUSEADDR / SO_REUSEPORT) get the smallest unused nonzero value.
var ports: [MAX_PORTS]u32 = @splat(0);
/// Effective uid that bound each slot (SO_REUSEPORT only shares between equal uids) and its bind order (later = larger).
var port_uid: [MAX_PORTS]u32 = @splat(0);
var port_seq: [MAX_PORTS]u32 = @splat(0);
var next_seq: u32 = 1;
/// Address family of the socket that owns each slot.
var port_v6: [MAX_PORTS]bool = @splat(false);
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
/// SOL_SOCKET options per registered port (travels with the port slot).
var port_opts: [MAX_PORTS]@import("sockopt_policy.zig").Stored = @splat(.{});
/// Pending asynchronous error per port (ICMP port unreachable → ECONNREFUSED,
/// positive errno) and the peer port a connect() fixed, 0 when unconnected.
var port_err: [MAX_PORTS]i32 = @splat(0);
var port_peer: [MAX_PORTS]u16 = @splat(0);
/// Peer address a connect() fixed (IPv4 in the first 4 bytes), meaningful when port_peer is nonzero.
var port_peer_ip: [MAX_PORTS][16]u8 = @splat(@splat(0));

/// Options of the socket bound to `port`, or null if it is not registered.
pub fn getPortOpts(port: u32) ?@import("sockopt_policy.zig").Stored {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    const i = findPortIdxLocked(port) orelse return null;
    return port_opts[i];
}

pub fn setPortOpts(port: u32, opts: @import("sockopt_policy.zig").Stored) bool {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    const i = findPortIdxLocked(port) orelse return false;
    port_opts[i] = opts;
    return true;
}

/// connect() fixed the peer port of the socket bound to `port`.
/// connect() fixed the peer (address and port) of the socket with registry key `port`.
pub fn setPeer(port: u32, peer_port: u16, peer_ip: [16]u8) void {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    const i = findPortIdxLocked(port) orelse return;
    port_peer[i] = peer_port;
    port_peer_ip[i] = peer_ip;
    port_err[i] = 0;
}

/// The pending error (positive errno) of the socket bound to `port`, 0 if none.
pub fn peekPendingError(port: u32) i32 {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    const i = findPortIdxLocked(port) orelse return 0;
    return port_err[i];
}

/// Take (return and clear) the pending error of the socket bound to `port`.
pub fn takePendingError(port: u32) i32 {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    const i = findPortIdxLocked(port) orelse return 0;
    const e = port_err[i];
    port_err[i] = 0;
    return e;
}

/// Clear the pending error only if it still equals `expected` (SO_ERROR read).
pub fn clearPendingErrorIfEqual(port: u32, expected: i32) void {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    const i = findPortIdxLocked(port) orelse return;
    if (port_err[i] == expected) port_err[i] = 0;
}

/// An ICMP port-unreachable quoted a datagram sent from `local_port` to
/// `peer_port`: every socket connected to that peer fails with ECONNREFUSED.
pub fn notifyUnreachable(local_port: u16, peer_port: u16) void {
    var hits: [MAX_PORTS]u32 = undefined;
    var n: usize = 0;
    {
        const saved = udp_lock.acquire();
        defer udp_lock.release(saved);
        for (0..num_ports) |i| {
            if (portNumber(ports[i]) != local_port) continue;
            if (!@import("icmp_unreach_policy.zig").matchesConnected(.{ .src_port = local_port, .dst_port = peer_port }, local_port, port_peer[i] != 0, port_peer[i])) continue;
            port_err[i] = 111; // ECONNREFUSED
            hits[n] = ports[i];
            n += 1;
        }
    }
    for (hits[0..n]) |key| @import("epoll.zig").epollNotify(.udp_socket, key, @import("epoll.zig").EPOLLERR);
}

/// True when a socket is bound to `port`.
pub fn portBound(port: u16) bool {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    return countPortLocked(port) != 0;
}

/// Lookup with the lock already held. Callers that use the returned index to
/// touch `queues` MUST stay in the same critical section: releasePort's
/// swap-remove reshuffles slots, so an index computed under a previous lock
/// hold can name a different port's queue by the time it is used (J1).
fn findPortIdxLocked(port: u32) ?u16 {
    for (0..num_ports) |i| {
        if (ports[i] == port) return @intCast(i);
    }
    return null;
}

fn portNumber(key: u32) u16 {
    return @truncate(key);
}

/// Number of sockets holding local port `port` (every discriminator).
fn countPortLocked(port: u16) u32 {
    var n: u32 = 0;
    for (0..num_ports) |i| {
        if (portNumber(ports[i]) == port) n += 1;
    }
    return n;
}

fn newSlotLocked(key: u32, is_v6: bool, uid: u32) u16 {
    const idx = num_ports;
    ports[idx] = key;
    port_refs[idx] = 1;
    port_opts[idx] = .{};
    port_err[idx] = 0;
    port_peer[idx] = 0;
    port_peer_ip[idx] = @splat(0);
    port_uid[idx] = uid;
    port_seq[idx] = next_seq;
    next_seq +%= 1;
    port_v6[idx] = is_v6;
    for (0..QUEUE_DEPTH) |j| queues[idx][j].valid = false;
    num_ports += 1;
    return @intCast(idx);
}

pub fn ensurePort(port: u16) u16 {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);

    // Check for existing registration
    for (0..num_ports) |i| {
        if (ports[i] == port) return @intCast(i);
    }

    if (num_ports >= MAX_PORTS) return 0xFFFF;
    return newSlotLocked(port, false, 0);
}

/// Register `port` only when no socket owns it yet. Returns the new slot
/// index, 0xFFFE when the port is already registered, 0xFFFF when full.
pub fn ensurePortExclusive(port: u16, is_v6: bool, uid: u32) u16 {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);

    if (countPortLocked(port) != 0) return 0xFFFE;
    if (num_ports >= MAX_PORTS) return 0xFFFF;
    return newSlotLocked(port, is_v6, uid);
}

/// bind() on a UDP socket already registered under `old_key`: move it to `new_port`, keeping its options (SO_REUSEADDR / SO_REUSEPORT are
/// set before bind). A port another socket holds can be joined only when the sharing policy allows it with every holder. On success returns
/// 0 and the socket's new discriminator in `out_disc`; -98 (EADDRINUSE) when the port is taken or the table is full, -9 when `old_key` is gone.
pub fn rebind(old_key: u32, new_port: u16, uid: u32, out_disc: *u16) i64 {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);

    const oi = findPortIdxLocked(old_key) orelse return -9;
    if (portNumber(old_key) == new_port) {
        out_disc.* = @truncate(old_key >> 16);
        return 0;
    }
    const mine = port_opts[oi];
    var used: u32 = 0;
    for (0..num_ports) |j| {
        if (portNumber(ports[j]) != new_port) continue;
        if (!@import("udp_port_policy.zig").mayShare(mine.flags, port_opts[j].flags, uid, port_uid[j])) return -98;
        used |= @as(u32, 1) << @intCast(ports[j] >> 16);
    }
    if (num_ports >= MAX_PORTS) return -98;
    const disc: u16 = @intCast(@ctz(~used));
    const ni = newSlotLocked(new_port | (@as(u32, disc) << 16), port_v6[oi], uid);
    port_opts[ni] = mine;
    releaseLocked(old_key);
    out_disc.* = disc;
    return 0;
}

/// Add a cross-process reference to a registered port (fork/clone).
pub fn retainPort(port: u32) void {
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
pub fn releasePort(port: u32) void {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    releaseLocked(port);
}

fn releaseLocked(port: u32) void {
    for (0..num_ports) |i| {
        if (ports[i] == port) {
            if (port_refs[i] > 1) {
                port_refs[i] -= 1;
                return;
            }
            num_ports -= 1;
            ports[i] = ports[num_ports];
            port_refs[i] = port_refs[num_ports];
            port_opts[i] = port_opts[num_ports];
            port_err[i] = port_err[num_ports];
            port_peer[i] = port_peer[num_ports];
            port_peer_ip[i] = port_peer_ip[num_ports];
            port_uid[i] = port_uid[num_ports];
            port_seq[i] = port_seq[num_ports];
            port_v6[i] = port_v6[num_ports];
            port_err[num_ports] = 0;
            port_peer[num_ports] = 0;
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

/// True when a datagram of the given address family is queued for `port`.
pub fn hasQueuedDatagramFor(port: u32, is_v6: bool) bool {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    const port_idx = findPortIdxLocked(port) orelse return false;
    for (0..QUEUE_DEPTH) |i| {
        if (queues[port_idx][i].valid and queues[port_idx][i].is_v6 == is_v6) return true;
    }
    return false;
}

/// True when a datagram is queued for `port` (epoll readiness).
pub fn hasQueuedDatagram(port: u32) bool {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    const port_idx = findPortIdxLocked(port) orelse return false;
    for (0..QUEUE_DEPTH) |i| {
        if (queues[port_idx][i].valid) return true;
    }
    return false;
}

/// Length of the datagram the next recvFromEx/recvFromV6Ex on `port` would
/// return (FIONREAD); 0 when none is queued for that address family.
pub fn nextDatagramLen(port: u32, is_v6: bool) u32 {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    const port_idx = findPortIdxLocked(port) orelse return 0;
    for (0..QUEUE_DEPTH) |i| {
        const entry = &queues[port_idx][i];
        if (entry.valid and entry.is_v6 == is_v6) return entry.data_len;
    }
    return 0;
}

/// J1: the socket choice and the queue insert share one critical section.
/// Previously the caller looked the index up under its own lock hold and
/// passed it here; a concurrent releasePort swap-remove in between could
/// point the index at a different port's queue, delivering the datagram to
/// the wrong socket (or effectively dropping it for the real owner).
/// Sockets sharing the port (SO_REUSEADDR / SO_REUSEPORT) are told apart by udp_port_policy.pickReceiver.
fn enqueue(port: u16, src_ip: [16]u8, src_port: u16, dst_port: u16, payload: []const u8, is_v6: bool) void {
    var notify_key: u32 = 0;
    const was_inserted = blk: {
        const saved = udp_lock.acquire();
        defer udp_lock.release(saved);

        const policy = @import("udp_port_policy.zig");
        var cand: [MAX_PORTS]u16 = undefined;
        var info: [MAX_PORTS]policy.Candidate = undefined;
        var n: usize = 0;
        for (0..num_ports) |i| {
            if (portNumber(ports[i]) == port and port_v6[i] == is_v6) {
                cand[n] = @intCast(i);
                info[n] = .{ .flags = port_opts[i].flags, .seq = port_seq[i], .peer_port = port_peer[i], .peer_ip = port_peer_ip[i] };
                n += 1;
            }
        }
        if (n == 0) {
            for (0..num_ports) |i| {
                if (portNumber(ports[i]) == port) {
                    cand[n] = @intCast(i);
                    info[n] = .{ .flags = port_opts[i].flags, .seq = port_seq[i], .peer_port = port_peer[i], .peer_ip = port_peer_ip[i] };
                    n += 1;
                }
            }
        }
        if (n == 0) break :blk false;
        // A connected socket whose peer is not this sender has no claim; one connected to it wins (see pickReceiverConnected).
        const pick = policy.pickReceiverConnected(info[0..n], src_ip, src_port) orelse break :blk false;
        const port_idx = cand[pick];
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
                notify_key = ports[port_idx];
                break :blk true;
            }
        }
        // Queue full - packet dropped (no accounting yet)
        break :blk false;
    };
    if (!was_inserted) return;
    // The datagram arrival is the readiness edge: without this notify, an
    // epoll item registered EPOLLIN on an empty queue never enters the ready
    // list (readiness is only re-probed on epoll_ctl and ready-list drain),
    // so epoll_wait blocks forever even though a datagram is queued. Notified
    // with udp_lock released — epollNotify walks pool/instance locks.
    @import("epoll.zig").epollNotify(.udp_socket, notify_key, @import("epoll.zig").EPOLLIN);
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
    const bound = portBound(hdr.dst_port);
    enqueue(hdr.dst_port, ip16, hdr.src_port, hdr.dst_port, data[8..][0..actual_payload], false);
    const unreach = @import("icmp_unreach_policy.zig");
    if (unreach.shouldReply(netif.isLoopback(src_ip) and netif.isLoopback(dst_ip), false, bound)) {
        sendPortUnreachable(src_ip, dst_ip, data, hdr.udp_len);
    }
}

/// ICMP port unreachable (type 3 code 3) for a loopback datagram nobody
/// receives: carries the offending IP header and first 8 payload bytes.
fn sendPortUnreachable(src_ip: [4]u8, dst_ip: [4]u8, udp: [*]const u8, udp_len: u16) void {
    const lo_dev = @import("lo.zig");
    const icmp_mod = @import("icmp.zig");
    var pkt: [128]u8 = @splat(0);
    const quote_udp: u16 = @min(udp_len, 8);
    // ICMP at 34: header (8) + quoted IP header (20) + quoted UDP bytes.
    ipv4.buildHeader(pkt[34 + 8 ..].ptr, src_ip, dst_ip, ipv4.PROTO_UDP, udp_len);
    @memcpy(pkt[34 + 8 + 20 ..][0..quote_udp], udp[0..quote_udp]);
    pkt[34] = 3;
    pkt[35] = 3;
    const icmp_len: u16 = 8 + 20 + quote_udp;
    bo.writeU16BeAt(&pkt, 36, ipv4.checksum(pkt[34..].ptr, icmp_len));
    ipv4.buildHeader(pkt[14..].ptr, dst_ip, src_ip, ipv4.PROTO_ICMP, icmp_len);
    const mac = netif.getMac();
    const frame_len = eth.buildFrame(&pkt, mac, mac, eth.ETHERTYPE_IPV4, 20 + icmp_len);
    _ = lo_dev.sendPacket(&pkt, frame_len);
    _ = icmp_mod;
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
    const bound = portBound(hdr.dst_port);
    enqueue(hdr.dst_port, src_ip, hdr.src_port, hdr.dst_port, data[8..][0..actual_payload], true);
    if (@import("icmp_unreach_policy.zig").shouldReplyV6(netif.isLoopbackV6(src_ip), netif.isLoopbackV6(dst_ip), bound)) {
        sendPortUnreachableV6(src_ip, dst_ip, data, hdr.udp_len);
    }
}

/// ICMPv6 port unreachable (type 1 code 4) for a ::1 datagram nobody receives:
/// carries the offending IPv6 header and the first 8 bytes of the UDP header.
fn sendPortUnreachableV6(src_ip: [16]u8, dst_ip: [16]u8, udp: [*]const u8, udp_len: u16) void {
    var pkt: [160]u8 = @splat(0);
    const icmp_off: u16 = 14 + ipv6.HEADER_LEN;
    const quote_udp: u16 = @min(udp_len, 8);
    // ICMPv6: type, code, checksum, 4 unused bytes, then the invoking packet.
    pkt[icmp_off] = 1;
    pkt[icmp_off + 1] = 4;
    ipv6.buildHeader(pkt[icmp_off + 8 ..].ptr, src_ip, dst_ip, ipv6.PROTO_UDP, udp_len);
    @memcpy(pkt[icmp_off + 8 + ipv6.HEADER_LEN ..][0..quote_udp], udp[0..quote_udp]);
    const icmp_len: u16 = 8 + ipv6.HEADER_LEN + quote_udp;
    // The reply travels from the destination back to the sender (both ::1).
    bo.writeU16BeAt(&pkt, icmp_off + 2, icmpv6.checksum(dst_ip, src_ip, pkt[icmp_off..].ptr, icmp_len));
    ipv6.buildHeader(pkt[14..].ptr, dst_ip, src_ip, ipv6.PROTO_ICMPV6, icmp_len);
    const mac = netif.getMac();
    const frame_len = eth.buildFrame(&pkt, mac, mac, eth.ETHERTYPE_IPV6, ipv6.HEADER_LEN + icmp_len);
    _ = lo.sendPacket(&pkt, frame_len);
}

pub fn recvFrom(port: u32, out_buf: [*]u8, out_len: u16, out_src_ip: *[4]u8, out_src_port: *u16) i64 {
    var full_len: u16 = 0;
    return recvFromEx(port, out_buf, out_len, out_src_ip, out_src_port, &full_len, false);
}

/// recvFrom variant reporting the datagram's full queued length and
/// optionally leaving the entry queued (MSG_PEEK). Returns the copied byte
/// count (min of full length and out_len), 0 when no datagram is queued.
/// `out_full_len` always receives the untruncated datagram length so the
/// caller can implement MSG_TRUNC.
pub fn recvFromEx(port: u32, out_buf: [*]u8, out_len: u16, out_src_ip: *[4]u8, out_src_port: *u16, out_full_len: *u16, peek: bool) i64 {
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
            out_full_len.* = entry.data_len;
            if (!peek) entry.valid = false;
            return n;
        }
    }
    return 0;
}

/// Drain one IPv6 datagram for `port` (SK-70).
pub fn recvFromV6(port: u32, out_buf: [*]u8, out_src_ip: *[16]u8, out_src_port: *u16) i64 {
    var full_len: u16 = 0;
    return recvFromV6Ex(port, out_buf, MAX_UDP_PAYLOAD_V6, out_src_ip, out_src_port, &full_len, false);
}

/// recvFromV6 variant with an explicit output cap, full-length reporting
/// and optional peek — same contract as recvFromEx.
pub fn recvFromV6Ex(port: u32, out_buf: [*]u8, out_len: u16, out_src_ip: *[16]u8, out_src_port: *u16, out_full_len: *u16, peek: bool) i64 {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);

    const port_idx = findPortIdxLocked(port) orelse return 0;
    for (0..QUEUE_DEPTH) |i| {
        const entry = &queues[port_idx][i];
        if (entry.valid and entry.is_v6) {
            const n = @min(entry.data_len, out_len);
            @memcpy(out_buf[0..n], entry.data[0..n]);
            out_src_ip.* = entry.src_ip;
            out_src_port.* = entry.src_port;
            out_full_len.* = entry.data_len;
            if (!peek) entry.valid = false;
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
    if (getPortOpts(src_port)) |po| {
        if (ip_opt_policy.ipv4NeedsPatch(po.ip)) ip_opt_policy.patchIpv4(send_pkt[14..][0..20], po.ip, ipv4.checksum);
    }

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
    if (getPortOpts(src_port)) |po| {
        if (ip_opt_policy.ipv6NeedsPatch(po.ip)) ip_opt_policy.patchIpv6(send_pkt[14..][0..40], po.ip);
    }
    const frame_len = eth.buildFrame(&send_pkt, dst_mac, our_mac, eth.ETHERTYPE_IPV6, ipv6.HEADER_LEN + udp_total);
    const ok = if (is_loop) lo.sendPacket(&send_pkt, frame_len) else nic.sendPacket(&send_pkt, frame_len);
    // SK-104: full-MTU TX success can raise the Path MTU early.
    if (ok) ipv6.noteFullSizeSend(dst_ip, ipv6.HEADER_LEN + udp_total);
    return ok;
}
