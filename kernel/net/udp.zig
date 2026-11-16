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
const mcast = @import("mcast_policy.zig");
const bo = @import("../lib/byte_order.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

/// Bound UDP sockets at once (Linux has no fixed limit; 64 sockets x 8 queued datagrams of 1.5 KiB is about 750 KiB).
const MAX_PORTS = 64;
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
/// Owner of each slot (Linux sk_uid: the creator's fsuid at socket(), kept across bind; SO_REUSEPORT only shares between equal owners)
/// and its bind order (later = larger).
var port_uid: [MAX_PORTS]u32 = @splat(0);
var port_seq: [MAX_PORTS]u32 = @splat(0);
var next_seq: u32 = 1;
/// Address family of the socket that owns each slot.
var port_v6: [MAX_PORTS]bool = @splat(false);
/// The slot belongs to an IPv4 ping socket (SOCK_DGRAM/IPPROTO_ICMP): its port is the ICMP ident, which shares no number space with
/// UDP ports (Linux ping_table), so no UDP path looks at it.
var port_ping: [MAX_PORTS]bool = @splat(false);
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
/// IPv4 address each slot is bound to (0.0.0.0 for the wildcard and for IPv6 sockets). Sockets on one port bound to different
/// addresses do not conflict, and a datagram goes to the socket bound to its destination before a wildcard one (Linux inet_rcv_saddr).
var port_local_ip: [MAX_PORTS][4]u8 = @splat(.{ 0, 0, 0, 0 });
/// IPv6 address each IPv6 slot is bound to (:: for the wildcard): the IPv6 counterpart of port_local_ip (Linux sk_v6_rcv_saddr).
var port_local_ip6: [MAX_PORTS][16]u8 = @splat(@splat(0));
/// IPv6 multicast groups each slot joined (IPV6_ADD_MEMBERSHIP); travels with the slot like port_opts.
var port_mc: [MAX_PORTS]mcast.Membership = @splat(.{});
/// IPv4 multicast groups each slot joined (IP_ADD_MEMBERSHIP).
var port_mc4: [MAX_PORTS]mcast.Membership4 = @splat(.{});
/// The interface an IPv6 slot is tied to by binding a scoped address (Linux sk_bound_dev_if), 0 for none.
var port_dev6: [MAX_PORTS]u8 = @splat(0);

/// The interface the socket with registry key `port` is tied to, 0 for none (or when it is gone).
pub fn boundDev6(port: u32) u8 {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    const i = findPortIdxLocked(port) orelse return 0;
    return port_dev6[i];
}

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

/// IPV6_ADD_MEMBERSHIP on the socket with registry key `port` (mcast_policy.join); -9 when the socket is gone.
pub fn mcJoin(port: u32, group: [16]u8, ifindex: u32, nic_active: bool) i64 {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    const i = findPortIdxLocked(port) orelse return -9;
    return mcast.join(&port_mc[i], group, ifindex, nic_active);
}

/// IPV6_DROP_MEMBERSHIP on the socket with registry key `port` (mcast_policy.drop).
pub fn mcDrop(port: u32, group: [16]u8, ifindex: u32) i64 {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    const i = findPortIdxLocked(port) orelse return -9;
    return mcast.drop(&port_mc[i], group, ifindex);
}

/// Whether this host is a member of `group` on interface `ifindex` (any interface when null): some IPv6 socket joined it there.
fn hostJoinedLocked(group: [16]u8, ifindex: ?u8) bool {
    for (0..num_ports) |i| {
        if (port_v6[i] and mcast.joinedOn(&port_mc[i], group, ifindex)) return true;
    }
    return false;
}

pub fn hostJoined(group: [16]u8, ifindex: ?u8) bool {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    return hostJoinedLocked(group, ifindex);
}

/// IP_ADD_MEMBERSHIP / IP_DROP_MEMBERSHIP on the socket with registry key `port` (mcast_policy.join4 / drop4); -9 when it is gone.
pub fn mcJoin4(port: u32, group: [4]u8, addr: [4]u8, index: u32, nic_active: bool, our: [4]u8) i64 {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    const i = findPortIdxLocked(port) orelse return -9;
    return mcast.join4(&port_mc4[i], group, addr, index, nic_active, our);
}

pub fn mcDrop4(port: u32, group: [4]u8, addr: [4]u8, index: u32, nic_active: bool, our: [4]u8) i64 {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    const i = findPortIdxLocked(port) orelse return -9;
    return mcast.drop4(&port_mc4[i], group, addr, index, nic_active, our);
}

/// Whether some IPv4 socket joined `group` on interface `ifindex`.
fn hostJoined4Locked(group: [4]u8, ifindex: ?u8) bool {
    for (0..num_ports) |i| {
        if (port_v6[i]) continue;
        const m = &port_mc4[i];
        for (0..m.n) |k| {
            if (@as(u32, @bitCast(m.group[k])) == @as(u32, @bitCast(group)) and (ifindex == null or m.ifindex[k] == ifindex.?)) return true;
        }
    }
    return false;
}

pub fn hostJoined4(group: [4]u8, ifindex: ?u8) bool {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    return hostJoined4Locked(group, ifindex);
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

/// connect(AF_UNSPEC) on the socket with registry key `key`: drops the peer filter, any pending error and the interface the socket
/// is tied to (Linux __udp_disconnect clears sk_bound_dev_if, also one a scoped bind set).
pub fn disconnect(key: u32) void {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    const i = findPortIdxLocked(key) orelse return;
    port_peer[i] = 0;
    port_peer_ip[i] = @splat(0);
    port_err[i] = 0;
    port_dev6[i] = 0;
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
            if (port_ping[i]) continue;
            if (portNumber(ports[i]) != local_port) continue;
            if (!@import("icmp_unreach_policy.zig").matchesConnected(.{ .src_port = local_port, .dst_port = peer_port }, local_port, port_peer[i] != 0, port_peer[i])) continue;
            port_err[i] = 111; // ECONNREFUSED
            hits[n] = ports[i];
            n += 1;
        }
    }
    for (hits[0..n]) |key| {
        @import("epoll.zig").epollNotify(.udp_socket, key, @import("epoll.zig").EPOLLERR);
        // sock_def_error_report: an O_ASYNC owner gets POLL_ERR.
        @import("../fs/vfs.zig").udpFasyncNotify(key, @import("../fs/fcntl_policy.zig").POLL_ERR);
    }
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
    return countSpaceLocked(port, false);
}

/// Number of sockets holding `port` among the ping sockets (`ping`) or the UDP sockets.
fn countSpaceLocked(port: u16, ping: bool) u32 {
    var n: u32 = 0;
    for (0..num_ports) |i| {
        if (port_ping[i] != ping) continue;
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
    port_ping[idx] = false;
    port_local_ip[idx] = .{ 0, 0, 0, 0 };
    port_local_ip6[idx] = @splat(0);
    port_mc[idx] = .{};
    port_mc4[idx] = .{};
    port_dev6[idx] = 0;
    for (0..QUEUE_DEPTH) |j| queues[idx][j].valid = false;
    num_ports += 1;
    return @intCast(idx);
}

/// net.ipv4.ping_group_range (/proc/sys/net/ipv4/ping_group_range): who may create a ping socket. Empty by default, as in Linux.
var ping_groups: @import("ping_policy.zig").GroupRange = .{};

/// Whether a task with effective gid `egid` and supplementary `groups` may create a ping socket (ping_init_sock).
pub fn pingGroupAllowed(egid: u32, groups: []const u32) bool {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    return @import("ping_policy.zig").groupAllowed(ping_groups, egid, groups);
}

/// The text of /proc/sys/net/ipv4/ping_group_range.
pub fn pingGroupRead(out: []u8) usize {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    return @import("ping_policy.zig").formatRange(ping_groups, out);
}

/// A write to /proc/sys/net/ipv4/ping_group_range: the bytes consumed or -EINVAL (ping_policy.writeRange).
pub fn pingGroupWrite(text: []const u8) i64 {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    return @import("ping_policy.zig").writeRange(&ping_groups, text);
}

/// Ping socket keys carry PING_KEY in the discriminator so they never equal a UDP socket's key; the ident is the low 16 bits.
pub const PING_KEY: u32 = 0x8000_0000;

/// Register a ping socket created by `uid` (an IPv6 one when `is_v6`) on the first free ident from 1 (Linux ping_get_port with ident
/// 0 walks a rover; any free ident does). IPv4 and IPv6 ping sockets share one ident table, as in Linux's ping_table. Returns the
/// registry key, or null when the table is full.
pub fn pingOpen(uid: u32, is_v6: bool) ?u32 {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    if (num_ports >= MAX_PORTS) return null;
    var ident: u32 = 1;
    while (ident <= 0xffff) : (ident += 1) {
        if (countSpaceLocked(@intCast(ident), true) != 0) continue;
        const key = PING_KEY | ident;
        const i = newSlotLocked(key, is_v6, uid);
        port_ping[i] = true;
        // INET_PROTOSW_REUSE: a ping socket starts with SO_REUSEADDR on, so default ping sockets may share an ident.
        port_opts[i].flags |= @import("udp_port_policy.zig").REUSEADDR_FLAG;
        return key;
    }
    return null;
}

/// bind() of the ping socket `old_key` to ident `ident` (0 keeps an automatic one) and address `addr` (`addr6` for an IPv6 one):
/// another ping socket holding the ident, of either family, conflicts unless both set SO_REUSEADDR, whatever their addresses
/// (ping_get_port). Returns the new key, or -98.
pub fn pingBind(old_key: u32, ident: u16, addr: [4]u8, addr6: [16]u8) i64 {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    const oi = findPortIdxLocked(old_key) orelse return -9;
    const want: u16 = if (ident == 0) portNumber(old_key) else ident;
    var used: u64 = 0;
    for (0..num_ports) |j| {
        if (!port_ping[j] or j == oi or portNumber(ports[j]) != want) continue;
        used |= @as(u64, 1) << @intCast((ports[j] >> 16) & 0x3f);
        if (!@import("ping_policy.zig").mayShareIdent(port_opts[oi].flags, port_opts[j].flags)) return -98;
    }
    // Hashing the socket (ping_get_port) puts it at the head of the chain: replies prefer it to earlier holders of the ident.
    port_seq[oi] = next_seq;
    next_seq +%= 1;
    port_local_ip[oi] = addr;
    port_local_ip6[oi] = addr6;
    if (want == portNumber(old_key)) return @intCast(old_key);
    const disc: u32 = @ctz(~used);
    const key = PING_KEY | (disc << 16) | want;
    ports[oi] = key;
    return @intCast(key);
}

/// The ping socket `key` gets its ident for good (its first send or connect, Linux inet_autobind → ping_get_port): it is hashed now,
/// so replies to its ident prefer it to sockets hashed earlier.
pub fn pingRehash(key: u32) void {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    const i = findPortIdxLocked(key) orelse return;
    port_seq[i] = next_seq;
    next_seq +%= 1;
}

/// An echo reply `msg` (ICMP header and data) from `src_ip` to `dst_ip` for ident `ident`: queued on the ping socket
/// ping_policy.pickReceiver picks among those holding the ident (ping_lookup, ping_queue_rcv_skb). Nobody holding it drops it.
pub fn deliverPing(ident: u16, src_ip: [4]u8, dst_ip: [4]u8, msg: []const u8) void {
    var notify_key: u32 = 0;
    blk: {
        const saved = udp_lock.acquire();
        defer udp_lock.release(saved);
        const pp = @import("ping_policy.zig");
        var holders: [MAX_PORTS]pp.Holder = undefined;
        var slots: [MAX_PORTS]usize = undefined;
        var n: usize = 0;
        for (0..num_ports) |k| {
            // An IPv4 reply only goes to an IPv4 ping socket (ping_lookup matches sk_family to the packet's protocol).
            if (!port_ping[k] or port_v6[k] or portNumber(ports[k]) != ident) continue;
            holders[n] = .{ .seq = port_seq[k], .bound = port_local_ip[k], .peer = port_peer_ip[k][0..4].* };
            slots[n] = k;
            n += 1;
        }
        const pick = pp.pickReceiver(holders[0..n], src_ip, dst_ip) orelse break :blk;
        {
            const i = slots[pick];
            const actual = @min(msg.len, MAX_UDP_PAYLOAD);
            for (0..QUEUE_DEPTH) |j| {
                const e = &queues[i][j];
                if (e.valid) continue;
                e.src_ip = @splat(0);
                @memcpy(e.src_ip[0..4], &src_ip);
                e.src_port = 0;
                e.dst_port = ident;
                e.data_len = @intCast(actual);
                @memcpy(e.data[0..actual], msg[0..actual]);
                e.is_v6 = false;
                e.valid = true;
                notify_key = ports[i];
                break;
            }
        }
    }
    if (notify_key == 0) return;
    @import("epoll.zig").epollNotify(.udp_socket, notify_key, @import("epoll.zig").EPOLLIN);
    @import("../fs/vfs.zig").udpFasyncNotify(notify_key, @import("../fs/fcntl_policy.zig").POLL_IN);
}

/// An ICMPv6 echo reply `msg` from `src_ip` to `dst_ip` for ident `ident`: queued on the IPv6 ping socket ping_policy.pickReceiver6
/// picks among the IPv6 ones holding the ident (ping_lookup). Nobody holding it drops it.
pub fn deliverPing6(ident: u16, src_ip: [16]u8, dst_ip: [16]u8, msg: []const u8) void {
    var notify_key: u32 = 0;
    blk: {
        const saved = udp_lock.acquire();
        defer udp_lock.release(saved);
        const pp = @import("ping_policy.zig");
        var holders: [MAX_PORTS]pp.Holder6 = undefined;
        var slots: [MAX_PORTS]usize = undefined;
        var n: usize = 0;
        for (0..num_ports) |k| {
            if (!port_ping[k] or !port_v6[k] or portNumber(ports[k]) != ident) continue;
            holders[n] = .{ .seq = port_seq[k], .bound = port_local_ip6[k] };
            slots[n] = k;
            n += 1;
        }
        const pick = pp.pickReceiver6(holders[0..n], dst_ip) orelse break :blk;
        const i = slots[pick];
        const actual = @min(msg.len, MAX_UDP_PAYLOAD_V6);
        for (0..QUEUE_DEPTH) |j| {
            const e = &queues[i][j];
            if (e.valid) continue;
            e.src_ip = src_ip;
            e.src_port = 0;
            e.dst_port = ident;
            e.data_len = @intCast(actual);
            @memcpy(e.data[0..actual], msg[0..actual]);
            e.is_v6 = true;
            e.valid = true;
            notify_key = ports[i];
            break;
        }
    }
    if (notify_key == 0) return;
    @import("epoll.zig").epollNotify(.udp_socket, notify_key, @import("epoll.zig").EPOLLIN);
    @import("../fs/vfs.zig").udpFasyncNotify(notify_key, @import("../fs/fcntl_policy.zig").POLL_IN);
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
/// set before bind) and recording the IPv4 address `addr` it is bound to. A port another socket holds can be joined only when the sharing
/// policy allows it with every holder whose address conflicts (tcp_port_policy.addrsConflict, addrsConflict6 for IPv6). On success
/// returns 0 and the socket's new discriminator in `out_disc`; -98 (EADDRINUSE) when the port is taken or the table is full, -9 when
/// `old_key` is gone. `dev6` is the interface a scoped IPv6 address ties the socket to (0 for none): two IPv6 sockets tied to
/// different interfaces do not conflict (bind_addr_policy.boundDevsConflict).
pub fn rebind(old_key: u32, new_port: u16, addr: [4]u8, addr6: [16]u8, dev6: u8, out_disc: *u16) i64 {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);

    const oi = findPortIdxLocked(old_key) orelse return -9;
    if (portNumber(old_key) == new_port) {
        out_disc.* = @truncate(old_key >> 16);
        port_local_ip[oi] = addr;
        port_local_ip6[oi] = addr6;
        port_dev6[oi] = dev6;
        return 0;
    }
    const mine = port_opts[oi];
    const uid = port_uid[oi];
    var used: u64 = 0;
    for (0..num_ports) |j| {
        if (port_ping[j]) continue;
        if (portNumber(ports[j]) != new_port) continue;
        used |= @as(u64, 1) << @intCast(ports[j] >> 16);
        if (!port_v6[j] and !port_v6[oi] and !@import("tcp_port_policy.zig").addrsConflict(addr, port_local_ip[j])) continue;
        if (port_v6[j] and port_v6[oi] and !@import("bind_addr_policy.zig").boundDevsConflict(dev6, port_dev6[j])) continue;
        if (port_v6[j] and port_v6[oi] and !@import("tcp_port_policy.zig").addrsConflict6(addr6, port_local_ip6[j])) continue;
        if (!@import("udp_port_policy.zig").mayShare(mine.flags, port_opts[j].flags, uid, port_uid[j])) return -98;
    }
    if (num_ports >= MAX_PORTS) return -98;
    const disc: u16 = @intCast(@ctz(~used));
    const ni = newSlotLocked(new_port | (@as(u32, disc) << 16), port_v6[oi], uid);
    port_opts[ni] = mine;
    port_local_ip[ni] = addr;
    port_local_ip6[ni] = addr6;
    port_dev6[ni] = dev6;
    port_mc[ni] = port_mc[oi];
    port_mc4[ni] = port_mc4[oi];
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
            port_ping[i] = port_ping[num_ports];
            port_ping[num_ports] = false;
            port_local_ip[i] = port_local_ip[num_ports];
            port_local_ip[num_ports] = .{ 0, 0, 0, 0 };
            port_local_ip6[i] = port_local_ip6[num_ports];
            port_local_ip6[num_ports] = @splat(0);
            port_mc[i] = port_mc[num_ports];
            port_mc[num_ports] = .{};
            port_mc4[i] = port_mc4[num_ports];
            port_mc4[num_ports] = .{};
            port_dev6[i] = port_dev6[num_ports];
            port_dev6[num_ports] = 0;
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
/// Candidates are the sockets bound to the destination address (`dst_ip` for IPv4, `dst_ip6` for an IPv6 datagram to an IPv6
/// socket), else the wildcard ones, each preferring the datagram's address family. Returns whether any socket claims the datagram (false: ICMP port unreachable).
fn enqueue(port: u16, src_ip: [16]u8, src_port: u16, dst_port: u16, dst_ip: [4]u8, dst_ip6: [16]u8, payload: []const u8, is_v6: bool) bool {
    var notify_key: u32 = 0;
    var claimed = false;
    const was_inserted = blk: {
        const saved = udp_lock.acquire();
        defer udp_lock.release(saved);

        const policy = @import("udp_port_policy.zig");
        var cand: [MAX_PORTS]u16 = undefined;
        var info: [MAX_PORTS]policy.Candidate = undefined;
        var n: usize = 0;
        const rounds = [_][2]bool{ .{ true, true }, .{ true, false }, .{ false, true }, .{ false, false } };
        for (rounds) |r| {
            for (0..num_ports) |i| {
                if (port_ping[i]) continue;
                if (portNumber(ports[i]) != port or (r[1] and port_v6[i] != is_v6)) continue;
                const takes = if (is_v6 and port_v6[i])
                    @import("tcp_port_policy.zig").listenerTakes6(port_local_ip6[i], dst_ip6, r[0])
                else
                    @import("tcp_port_policy.zig").listenerTakes(port_local_ip[i], dst_ip, r[0]);
                if (!takes) continue;
                cand[n] = @intCast(i);
                info[n] = .{ .flags = port_opts[i].flags, .seq = port_seq[i], .peer_port = port_peer[i], .peer_ip = port_peer_ip[i] };
                n += 1;
            }
            if (n != 0) break;
        }
        if (n == 0) break :blk false;
        claimed = true;
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
    if (!was_inserted) return claimed;
    // The datagram arrival is the readiness edge: without this notify, an
    // epoll item registered EPOLLIN on an empty queue never enters the ready
    // list (readiness is only re-probed on epoll_ctl and ready-list drain),
    // so epoll_wait blocks forever even though a datagram is queued. Notified
    // with udp_lock released — epollNotify walks pool/instance locks.
    @import("epoll.zig").epollNotify(.udp_socket, notify_key, @import("epoll.zig").EPOLLIN);
    // sock_def_readable: every queued datagram signals an O_ASYNC owner with POLL_IN.
    @import("../fs/vfs.zig").udpFasyncNotify(notify_key, @import("../fs/fcntl_policy.zig").POLL_IN);
    return true;
}

/// An IPv6 datagram to a multicast group goes to every IPv6 socket on its port that mcast_policy.socketMatches and socketAccepts, a
/// copy each (Linux __udp6_lib_mcast_deliver), and only when this host is a member of the group on `ifindex`, the interface it
/// arrived on (ip6_mc_input), or the group is all-nodes. Nobody taking it is not an error: a group datagram never draws an ICMP port
/// unreachable.
fn enqueueMcast(port: u16, src_ip: [16]u8, src_port: u16, group: [16]u8, payload: []const u8, ifindex: u8) void {
    var keys: [MAX_PORTS]u32 = undefined;
    var n: usize = 0;
    {
        const saved = udp_lock.acquire();
        defer udp_lock.release(saved);
        if (!mcast.alwaysJoined(group) and !hostJoinedLocked(group, ifindex)) return;
        const actual = @min(payload.len, MAX_UDP_PAYLOAD);
        for (0..num_ports) |i| {
            if (port_ping[i]) continue;
            if (portNumber(ports[i]) != port or !port_v6[i]) continue;
            if (!mcast.socketMatches(port_local_ip6[i], group, port_peer[i], port_peer_ip[i], src_ip, src_port, port_dev6[i], ifindex)) continue;
            if (!mcast.socketAccepts(&port_mc[i], port_opts[i].ip.mc_all, group)) continue;
            for (0..QUEUE_DEPTH) |j| {
                const e = &queues[i][j];
                if (e.valid) continue;
                e.src_ip = src_ip;
                e.src_port = src_port;
                e.dst_port = port;
                e.data_len = @intCast(actual);
                @memcpy(e.data[0..actual], payload[0..actual]);
                e.is_v6 = true;
                e.valid = true;
                keys[n] = ports[i];
                n += 1;
                break;
            }
        }
    }
    for (keys[0..n]) |key| {
        @import("epoll.zig").epollNotify(.udp_socket, key, @import("epoll.zig").EPOLLIN);
        @import("../fs/vfs.zig").udpFasyncNotify(key, @import("../fs/fcntl_policy.zig").POLL_IN);
    }
}

/// The IPv4 counterpart of enqueueMcast (Linux __udp4_lib_mcast_deliver, ip_check_mc_rcu): a copy to every IPv4 socket on the port
/// that socketMatches4 and socketAccepts4, while this host is a member of the group on `ifindex`, the interface the datagram arrived
/// on, or it is 224.0.0.1.
fn enqueueMcast4(port: u16, src_ip: [16]u8, src_port: u16, group: [4]u8, payload: []const u8, ifindex: u8) void {
    var keys: [MAX_PORTS]u32 = undefined;
    var n: usize = 0;
    {
        const saved = udp_lock.acquire();
        defer udp_lock.release(saved);
        if (!mcast.alwaysJoined4(group) and !hostJoined4Locked(group, ifindex)) return;
        const actual = @min(payload.len, MAX_UDP_PAYLOAD);
        for (0..num_ports) |i| {
            if (port_ping[i]) continue;
            if (portNumber(ports[i]) != port or port_v6[i]) continue;
            if (!mcast.socketMatches4(port_local_ip[i], group, port_peer[i], port_peer_ip[i], src_ip[0..4].*, src_port)) continue;
            if (!mcast.socketAccepts4(&port_mc4[i], port_opts[i].ip.mc4_all, group, ifindex)) continue;
            for (0..QUEUE_DEPTH) |j| {
                const e = &queues[i][j];
                if (e.valid) continue;
                e.src_ip = src_ip;
                e.src_port = src_port;
                e.dst_port = port;
                e.data_len = @intCast(actual);
                @memcpy(e.data[0..actual], payload[0..actual]);
                e.is_v6 = false;
                e.valid = true;
                keys[n] = ports[i];
                n += 1;
                break;
            }
        }
    }
    for (keys[0..n]) |key| {
        @import("epoll.zig").epollNotify(.udp_socket, key, @import("epoll.zig").EPOLLIN);
        @import("../fs/vfs.zig").udpFasyncNotify(key, @import("../fs/fcntl_policy.zig").POLL_IN);
    }
}

pub fn handlePacket(src_ip: [4]u8, dst_ip: [4]u8, data: [*]const u8, len: u32) void {
    handlePacketOn(src_ip, dst_ip, data, len, @intCast(@import("bind_addr_policy.zig").NIC_IFINDEX));
}

/// handlePacket for a datagram that arrived on interface `ifindex` (1 lo, 2 the NIC).
pub fn handlePacketOn(src_ip: [4]u8, dst_ip: [4]u8, data: [*]const u8, len: u32, ifindex: u8) void {
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
    if (mcast.isMulticast4(dst_ip)) {
        enqueueMcast4(hdr.dst_port, ip16, hdr.src_port, dst_ip, data[8..][0..actual_payload], ifindex);
        return;
    }
    const bound = enqueue(hdr.dst_port, ip16, hdr.src_port, hdr.dst_port, dst_ip, @splat(0), data[8..][0..actual_payload], false);
    const unreach = @import("icmp_unreach_policy.zig");
    if (unreach.shouldReply(netif.isLocal4(src_ip) and netif.isLocal4(dst_ip), false, bound)) {
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
    handlePacketV6On(src_ip, dst_ip, data, len, @intCast(@import("bind_addr_policy.zig").NIC_IFINDEX));
}

/// handlePacketV6 for a datagram that arrived on interface `ifindex` (1 lo, 2 the NIC).
pub fn handlePacketV6On(src_ip: [16]u8, dst_ip: [16]u8, data: [*]const u8, len: u32, ifindex: u8) void {
    const hdr = udp_util.parseHeader(data, len) orelse return;
    if (hdr.udp_len < udp_util.HEADER_LEN or hdr.udp_len > len) return;

    // IPv6 UDP checksum is mandatory; reject if the field is zero or wrong.
    const wire_csum = bo.readU16BeAt(data, 6);
    if (wire_csum == 0) return;
    const expect = udp_util.checksumV6(src_ip, dst_ip, data, hdr.udp_len);
    if (wire_csum != expect) return;

    const actual_payload = @min(hdr.payload_len, @as(u16, MAX_UDP_PAYLOAD_V6));
    if (8 + actual_payload > len) return;
    if (mcast.isMulticast(dst_ip)) {
        enqueueMcast(hdr.dst_port, src_ip, hdr.src_port, dst_ip, data[8..][0..actual_payload], ifindex);
        return;
    }
    const bound = enqueue(hdr.dst_port, src_ip, hdr.src_port, hdr.dst_port, .{ 0, 0, 0, 0 }, dst_ip, data[8..][0..actual_payload], true);
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

/// The interface an IPv6 datagram from the socket with key `key` to `dst` (sendto's sin6_scope_id `scope_id`, 0 for none) leaves
/// through, 0 for the default route (bind_addr_policy.sendOif6); bind_addr_policy.routeErrno6 says whether it has a route there.
pub fn sendOif6(key: u32, dst: [16]u8, scope_id: u32) u8 {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    const i = findPortIdxLocked(key) orelse return @import("bind_addr_policy.zig").sendOif6(dst, scope_id, 0, 0);
    return @import("bind_addr_policy.zig").sendOif6(dst, scope_id, port_dev6[i], port_opts[i].ip.mc_if);
}

/// connect() of the IPv6 socket with key `key` to `dst`%`scope_id`: ties it to the interface bind_addr_policy.connectDev6 picks
/// (also when the route check then fails, as Linux does) and returns that errno, 0 when the connect may go on.
pub fn connectDev6(key: u32, dst: [16]u8, scope_id: u32) i64 {
    const saved = udp_lock.acquire();
    defer udp_lock.release(saved);
    const i = findPortIdxLocked(key) orelse return -9;
    const r = @import("bind_addr_policy.zig").connectDev6(dst, scope_id, port_dev6[i], port_opts[i].ip.mc_if);
    port_dev6[i] = r.dev;
    return r.err;
}

pub fn sendTo(dst_ip: [4]u8, dst_port: u16, src_port: u16, data: [*]const u8, data_len: u16) bool {
    return sendToFrom(.{ 0, 0, 0, 0 }, dst_ip, dst_port, src_port, data, data_len);
}

/// sendTo from the socket with registry key `src_key` (its port in the low 16 bits, see `ports`), bound to the IPv4 address `bound`
/// (0.0.0.0 when unbound): the source address follows tcp_port_policy.sourceAddr, so a loopback datagram leaves from the bound
/// loopback address or else 127.0.0.1. The IP options are that socket's own, also when other sockets share its port.
pub fn sendToFrom(bound: [4]u8, dst_ip: [4]u8, dst_port: u16, src_key: u32, data: [*]const u8, data_len: u16) bool {
    if (data_len > MAX_UDP_PAYLOAD) return false;
    const src_port = portNumber(src_key);
    const opts4: ip_opt_policy.IpOpts = if (getPortOpts(src_key)) |po| po.ip else .{};

    const our_mac = netif.getMac();
    // F2: 127.0.0.0/8 goes to the loopback device — no ARP, no hardware NIC.
    const loopback = netif.isLocal4(dst_ip);
    // Limited broadcast has no ARP entry (arp.resolve would fail and nothing
    // would ever be transmitted) — use the broadcast MAC directly. DHCP
    // DISCOVER/REQUEST depend on this.
    const group = mcast.isMulticast4(dst_ip);
    // IP_MULTICAST_IF naming lo: the datagram goes out lo alone (Linux ip_mc_output on the loopback device), whatever
    // IP_MULTICAST_LOOP and IP_MULTICAST_TTL say.
    const out_if: u8 = if (opts4.mc4_index != 0) opts4.mc4_index else @intCast(@import("bind_addr_policy.zig").NIC_IFINDEX);
    const via_lo = loopback or (group and out_if == lo.IFINDEX);
    const dst_mac = if (via_lo)
        our_mac
    else if (dst_ip[0] == 255 and dst_ip[1] == 255 and dst_ip[2] == 255 and dst_ip[3] == 255)
        [6]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }
    else if (group)
        mcast.multicastMac4(dst_ip)
    else resolve: {
        // An off-link destination is reached through the gateway, whose MAC is the one to resolve.
        const hop = netif.nextHop4(dst_ip);
        break :resolve arp.resolve(hop) orelse {
            arp.sendArpRequest(hop);
            return false;
        };
    };

    // A 127/8 destination is reached from the bound loopback address, else from 127.0.0.1 (Linux's local route), so the
    // peer's replies stay on lo.
    // A group datagram from an unbound socket leaves from the IP_MULTICAST_IF address when one was given (Linux takes the source from
    // inet->mc_addr).
    const our_ip = if (mcast.multicastSource4(group, bound, opts4.mc4_addr)) |a| a else @import("tcp_port_policy.zig").sourceAddr(bound, dst_ip, netif.getOurIp());
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
    if (ip_opt_policy.ipv4NeedsPatch(opts4)) ip_opt_policy.patchIpv4(send_pkt[14..][0..20], opts4, ipv4.checksum);
    // A datagram to a group carries IP_MULTICAST_TTL (default 1), not the unicast TTL.
    if (group) ip_opt_policy.setTtl4(send_pkt[14..][0..20], opts4.mc4_ttl, ipv4.checksum);

    // Build ethernet frame
    const frame_len = eth.buildFrame(&send_pkt, dst_mac, our_mac, eth.ETHERTYPE_IPV4, 20 + udp_total);
    // IP_MULTICAST_LOOP: when this host is a member of the group on the outgoing interface (the NIC here) a copy is delivered locally
    // too, arriving on that interface (Linux ip_mc_output, ip_check_mc_rcu, dev_loopback_xmit).
    if (group and !via_lo and opts4.mc4_loop and (mcast.alwaysJoined4(dst_ip) or hostJoined4(dst_ip, out_if))) _ = lo.sendPacketOn(&send_pkt, frame_len, out_if);

    const ok = if (via_lo) lo.sendPacket(&send_pkt, frame_len) or lo.dropIsLoss(frame_len) else nic.sendPacket(&send_pkt, frame_len);
    // SK-104: full-MTU TX success can raise the Path MTU early.
    if (ok) ipv4.noteFullSizeSend(dst_ip, ipv4.HEADER_LEN + udp_total);
    return ok;
}

/// Send a UDP datagram over IPv6 (SK-70/87). On-link via NDP; off-link via default router.
pub fn sendToV6(dst_ip: [16]u8, dst_port: u16, src_port: u16, data: [*]const u8, data_len: u16) bool {
    return sendToV6From(@splat(0), dst_ip, dst_port, src_port, 0, data, data_len);
}

/// sendToV6 from the socket with registry key `src_key`, bound to the IPv6 address `bound` (:: when unbound): the source address
/// follows tcp_port_policy.sourceAddr6, so a datagram leaves from the bound unicast address, also when it goes to ::1. The IPv6 options
/// are that socket's own, also when other sockets share its port. `oif` is the interface it leaves through (sendOif6, 0 for the
/// default route); a group copy looped back to this host arrives on it.
pub fn sendToV6From(bound: [16]u8, dst_ip: [16]u8, dst_port: u16, src_key: u32, oif: u8, data: [*]const u8, data_len: u16) bool {
    if (data_len > MAX_UDP_PAYLOAD_V6) return false;
    const src_port = portNumber(src_key);

    const nh = ndp.resolveNextHop(dst_ip);
    // K3: ::1 short-circuits NDP and the wire — loop back via lo.
    // An address of this host is reached through lo too (Linux routes it via the local table).
    const is_loop = netif.isLoopbackV6(dst_ip) or ndp.isOwnAddress(dst_ip, netif.getMac());
    const dst_mac = if (is_loop) netif.getMac() else nh.mac orelse {
        if (nh.solicit) |t| icmpv6.sendNeighborSolicitation(t);
        return false;
    };

    const our_mac = netif.getMac();
    // An unbound socket sends to ::1 from ::1 (mirrors the IPv4 lo choice), elsewhere from the selected source address.
    const our_ip = @import("tcp_port_policy.zig").sourceAddr6(bound, dst_ip, if (is_loop) dst_ip else ndp.selectSourceAddress(dst_ip, our_mac));
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
    const opts: ip_opt_policy.IpOpts = if (getPortOpts(src_key)) |po| po.ip else .{};
    if (ip_opt_policy.ipv6NeedsPatch(opts)) ip_opt_policy.patchIpv6(send_pkt[14..][0..40], opts);
    const group = mcast.isMulticast(dst_ip);
    // A datagram to a group carries IPV6_MULTICAST_HOPS (default 1), not the unicast hop limit.
    if (group) send_pkt[14 + 7] = opts.mc_hops;
    const frame_len = eth.buildFrame(&send_pkt, dst_mac, our_mac, eth.ETHERTYPE_IPV6, ipv6.HEADER_LEN + udp_total);
    // IPV6_MULTICAST_LOOP: when this host is a member of the group on the outgoing interface a copy is delivered locally too,
    // arriving on that interface (Linux ip6_finish_output2 checks ipv6_chk_mcast_addr on the device).
    const out_if6 = mcast.outInterface(oif);
    if (group and opts.mc_loop and (mcast.alwaysJoined(dst_ip) or hostJoined(dst_ip, out_if6))) _ = lo.sendPacketOn(&send_pkt, frame_len, out_if6);
    const ok = if (is_loop) lo.sendPacket(&send_pkt, frame_len) or lo.dropIsLoss(frame_len) else nic.sendPacket(&send_pkt, frame_len);
    // SK-104: full-MTU TX success can raise the Path MTU early.
    if (ok) ipv6.noteFullSizeSend(dst_ip, ipv6.HEADER_LEN + udp_total);
    return ok;
}
