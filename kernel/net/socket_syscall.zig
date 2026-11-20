// kernel/net/socket_syscall.zig — Network socket syscall implementations
//
// Extracted from syscall_entry.zig: socket, bind, listen, accept, accept4,
// connect, shutdown, socketpair, sendto, recvfrom, sendmsg, recvmsg,
// setsockopt, getsockopt, getsockname, getpeername, net_poll,
// recvmmsg, sendmmsg.

const std = @import("std");
const sched_mod = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const cap_mod = @import("../ipc/capability.zig");
const vfs_mod = @import("../fs/vfs.zig");
const net_mod = @import("mod.zig");
const udp = @import("udp.zig");
const udp_util = @import("udp_util.zig");
const sa = @import("sockaddr_util.zig");
const netif = @import("netif.zig");
const ndp = @import("ndp.zig");
const copy = @import("../mm/copy_from_user.zig");
const bo = @import("../lib/byte_order.zig");
const socketpair_policy = @import("socketpair_policy.zig");
const message_batch_policy = @import("message_batch_policy.zig");
const accept4_policy = @import("accept4_policy.zig");
const bind_addr_policy = @import("bind_addr_policy.zig");
const nic_mod = @import("nic.zig");
const ip_opt_policy = @import("ip_opt_policy.zig");
const ip_cmsg_policy = @import("ip_cmsg_policy.zig");

const ENOTCONN: i64 = -107;
const SOCKADDR_UN_PATH_OFFSET: u32 = 2;
const SOCKADDR_IN_MIN_LEN: u32 = 8;

// ── FD allocation helpers ──────────────────────────────────────────

pub fn allocTcpFd(fd_table: *vfs_mod.FdTable, tcb_idx: u32) i64 {
    const slot = fd_table.allocFd() orelse return -24; // EMFILE
    fd_table.fds[slot] = .{
        .fd_type = .tcp_socket,
        .tcb_idx = tcb_idx,
        .writable = true,
    };
    fd_table.publishFd(slot);
    return @intCast(slot);
}

pub fn allocUnixFd(fd_table: *vfs_mod.FdTable, unix_sock_idx: u32) i32 {
    const slot = fd_table.allocFd() orelse return -24; // EMFILE
    fd_table.fds[slot] = .{
        .fd_type = .unix_socket,
        .unix_sock_idx = unix_sock_idx,
        .writable = true,
    };
    fd_table.publishFd(slot);
    return @intCast(slot);
}

// ── Raw IPv4 and IPv6 sockets (net/raw_icmp.zig) ───────────────────

/// socket(AF_INET, SOCK_RAW, protocol) or, when `v6`, socket(AF_INET6, SOCK_RAW, protocol): needs CAP_NET_RAW (inet_create /
/// inet6_create: EPERM). Either family takes any protocol from 1 to 255 (raw_icmp_policy.protocolErrno, protocolErrno6).
fn rawCreate(protocol: u32, v6: bool) i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;
    const rp = @import("raw_icmp_policy.zig");
    const perr = if (v6) rp.protocolErrno6(protocol) else rp.protocolErrno(protocol);
    if (!cap_mod.hasSysCap(cur_idx, "cap_net_raw")) return -1; // EPERM
    if (perr != 0) return perr;
    const raw = @import("raw_icmp.zig");
    const idx = raw.open(v6, protocol) orelse return -105; // ENOBUFS
    const fd_slot = t.fd_table.allocFd() orelse {
        raw.release(idx);
        return -24; // EMFILE
    };
    t.fd_table.fds[fd_slot] = .{ .fd_type = .raw_socket, .raw_idx = idx, .writable = true };
    t.fd_table.publishFd(fd_slot);
    return @intCast(fd_slot);
}

/// A user sockaddr_in of `addr_len` bytes at `addr_ptr`: its family and address (the port is not looked at).
fn readInet4(addr_ptr: u64, addr_len: u32) union(enum) { ok: struct { family: u16, addr: [4]u8 }, err: i64 } {
    if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000) return .{ .err = -14 };
    var b: [16]u8 = @splat(0);
    const n = @min(addr_len, 16);
    if (n >= 2 and copy.copyFromUser(b[0..n], @ptrFromInt(addr_ptr), n) != n) return .{ .err = -14 };
    return .{ .ok = .{ .family = bo.readU16Le(b[0..2]), .addr = b[4..8].* } };
}

/// A user sockaddr_in6 of `addr_len` bytes at `addr_ptr` (the first 24 are enough, as for rawv6_sendmsg): family, port, address,
/// scope (0 when not given).
fn readInet6(addr_ptr: u64, addr_len: u32) union(enum) { ok: struct { family: u16, port: u16, addr: [16]u8, scope: u32 }, err: i64 } {
    if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000) return .{ .err = -14 };
    var b: [28]u8 = @splat(0);
    const n = @min(addr_len, 28);
    if (n >= 2 and copy.copyFromUser(b[0..n], @ptrFromInt(addr_ptr), n) != n) return .{ .err = -14 };
    return .{ .ok = .{ .family = bo.readU16Le(b[0..2]), .port = bo.readU16BeAt(&b, 2), .addr = b[8..24].*, .scope = bo.readU32Le(b[24..28]) } };
}

/// sendto/send/write/sendmsg on an IPv6 raw socket: the destination is checked first (rawv6_sendmsg), then the control messages
/// (`control`, sendmsg's msg_control, else empty: ip6_datagram_send_ctl), then the length; :: goes to ::1. IPV6_HOPLIMIT /
/// IPV6_TCLASS replace the socket's values for this packet, IPV6_PKTINFO names its source and interface. An IPV6_HDRINCL packet
/// goes out as written.
fn rawSendFrom6(d: *const vfs_mod.FileDescriptor, msg: []const u8, to: ?RawDest, control: []const u8) i64 {
    const raw = @import("raw_icmp.zig");
    const rp = @import("raw_icmp_policy.zig");
    var dst = raw.peerAddr6(d.raw_idx);
    var scope: u32 = 0;
    if (to) |a| {
        const parsed = switch (readInet6(a.ptr, a.len)) {
            .ok => |v| v,
            .err => |e| return e,
        };
        const rc = rp.sendtoErrno6(true, a.len, parsed.family, parsed.port, false, raw.protocolOf(d.raw_idx));
        if (rc != 0) return rc;
        dst = parsed.addr;
        scope = parsed.scope;
    } else {
        const rc = rp.sendtoErrno6(false, 0, 0, 0, raw.isConnected(d.raw_idx), raw.protocolOf(d.raw_idx));
        if (rc != 0) return rc;
    }
    const ip = rawIpOpts(d.raw_idx);
    const oif6 = bind_addr_policy.sendOif6(dst, scope, 0, ip.mc_if);
    const ctx6: ip_cmsg_policy.Ctx6 = .{ .pre_oif = oif6, .nic_active = nic_mod.isActive(), .isOwnNic = isOwnNicAddr6 };
    const ov6 = switch (ip_cmsg_policy.parseSendRaw6(control, sendCaps(), ctx6)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    // IPV6_HDRINCL: `msg` is the whole packet, header first, sent as written once routed (rawv6_send_hdrinc); otherwise the
    // ICMPv6 type and code are read before the route is looked up (rawv6_probe_proto_opt).
    const hdrincl = rawIpOpts(d.raw_idx).hdrincl;
    if (!hdrincl) {
        const lrc = rp.lengthErrno6(raw.protocolOf(d.raw_idx), raw.checksumOffset(d.raw_idx), msg.len);
        if (lrc != 0) return lrc;
    }
    const to6 = rp.dest6(dst) orelse return -101; // ENETUNREACH: a v4-mapped address has no IPv6 route
    if (hdrincl) {
        const hrc = rp.hdrinclErrno6(msg.len, @import("netif.zig").getMtu());
        if (hrc != 0) return hrc;
        const hs = raw.sendHdrincl6(to6, msg);
        return if (hs < 0) hs else @intCast(msg.len);
    }
    const src6 = if (ov6.pktinfo and !std.mem.allEqual(u8, &ov6.src, 0)) ov6.src else raw.boundAddr6(d.raw_idx);
    const sent = raw.send6(src6, to6, @truncate(raw.protocolOf(d.raw_idx)), raw.checksumOffset(d.raw_idx), msg, ip, ov6.hops, ov6.tclass);
    return if (sent < 0) sent else @intCast(msg.len);
}

pub const RawDest = struct { ptr: u64, len: u32 };

/// sendto/send/write/sendmsg on a raw ICMP socket: `msg` (the ICMP message) to the address at `to` (ptr, len), or to the connected
/// peer. `control` is sendmsg's msg_control (empty otherwise): raw_sendmsg parses it with ip_cmsg_send once the destination is
/// known (an IPv6 socket: rawSendFrom6). IP_TTL / IP_TOS replace the socket's values for this datagram, IP_PKTINFO names its
/// source; an IP_HDRINCL socket's header is left as written (only a zero source is filled) and any IP options are EINVAL there.
pub fn rawSendFrom(d: *const vfs_mod.FileDescriptor, msg: []const u8, to: ?RawDest, control: []const u8) i64 {
    const raw = @import("raw_icmp.zig");
    const rp = @import("raw_icmp_policy.zig");
    if (raw.isV6(d.raw_idx)) return rawSendFrom6(d, msg, to, control);
    var dst = raw.peerAddr(d.raw_idx);
    if (to) |a| {
        const r = readInet4(a.ptr, a.len);
        const parsed = switch (r) {
            .ok => |v| v,
            .err => |e| return e,
        };
        const rc = rp.sendtoErrno(true, a.len, parsed.family, false);
        if (rc != 0) return rc;
        dst = parsed.addr;
    } else {
        const rc = rp.sendtoErrno(false, 0, 0, raw.isConnected(d.raw_idx));
        if (rc != 0) return rc;
    }
    var ip = rawIpOpts(d.raw_idx);
    const hdrincl = ip.hdrincl;
    const ov = switch (ip_cmsg_policy.parseSendPing4(control, sendCaps())) {
        .ok => |v| v,
        .err => |e| return e,
    };
    // Linux does not mangle an IP_HDRINCL header, so IP options with it make no sense (raw_sendmsg).
    if (hdrincl and ov.retopts) return -22;
    // IP_HDRINCL: `msg` is the whole datagram, header first (raw_send_hdrinc); otherwise raw_sendmsg reads the ICMP type and code
    // from the user buffer of an ICMP socket (raw_probe_proto_opt), and fewer than 2 bytes is EFAULT.
    const protocol = raw.protocolOf(d.raw_idx);
    const lrc = if (hdrincl) rp.hdrinclErrno(msg) else rp.sendLengthErrno(protocol, msg.len);
    if (lrc != 0) return lrc;
    // IP_PKTINFO's ipi_spec_dst replaces the bound address as the source; the route lookup checks it, then the interface.
    var src = raw.boundAddr(d.raw_idx);
    if (ov.pktinfo) {
        src = ov.spec_dst;
        const src_rc = ip_cmsg_policy.sourceErrno4(src, netif.getOurIp(), nic_mod.isActive());
        if (src_rc != 0) return src_rc;
        const oif_rc = ip_cmsg_policy.oifErrno4(ov.oif, nic_mod.isActive());
        if (oif_rc != 0) return oif_rc;
    }
    const lo_rc = @import("route4_policy.zig").loopbackSourceErrno(src, dst, netif.getOurIp(), @import("arp.zig").loopbackAllowed());
    if (lo_rc != 0) return lo_rc;
    // The destination still comes from the sendto address or the connected peer, not from the caller's header.
    if (hdrincl) {
        const hs = raw.sendHdrincl(src, dst, msg);
        return if (hs < 0) hs else @intCast(msg.len);
    }
    if (ov.ttl) |v| ip.ttl = v;
    if (ov.tos) |v| ip.tos = v;
    const sent = raw.send(src, dst, @truncate(protocol), msg, ip);
    return if (sent < 0) sent else @intCast(msg.len);
}

/// The IP-level options (IP_TTL, IP_TOS, IPV6_UNICAST_HOPS, IPV6_TCLASS) a raw socket's sends carry.
fn rawIpOpts(idx: u32) @import("ip_opt_policy.zig").IpOpts {
    return if (@import("raw_icmp.zig").getOpts(idx)) |o| o.ip else .{};
}

/// recvfrom/recv/read on a raw ICMP socket into the kernel buffer `out`: the next datagram (IP header included; an ICMPv6 message
/// without it), waiting for one unless the descriptor or `flags` ask not to, SHUT_RD ended receiving (0), or SO_RCVTIMEO ran out
/// (EAGAIN). MSG_TRUNC returns the datagram's whole length. The sender's address (IPv4 in the first 4 bytes) goes to `from` when
/// given.
pub fn rawRecvInto(d: *vfs_mod.FileDescriptor, out: []u8, flags: u32, from: ?*[16]u8) i64 {
    return rawRecvIntoMeta(d, out, flags, from, null);
}

/// What a received raw datagram arrived with, for recvmsg's control messages.
const RawMeta = struct { v4: ip_cmsg_policy.RecvInfo = .{}, v6: ip_cmsg_policy.RecvInfo6 = .{} };

/// rawRecvInto that also reports, in `meta`, the interface, destination and IP header values the datagram arrived with.
fn rawRecvIntoMeta(d: *vfs_mod.FileDescriptor, out: []u8, flags: u32, from: ?*[16]u8, meta: ?*RawMeta) i64 {
    const raw = @import("raw_icmp.zig");
    const tsc = @import("../arch/arch.zig").tsc;
    const urp = @import("udp_recv_policy.zig");
    const nonblock = @import("../fs/namespace_policy.zig").nonblockRequested(vfs_mod.statusFlagsOf(d), flags);
    const deadline = urp.deadlineNs(tsc.nanos(), if (raw.getOpts(d.raw_idx)) |o| o.rcv_ms else 0);
    while (true) {
        _ = @import("lo.zig").drain();
        // __skb_try_recv_datagram: a pending ICMP error is reported, once, before any queued datagram.
        const pending = raw.takeError(d.raw_idx, true);
        if (pending != 0) return -@as(i64, pending);
        switch (raw.recv(d.raw_idx, out, (flags & 0x02) != 0)) {
            .ok => |r| {
                if (from) |f| f.* = r.src;
                if (meta) |m| m.* = .{ .v4 = r.meta, .v6 = r.meta6 };
                return @intCast(if ((flags & 0x20) != 0) r.trunc else r.n);
            },
            .eagain => {},
        }
        switch (@import("raw_icmp_policy.zig").emptyRecv(nonblock, raw.shutRd(d.raw_idx))) {
            .eagain => return -11,
            .eof => return 0,
            .wait => {},
        }
        // A blocking receive waits for the next datagram, a signal, or the end of SO_RCVTIMEO (EAGAIN, as raw_recvmsg's
        // skb_recv_datagram). Short sleeps, not one long wait: the loopback device has to be pumped.
        const now = tsc.nanos();
        if (urp.timedOut(deadline, now)) return -11;
        if (comptime @import("builtin").cpu.arch != .x86_64) return -11;
        const se = @import("../arch/x86_64/syscall_entry.zig");
        const slice = now +| 5 * 1_000_000;
        const rc = se.sleepUntil(if (deadline) |dl| @min(slice, dl) else slice, 0);
        if (rc < 0) return rc;
    }
}

/// bind on an IPv6 raw socket (rawv6_bind): 24 bytes of AF_INET6 (EINVAL otherwise), no v4-mapped address (EADDRNOTAVAIL), a
/// link-scoped one with its interface, and an address of this host.
fn rawBind6(d: *vfs_mod.FileDescriptor, addr_ptr: u64, addr_len: u32) i64 {
    if (addr_len < 24) return -22;
    const parsed = switch (readInet6(addr_ptr, addr_len)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    if (parsed.family != 10) return -22;
    if (@import("raw_icmp_policy.zig").isMapped6(parsed.addr)) return -99;
    const scope_rc = bind_addr_policy.inet6ScopeErrno(parsed.addr, parsed.scope, nic_mod.isActive());
    if (scope_rc != 0) return scope_rc;
    if (bindAddrNotAvail6(parsed.addr)) return bind_addr_policy.EADDRNOTAVAIL;
    _ = @import("raw_icmp.zig").bind6(d.raw_idx, parsed.addr);
    return 0;
}

/// connect on an IPv6 raw socket (ip6_datagram_connect): AF_UNSPEC dissolves the association; otherwise a 24-byte AF_INET6 address
/// (:: included) filters what is received and is where send and write go.
fn rawConnect6(d: *vfs_mod.FileDescriptor, addr_ptr: u64, addr_len: u32) i64 {
    var fam: [2]u8 = @splat(0);
    if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000) return -14;
    if (addr_len >= 2 and copy.copyFromUser(&fam, @ptrFromInt(addr_ptr), 2) != 2) return -14;
    switch (@import("socket_address_policy.zig").dgramConnectAction6(addr_len, bo.readU16Le(&fam))) {
        .einval => return -22,
        .eafnosupport => return -97,
        .disconnect => {
            _ = @import("raw_icmp.zig").connect6(d.raw_idx, null);
            return 0;
        },
        .address => {},
    }
    if (bo.readU16Le(&fam) != 10) return -97;
    if (addr_len < 24) return -22;
    const parsed = switch (readInet6(addr_ptr, addr_len)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    _ = @import("raw_icmp.zig").connect6(d.raw_idx, parsed.addr);
    return 0;
}

/// bind on a raw ICMP socket: a whole sockaddr_in naming this host (or the wildcard); the protocol stays the port.
fn rawBind(d: *vfs_mod.FileDescriptor, addr_ptr: u64, addr_len: u32) i64 {
    if (@import("raw_icmp.zig").isV6(d.raw_idx)) return rawBind6(d, addr_ptr, addr_len);
    const rp = @import("raw_icmp_policy.zig");
    const lrc = rp.addrLenErrno(addr_len);
    if (lrc != 0) return lrc;
    const parsed = switch (readInet4(addr_ptr, addr_len)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    // raw_bind checks the address type only (inet_addr_type_table): a group or a broadcast address is EADDRNOTAVAIL.
    const a = parsed.addr;
    if ((a[0] >= 224 and a[0] <= 239) or (a[0] == 255 and a[1] == 255 and a[2] == 255 and a[3] == 255) or bindAddrNotAvail4(a)) return -99;
    _ = @import("raw_icmp.zig").bind(d.raw_idx, a);
    return 0;
}

/// connect on a raw ICMP socket (ip4_datagram_connect): AF_UNSPEC drops the peer; otherwise the peer filters what is received and is
/// where send and write go.
fn rawConnect(d: *vfs_mod.FileDescriptor, addr_ptr: u64, addr_len: u32) i64 {
    if (@import("raw_icmp.zig").isV6(d.raw_idx)) return rawConnect6(d, addr_ptr, addr_len);
    var fam: [2]u8 = @splat(0);
    if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000) return -14;
    if (addr_len >= 2 and copy.copyFromUser(&fam, @ptrFromInt(addr_ptr), 2) != 2) return -14;
    switch (@import("socket_address_policy.zig").dgramConnectAction(addr_len, bo.readU16Le(&fam))) {
        .einval => return -22,
        .eafnosupport => return -97,
        .disconnect => {
            _ = @import("raw_icmp.zig").connect(d.raw_idx, .{ 0, 0, 0, 0 });
            return 0;
        },
        .address => {},
    }
    if (addr_len < 16) return -22;
    const parsed = switch (readInet4(addr_ptr, addr_len)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    if (parsed.family != 2) return -97;
    _ = @import("raw_icmp.zig").connect(d.raw_idx, parsed.addr);
    return 0;
}

// ── Syscall implementations ────────────────────────────────────────

/// socket(domain, type, protocol) → fd or -errno
pub fn socket(domain: u32, type_and_flags: u32, protocol: u32) i64 {
    const np = @import("../fs/namespace_policy.zig");
    const parsed = switch (np.socketArgs(domain, type_and_flags, protocol)) {
        .ok => |a| a,
        .err => |e| return e,
    };
    const is_ping = parsed.sock_type == 2 and ((domain == 2 and protocol == 1) or (domain == 10 and protocol == 58));
    const fd = if (is_ping) pingCreate(domain == 10) else if ((domain == 2 or domain == 10) and parsed.sock_type == 3) rawCreate(protocol, domain == 10) else socketCreate(domain, parsed.sock_type);
    if (fd < 0) return fd;
    // SOCK_CLOEXEC / SOCK_NONBLOCK belong to the new descriptor, not to the socket type.
    const cur_idx = sched_mod.currentTaskIndex() orelse return fd;
    const t = task_mod.getTask(cur_idx) orelse return fd;
    if (fd < vfs_mod.MAX_FDS) {
        if (parsed.cloexec) t.fd_table.fds[@intCast(fd)].fd_flags = 1;
        if (parsed.nonblock) vfs_mod.setStatusFlags(&t.fd_table.fds[@intCast(fd)], t.fd_table.fds[@intCast(fd)].status_flags | 0x800);
    }
    return fd;
}

/// bind() of a UDP socket to `new_port`: the registration moves with its options, joining a port other sockets hold only when
/// udp_port_policy allows it (both SO_REUSEADDR, or both SO_REUSEPORT with the same owner, the fsuid recorded when socket() created it).
/// Sockets bound to different addresses on one port (IPv4 `addr`, or IPv6 `addr6` between two IPv6 sockets) do not conflict. The ephemeral port from socket() is dropped.
fn udpRebind(t: *task_mod.Task, fd: u32, new_port: u16, addr: [4]u8, addr6: [16]u8, dev6: u8) i64 {
    const d = &t.fd_table.fds[fd];
    var disc: u16 = 0;
    const old_key = d.udpKey();
    // bind with port 0 names the socket on an ephemeral port (udp_lib_get_port(sk, 0)), keeping the one socket() reserved when it is
    // still free; the address is recorded the same way.
    const target = if (new_port == 0) blk: {
        const ab = udpAutobind(d);
        if (ab != 0) return ab;
        break :blk d.udp_port;
    } else new_port;
    const rc = udp.rebind(d.udpKey(), target, addr, addr6, dev6, &disc);
    if (rc != 0) return rc;
    d.udp_local_ip = addr;
    d.udp_local_ip6 = addr6;
    d.udp_port = target;
    d.udp_disc = disc;
    // A port the user named survives connect(AF_UNSPEC) (SOCK_BINDPORT_LOCK); one bind picked is given up like an autobound one.
    if (new_port != 0) {
        _ = udp.markUserPort(d.udpKey());
    } else _ = udp.autobindDone(d.udpKey());
    if (d.udpKey() != old_key) vfs_mod.udpFasyncRekey(old_key, d.udpKey());
    return 0;
}

/// Name an unnamed UDP socket before it is used (inet_send_prepare, ip4_datagram_connect -> inet_autobind): it keeps the port
/// socket() reserved unless someone bound that number meanwhile. The descriptor is rekeyed when the port moves. 0, or -EAGAIN.
fn udpAutobind(d: *vfs_mod.FileDescriptor) i64 {
    if (d.udp_ping) return 0;
    const old_key = d.udpKey();
    var port: u16 = 0;
    var disc: u16 = 0;
    const rc = udp.autobind(old_key, &port, &disc);
    if (rc != 0) return rc;
    d.udp_port = port;
    d.udp_disc = disc;
    if (d.udpKey() != old_key) vfs_mod.udpFasyncRekey(old_key, d.udpKey());
    return 0;
}

/// socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP), or socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6) when `is_v6`: a ping socket on the
/// first free ident, for a task whose egid or a supplementary group lies in net.ipv4.ping_group_range (empty by default; root sets
/// it through /proc/sys/net/ipv4/ping_group_range; the IPv6 socket is gated by the same range, as in Linux ping_init_sock).
fn pingCreate(is_v6: bool) i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;
    // ping_init_sock: the egid or a supplementary group must lie in net.ipv4.ping_group_range.
    if (!udp.pingGroupAllowed(t.egid, t.groups[0..t.ngroups])) return -13; // EACCES
    const key = udp.pingOpen(t.fsuid, is_v6) orelse return -105; // ENOBUFS
    const fd_slot = t.fd_table.allocFd() orelse {
        udp.releasePort(key);
        return -24; // EMFILE
    };
    t.fd_table.fds[fd_slot] = .{
        .fd_type = .udp_socket,
        .udp_port = @truncate(key),
        .udp_ping = true,
        .udp_is_v6 = is_v6,
        .writable = true,
    };
    t.fd_table.publishFd(fd_slot);
    return @intCast(fd_slot);
}

/// sendto/sendmsg on a ping socket: `payload` is an ICMP echo request; the ident and the checksum are filled in
/// (ping_v4_sendmsg). The destination is `addr_ptr` (a sockaddr_in of at least 16 bytes) or the connected peer. `control` is
/// sendmsg's msg_control (empty for sendto): once the destination is known, ip_cmsg_send's IP_TTL / IP_TOS replace the socket's
/// values for this request and IP_PKTINFO names its source. An IPv6 ping socket reads it in pingSend6.
fn pingSend(d: *vfs_mod.FileDescriptor, payload: []const u8, addr_ptr: u64, addr_len: u32, control: []const u8) i64 {
    const pp = @import("ping_policy.zig");
    if (d.udp_is_v6) return pingSend6(d, payload, addr_ptr, addr_len, control);
    const rc = pp.sendErrno(payload.len, if (payload.len > 0) payload[0] else 0, if (payload.len > 1) payload[1] else 0);
    if (rc != 0) return rc;
    var dst: [4]u8 = .{ 0, 0, 0, 0 };
    if (addr_ptr != 0) {
        if (addr_len < SOCKADDR_IN_MIN_LEN + 8) return -22;
        var sa_buf: [16]u8 = undefined;
        if (copy.copyFromUser(&sa_buf, @ptrFromInt(addr_ptr), 16) != 16) return -14;
        if (!@import("socket_address_policy.zig").inet4FamilyValid(bo.readU16Le(sa_buf[0..2]))) return -97;
        dst = .{ sa_buf[4], sa_buf[5], sa_buf[6], sa_buf[7] };
    } else if (d.udp_connected) {
        dst = d.udp_dst_ip;
    } else return -89; // EDESTADDRREQ
    const ov = switch (ip_cmsg_policy.parseSendPing4(control, sendCaps())) {
        .ok => |v| v,
        .err => |e| return e,
    };
    var src = d.udp_local_ip;
    if (ov.pktinfo) {
        src = ov.spec_dst;
        const src_rc = ip_cmsg_policy.sourceErrno4(src, netif.getOurIp(), nic_mod.isActive());
        if (src_rc != 0) return src_rc;
        const oif_rc = ip_cmsg_policy.oifErrno4(ov.oif, nic_mod.isActive());
        if (oif_rc != 0) return oif_rc;
    }
    // A socket bound to 127/8 reaches only what lo carries (__mkroute_output).
    const lo_rc = @import("route4_policy.zig").loopbackSourceErrno(src, dst, netif.getOurIp(), @import("arp.zig").loopbackAllowed());
    if (lo_rc != 0) return lo_rc;
    var msg: [pp.MAX_MESSAGE]u8 = undefined;
    @memcpy(msg[0..payload.len], payload);
    pp.finishRequest(msg[0..payload.len], d.udp_port);
    // The first send gives the socket its ident for good (ping_v4_sendmsg autobinds through inet_autobind) and hashes it.
    if (!d.udp_ping_bound) udp.pingRehash(d.udpKey());
    d.udp_ping_bound = true;
    // An ICMP error a connected socket took fails this send, once (sock_alloc_send_skb → sock_error).
    const pending = udp.takePendingError(d.udpKey());
    if (pending != 0) return -@as(i64, pending);
    const ipo = @import("ip_opt_policy.zig");
    const ping_ip: ipo.IpOpts = if (udp.getPortOpts(d.udpKey())) |po| po.ip else .{};
    const sock_ttl: u8 = if (dst[0] >= 224 and dst[0] <= 239) ping_ip.mc4_ttl else ipo.effectiveTtl(ping_ip);
    const ttl: u8 = ov.ttl orelse sock_ttl;
    const tos: u8 = ov.tos orelse ping_ip.tos;
    const sent = @import("icmp.zig").sendFromOv(src, dst, msg[0..payload.len], ping_ip.pmtudisc, ttl, tos);
    return if (sent < 0) sent else @intCast(payload.len);
}

/// sendto/sendmsg on an IPv6 ping socket: `payload` is an ICMPv6 echo request; the ident and the checksum (over the IPv6
/// pseudo-header) are filled in (ping_v6_sendmsg). The destination is `addr_ptr` (a sockaddr_in6 of at least 28 bytes) or the
/// connected peer; a link-scoped one needs an interface (sin6_scope_id or the socket's own). `control` is sendmsg's msg_control
/// (empty for sendto), read once the destination is routed (ip6_datagram_send_ctl): IPV6_HOPLIMIT / IPV6_TCLASS replace the
/// socket's IPV6_UNICAST_HOPS / IPV6_TCLASS for this request; an IPV6_PKTINFO source is checked, not used (fl6.saddr = np->saddr).
fn pingSend6(d: *vfs_mod.FileDescriptor, payload: []const u8, addr_ptr: u64, addr_len: u32, control: []const u8) i64 {
    const pp = @import("ping_policy.zig");
    const rc = pp.sendErrno6(payload.len, if (payload.len > 0) payload[0] else 0, if (payload.len > 1) payload[1] else 0);
    if (rc != 0) return rc;
    var dst: [16]u8 = @splat(0);
    var scope: u32 = 0;
    if (addr_ptr != 0) {
        if (addr_len < sa.SOCKADDR_IN6_LEN) return -22;
        var sa6: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
        if (copy.copyFromUser(&sa6, @ptrFromInt(addr_ptr), sa.SOCKADDR_IN6_LEN) != sa.SOCKADDR_IN6_LEN) return -14;
        const fam_rc = pp.family6Errno(bo.readU16Le(sa6[0..2]));
        if (fam_rc != 0) return fam_rc;
        const parsed = sa.parseInet6(&sa6) orelse return -97;
        dst = parsed.addr;
        scope = parsed.scope_id;
    } else if (d.udp_connected) {
        dst = d.udp_dst_ip6;
    } else return -89; // EDESTADDRREQ
    const oif = udp.sendOif6(d.udpKey(), dst, scope);
    const dest_rc = pp.destErrno6(dst, bind_addr_policy.needsScope6(dst), oif);
    if (dest_rc != 0) return dest_rc;
    const unreach = bind_addr_policy.routeErrno6(dst, oif);
    if (unreach != 0) return unreach;
    const ctx6: ip_cmsg_policy.Ctx6 = .{ .pre_oif = oif, .nic_active = nic_mod.isActive(), .isOwnNic = isOwnNicAddr6 };
    const ov6 = switch (ip_cmsg_policy.parseSendPing6(control, sendCaps(), ctx6)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    var msg: [pp.MAX_MESSAGE]u8 = undefined;
    @memcpy(msg[0..payload.len], payload);
    pp.setIdent(msg[0..payload.len], d.udp_port);
    if (!d.udp_ping_bound) udp.pingRehash(d.udpKey());
    d.udp_ping_bound = true;
    // An ICMPv6 error a connected socket took fails this send, once (sock_alloc_send_skb → sock_error).
    const pending = udp.takePendingError(d.udpKey());
    if (pending != 0) return -@as(i64, pending);
    const ping_ip6: @import("ip_opt_policy.zig").IpOpts = if (udp.getPortOpts(d.udpKey())) |po| po.ip else .{};
    const sent = @import("icmpv6.zig").sendProto6Ov(d.udp_local_ip6, dst, 58, 2, msg[0..payload.len], ping_ip6, ov6.hops, ov6.tclass);
    return if (sent < 0) sent else @intCast(payload.len);
}

fn socketCreate(domain: u32, sock_type: u32) i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;

    if (domain == 1) {
        // AF_UNIX
        const sock_idx = net_mod.unix_socket.unixSocket(sock_type);
        if (sock_idx < 0) return @as(i64, sock_idx);
        net_mod.unix_socket.unixSetCred(@intCast(sock_idx), .{ .pid = @intCast(if (t.is_thread and t.parent_tid != 0) t.parent_tid else t.tid), .uid = t.euid, .gid = t.egid });
        const fd = allocUnixFd(t.fd_table, @intCast(sock_idx));
        if (fd < 0) {
            net_mod.unix_socket.unixClose(@intCast(sock_idx));
            return fd;
        }
        return @as(i64, fd);
    }

    // AF_INET + UDP
    if (domain == 2 and sock_type == 2) {
        var port: u16 = 49152;
        while (port < 65535) : (port += 1) {
            // ensurePortExclusive: an already-registered port (0xFFFE) must be
            // skipped — plain ensurePort would hand the new socket the EXISTING
            // slot, sharing the first socket's receive queue and refcount.
            const idx = udp.ensurePortExclusive(port, false, t.fsuid);
            switch (udp_util.scanAction(idx)) {
                .skip_in_use => continue,
                .abort_full => return -105, // ENOBUFS
                .use => {
                    // v53.49: Use allocFd() O(1) bitmap instead of duplicated linear scan
                    const fd_slot = t.fd_table.allocFd() orelse {
                        udp.releasePort(port); // roll back the port registration
                        return -24; // EMFILE
                    };
                    t.fd_table.fds[fd_slot] = .{
                        .fd_type = .udp_socket,
                        .udp_port = port,
                        .writable = true,
                    };
                    t.fd_table.publishFd(fd_slot);
                    return @intCast(fd_slot);
                },
            }
        }
        return -1;
    }

    // AF_INET6 — UDP uses the IPv6 stack (SK-70/71); TCP marks TCB is_v6 (SK-75).
    if (domain == 10) {
        if (sock_type == 1) {
            // SOCK_STREAM → IPv6 TCP socket (TX SYN-ACK still SK-76)
            const tcb_idx6 = net_mod.tcp.tcpSocket(cur_idx);
            if (tcb_idx6 < 0) return -1;
            if (net_mod.tcp.tcpSetIpv6(@intCast(tcb_idx6)) < 0) {
                _ = net_mod.tcp.tcpClose(@intCast(tcb_idx6));
                return -1;
            }
            const fd6 = allocTcpFd(t.fd_table, @intCast(tcb_idx6));
            if (fd6 < 0) {
                _ = net_mod.tcp.tcpClose(@intCast(tcb_idx6));
                return fd6;
            }
            return fd6;
        }
        if (sock_type == 2) {
            // SOCK_DGRAM → IPv6 UDP socket
            var port6: u16 = 49152;
            while (port6 < 65535) : (port6 += 1) {
                // Same exclusivity rule as the IPv4 scan above.
                const idx6 = udp.ensurePortExclusive(port6, true, t.fsuid);
                switch (udp_util.scanAction(idx6)) {
                    .skip_in_use => continue,
                    .abort_full => return -105, // ENOBUFS
                    .use => {
                        const fd_slot6 = t.fd_table.allocFd() orelse {
                            udp.releasePort(port6); // roll back the port registration
                            return -24; // EMFILE
                        };
                        t.fd_table.fds[fd_slot6] = .{
                            .fd_type = .udp_socket,
                            .udp_port = port6,
                            .udp_is_v6 = true,
                            .writable = true,
                        };
                        t.fd_table.publishFd(fd_slot6);
                        return @intCast(fd_slot6);
                    },
                }
            }
            return -1;
        }
        return -38; // ENOSYS for unsupported AF_INET6 socket types
    }

    if (domain != 2 or sock_type != 1) {
        return -38; // ENOSYS
    }

    // AF_INET + TCP
    const tcb_idx = net_mod.tcp.tcpSocket(cur_idx);
    if (tcb_idx < 0) return -1;
    const fd = allocTcpFd(t.fd_table, @intCast(tcb_idx));
    if (fd < 0) {
        _ = net_mod.tcp.tcpClose(@intCast(tcb_idx));
        return fd;
    }
    return fd;
}

fn bindAddrNotAvail4(addr: [4]u8) bool {
    var nic: bind_addr_policy.Nic = .{ .active = nic_mod.isActive() };
    if (nic.active) {
        nic.ip = netif.getOurIp();
        nic.netmask = netif.getNetmask();
    }
    return !bind_addr_policy.inet4Bindable(addr, nic);
}

fn bindAddrNotAvail6(addr: [16]u8) bool {
    var nic: bind_addr_policy.Nic = .{ .active = nic_mod.isActive() };
    if (nic.active) {
        nic.ip = netif.getOurIp();
        nic.netmask = netif.getNetmask();
        nic.link_local6 = ndp.generateLinkLocal(netif.getMac());
    }
    return !bind_addr_policy.inet6Bindable(addr, nic, ndp.hasLocalAddress(addr));
}

/// bind(fd, addr_ptr, addr_len) → 0 or -errno
pub fn bind(fd: u32, addr_ptr: u64, addr_len: u32) i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS) return -9; // EBADF
    if (t.fd_table.fds[fd].fd_type == .none) return -9;

    if (t.fd_table.fds[fd].fd_type == .raw_socket) return rawBind(&t.fd_table.fds[fd], addr_ptr, addr_len);

    // AF_UNIX bind
    if (t.fd_table.fds[fd].fd_type == .unix_socket) {
        const unix_idx = t.fd_table.fds[fd].unix_sock_idx;
        if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000) return -14;
        // An address that is only the family asks for an automatically chosen abstract name.
        if (addr_len == SOCKADDR_UN_PATH_OFFSET) {
            var fam: [2]u8 = undefined;
            if (copy.copyFromUser(&fam, @ptrFromInt(addr_ptr), 2) != 2) return -14;
            if (bo.readU16Le(&fam) != 1) return -97; // EAFNOSUPPORT
            return @as(i64, net_mod.unix_socket.unixAutobind(unix_idx));
        }
        if (!@import("socket_address_policy.zig").unixLengthValid(addr_len, SOCKADDR_UN_PATH_OFFSET)) return -22;
        var sock_addr_buf: [110]u8 = undefined;
        const to_copy = @min(@as(usize, addr_len), sock_addr_buf.len);
        const copied = copy.copyFromUser(sock_addr_buf[0..to_copy], @ptrFromInt(addr_ptr), to_copy);
        if (copied <= SOCKADDR_UN_PATH_OFFSET) return -22; // EINVAL
        const path_len = @import("socket_address_policy.zig").unixNameLen(sock_addr_buf[2..copied]);
        const result = net_mod.unix_socket.unixBind(unix_idx, @ptrCast(sock_addr_buf[2 .. 2 + path_len].ptr), path_len);
        return @as(i64, result);
    }

    // Ping socket bind: the port is the ICMP ident (ping_bind → ping_get_port).
    if (t.fd_table.fds[fd].fd_type == .udp_socket and t.fd_table.fds[fd].udp_ping and t.fd_table.fds[fd].udp_is_v6) {
        if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000) return -14;
        if (addr_len < sa.SOCKADDR_IN6_LEN) return -22;
        var pa6: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
        if (copy.copyFromUser(&pa6, @ptrFromInt(addr_ptr), sa.SOCKADDR_IN6_LEN) != sa.SOCKADDR_IN6_LEN) return -14;
        const pp6 = @import("ping_policy.zig");
        const fam_rc = pp6.family6Errno(bo.readU16Le(pa6[0..2]));
        if (fam_rc != 0) return fam_rc;
        const parsed = sa.parseInet6(&pa6) orelse return -97;
        const dev_ok = parsed.scope_id == bind_addr_policy.LO_IFINDEX or (nic_mod.isActive() and parsed.scope_id == bind_addr_policy.NIC_IFINDEX);
        const addr_rc = pp6.bindAddrErrno6(parsed.addr, bind_addr_policy.needsScope6(parsed.addr), parsed.scope_id, dev_ok, !bindAddrNotAvail6(parsed.addr));
        if (addr_rc != 0) return addr_rc;
        const d6 = &t.fd_table.fds[fd];
        const bind_rc6 = pp6.bindErrno(d6.udp_ping_bound);
        if (bind_rc6 != 0) return bind_rc6;
        const old_key6 = d6.udpKey();
        const nk6 = udp.pingBind(old_key6, parsed.port, .{ 0, 0, 0, 0 }, parsed.addr);
        if (nk6 < 0) return nk6;
        const key6: u32 = @intCast(nk6);
        d6.udp_port = @truncate(key6);
        d6.udp_disc = @truncate((key6 >> 16) & 0x7fff);
        d6.udp_local_ip6 = parsed.addr;
        d6.udp_ping_bound = true;
        if (d6.udpKey() != old_key6) vfs_mod.udpFasyncRekey(old_key6, d6.udpKey());
        return 0;
    }
    if (t.fd_table.fds[fd].fd_type == .udp_socket and t.fd_table.fds[fd].udp_ping) {
        if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000) return -14;
        if (addr_len < SOCKADDR_IN_MIN_LEN + 8) return -22;
        var pa: [16]u8 = undefined;
        if (copy.copyFromUser(&pa, @ptrFromInt(addr_ptr), 16) != 16) return -14;
        if (!@import("socket_address_policy.zig").inet4FamilyValid(bo.readU16Le(pa[0..2]))) return -97;
        const addr4 = [4]u8{ pa[4], pa[5], pa[6], pa[7] };
        const pp = @import("ping_policy.zig");
        if (!pp.bindAddrAllowed(addr4, !bindAddrNotAvail4(addr4))) return bind_addr_policy.EADDRNOTAVAIL;
        const d = &t.fd_table.fds[fd];
        const bind_rc = pp.bindErrno(d.udp_ping_bound);
        if (bind_rc != 0) return bind_rc;
        const old_key = d.udpKey();
        const nk = udp.pingBind(old_key, bo.readU16BeAt(&pa, 2), addr4, @splat(0));
        if (nk < 0) return nk;
        const key: u32 = @intCast(nk);
        d.udp_port = @truncate(key);
        d.udp_disc = @truncate((key >> 16) & 0x7fff);
        d.udp_local_ip = addr4;
        d.udp_ping_bound = true;
        if (d.udpKey() != old_key) vfs_mod.udpFasyncRekey(old_key, d.udpKey());
        return 0;
    }

    // UDP bind
    if (t.fd_table.fds[fd].fd_type == .udp_socket) {
        if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000) return -1;
        const is_v6 = t.fd_table.fds[fd].udp_is_v6;
        if (is_v6) {
            if (addr_len < sa.SOCKADDR_IN6_LEN) return -22;
            var sa6: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
            const n = copy.copyFromUser(&sa6, @ptrFromInt(addr_ptr), sa.SOCKADDR_IN6_LEN);
            if (n < sa.SOCKADDR_IN6_LEN) return -22; // EINVAL
            const parsed = sa.parseInet6(&sa6) orelse return -97; // EAFNOSUPPORT
            const scope_rc = bind_addr_policy.inet6ScopeErrno(parsed.addr, parsed.scope_id, nic_mod.isActive());
            if (scope_rc != 0) return scope_rc;
            if (bindAddrNotAvail6(parsed.addr)) return bind_addr_policy.EADDRNOTAVAIL;
            if (net_mod.tcp_port_policy.bindNeedsPrivilege(parsed.port) and !cap_mod.hasSysCap(cur_idx, "cap_net_bind")) return net_mod.tcp_port_policy.BIND_EACCES;
            return udpRebind(t, fd, parsed.port, .{ 0, 0, 0, 0 }, parsed.addr, bind_addr_policy.boundDev6(parsed.addr, parsed.scope_id));
        }
        if (addr_len < SOCKADDR_IN_MIN_LEN) return -22;
        var sock_addr: [sa.SOCKADDR_IN_LEN]u8 = undefined;
        const n4 = copy.copyFromUser(&sock_addr, @ptrFromInt(addr_ptr), SOCKADDR_IN_MIN_LEN);
        if (n4 < SOCKADDR_IN_MIN_LEN) return -22;
        // Accept legacy callers that only filled port+addr; family may be unset.
        const new_port = bo.readU16BeAt(&sock_addr, 2);
        if (bindAddrNotAvail4(.{ sock_addr[4], sock_addr[5], sock_addr[6], sock_addr[7] })) return bind_addr_policy.EADDRNOTAVAIL;
        if (net_mod.tcp_port_policy.bindNeedsPrivilege(new_port) and !cap_mod.hasSysCap(cur_idx, "cap_net_bind")) return net_mod.tcp_port_policy.BIND_EACCES;
        return udpRebind(t, fd, new_port, .{ sock_addr[4], sock_addr[5], sock_addr[6], sock_addr[7] }, @splat(0), 0);
    }

    if (t.fd_table.fds[fd].fd_type != .tcp_socket) return -88; // ENOTSOCK
    const tcb_idx = t.fd_table.fds[fd].tcb_idx;

    if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000) return -14;
    const info = net_mod.tcp.tcpGetAddrInfo(tcb_idx) orelse return -1;
    if (info.is_v6) {
        if (!@import("socket_address_policy.zig").inetLengthValid(addr_len, true)) return -22;
        if (addr_len < sa.SOCKADDR_IN6_LEN) return -22;
        var sa6: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
        if (copy.copyFromUser(&sa6, @ptrFromInt(addr_ptr), sa.SOCKADDR_IN6_LEN) < sa.SOCKADDR_IN6_LEN)
            return -22;
        const parsed = sa.parseInet6(&sa6) orelse return -97; // EAFNOSUPPORT
        const stream_rc = bind_addr_policy.streamBindErrno6(parsed.addr);
        if (stream_rc != 0) return stream_rc;
        const scope_rc = bind_addr_policy.inet6ScopeErrno(parsed.addr, parsed.scope_id, nic_mod.isActive());
        if (scope_rc != 0) return scope_rc;
        if (bindAddrNotAvail6(parsed.addr)) return bind_addr_policy.EADDRNOTAVAIL;
        if (net_mod.tcp_port_policy.bindNeedsPrivilege(parsed.port) and !cap_mod.hasSysCap(cur_idx, "cap_net_bind")) return net_mod.tcp_port_policy.BIND_EACCES;
        return net_mod.tcp.tcpBindAddr46(tcb_idx, parsed.port, net_mod.tcp_port_policy.WILDCARD4, parsed.addr, bind_addr_policy.boundDev6(parsed.addr, parsed.scope_id));
    }
    if (addr_len < SOCKADDR_IN_MIN_LEN) return -22;
    if (!@import("socket_address_policy.zig").inetLengthValid(addr_len, false)) return -22;
    var sock_addr: [8]u8 = undefined;
    if (copy.copyFromUser(&sock_addr, @ptrFromInt(addr_ptr), SOCKADDR_IN_MIN_LEN) != SOCKADDR_IN_MIN_LEN) return -14;
    if (!@import("socket_address_policy.zig").inet4FamilyValid(bo.readU16Le(sock_addr[0..2]))) return -97; // EAFNOSUPPORT
    const port = bo.readU16BeAt(&sock_addr, 2);
    if (bindAddrNotAvail4(.{ sock_addr[4], sock_addr[5], sock_addr[6], sock_addr[7] })) return bind_addr_policy.EADDRNOTAVAIL;
    if (net_mod.tcp_port_policy.bindNeedsPrivilege(port) and !cap_mod.hasSysCap(cur_idx, "cap_net_bind")) return net_mod.tcp_port_policy.BIND_EACCES;
    return net_mod.tcp.tcpBindAddr(tcb_idx, port, .{ sock_addr[4], sock_addr[5], sock_addr[6], sock_addr[7] });
}

/// listen(fd, backlog) → 0 or -errno
pub fn listen(fd: u32, backlog: u32) i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS or t.fd_table.fds[fd].fd_type == .none) return -9; // EBADF

    if (t.fd_table.fds[fd].fd_type == .raw_socket) return -95; // EOPNOTSUPP (raw_listen/raw_accept stay NULL in Linux)

    if (t.fd_table.fds[fd].fd_type == .unix_socket) {
        const unix_idx = t.fd_table.fds[fd].unix_sock_idx;
        const result = net_mod.unix_socket.unixListen(unix_idx, backlog);
        return @as(i64, result);
    }

    if (t.fd_table.fds[fd].fd_type != .tcp_socket) return -88;
    const tcb_idx = t.fd_table.fds[fd].tcb_idx;
    const result = net_mod.tcp.tcpListen(tcb_idx, backlog);
    return result;
}

/// accept(fd, addr_ptr, addr_len_ptr) → new fd or -errno
pub fn accept(fd: u32, addr_ptr: u64, addr_len_ptr: u64) i64 {
    if ((addr_ptr == 0) != (addr_len_ptr == 0)) return -14;
    if (addr_ptr != 0 and
        (!copy.validateUserRange(addr_ptr, 0) or
            !copy.validateUserBuffer(addr_len_ptr, 4) or
            !copy.validateUserBufferWritable(addr_len_ptr, 4))) return -14;

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS) return -9;
    if (t.fd_table.fds[fd].fd_type == .none) return -9;

    if (t.fd_table.fds[fd].fd_type == .raw_socket) return -95; // EOPNOTSUPP

    // AF_UNIX accept
    if (t.fd_table.fds[fd].fd_type == .unix_socket) {
        const unix_idx = t.fd_table.fds[fd].unix_sock_idx;
        const new_sock_idx = net_mod.unix_socket.unixAcceptBlocking(unix_idx, @import("../fs/namespace_policy.zig").nonblockRequested(vfs_mod.statusFlagsOf(&t.fd_table.fds[fd]), 0));
        if (new_sock_idx < 0) return @as(i64, new_sock_idx);
        net_mod.unix_socket.unixSetCred(@intCast(new_sock_idx), .{ .pid = @intCast(if (t.is_thread and t.parent_tid != 0) t.parent_tid else t.tid), .uid = t.euid, .gid = t.egid });
        const new_fd = allocUnixFd(t.fd_table, @intCast(new_sock_idx));
        if (new_fd < 0) {
            net_mod.unix_socket.unixClose(@intCast(new_sock_idx));
            return new_fd;
        }
        return @as(i64, @as(i64, new_fd));
    }

    if (t.fd_table.fds[fd].fd_type != .tcp_socket) return -88;
    const listen_tcb_idx = t.fd_table.fds[fd].tcb_idx;
    const new_tcb_idx = net_mod.tcp.tcpAccept(listen_tcb_idx, cur_idx);
    // Negative only on error/empty backlog (-11 EAGAIN); TCB index 0 is valid.
    if (new_tcb_idx < 0) return new_tcb_idx;
    const new_fd = allocTcpFd(t.fd_table, @intCast(new_tcb_idx));
    if (new_fd < 0) {
        _ = net_mod.tcp.tcpClose(@intCast(new_tcb_idx));
        return new_fd;
    }
    // SK-78: optionally fill peer sockaddr (IPv4 or IPv6).
    if (addr_ptr != 0 or addr_len_ptr != 0) {
        if (net_mod.tcp.tcpGetAddrInfo(@intCast(new_tcb_idx))) |ainfo| {
            var sa_buf: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
            const alen = sa.encodeInetName(ainfo.is_v6, ainfo.remote_port, ainfo.remote_ip, ainfo.remote_ip6, &sa_buf);
            // Copy-out failure must not leak the accepted fd/TCB.
            if (alen != 0 and copySockaddrToUser(addr_ptr, addr_len_ptr, sa_buf[0..alen], alen) != 0) {
                _ = t.fd_table.close(@intCast(new_fd));
                return -14; // EFAULT
            }
        }
    }
    return new_fd;
}

/// accept4(fd, addr, addrlen, flags) → new fd or -errno
pub fn accept4(fd: u32, addr_ptr: u64, addr_len_ptr: u64, flags: u32) i64 {
    const policy_result = accept4_policy.validate(flags);
    if (policy_result != 0) return policy_result;
    const result = accept(fd, addr_ptr, addr_len_ptr);
    if (result >= 0 and flags != 0) {
        const cur_idx = sched_mod.currentTaskIndex() orelse return result;
        const cur = task_mod.getTask(cur_idx) orelse return result;
        const newfd: u32 = @intCast(result);
        if (newfd < vfs_mod.MAX_FDS) {
            if ((flags & 0x80000) != 0) { // O_CLOEXEC
                cur.fd_table.fds[newfd].fd_flags = 1;
            }
            if ((flags & 0x800) != 0) { // O_NONBLOCK
                cur.fd_table.fds[newfd].status_flags |= 0x800;
            }
        }
    }
    return result;
}

/// Read a sockaddr_un destination into `out` (family at 0..2, path from 2); returns the path
/// length (to the first NUL). Errors are negative errnos.
const UnixDest = union(enum) { ok: usize, err: i64 };

fn unixDestPath(addr_ptr: u64, addr_len: u32, out: *[110]u8) UnixDest {
    const ap = @import("socket_address_policy.zig");
    if (addr_ptr >= 0x0000_8000_0000_0000) return .{ .err = -14 };
    if (!ap.unixLengthValid(addr_len, SOCKADDR_UN_PATH_OFFSET)) return .{ .err = -22 };
    const to_copy = @min(@as(usize, addr_len), out.len);
    const copied = copy.copyFromUser(out[0..to_copy], @ptrFromInt(addr_ptr), to_copy);
    if (copied != to_copy) return .{ .err = -14 };
    if (bo.readU16Le(out[0..2]) != 1) return .{ .err = -97 }; // EAFNOSUPPORT (AF_UNIX, little endian)
    const n = ap.unixNameLen(out[2..copied]);
    if (n == 0) return .{ .err = -22 };
    return .{ .ok = n };
}

/// sendto(fd, buf, len, flags, addr_ptr, addr_len) → bytes sent or -errno
pub fn sendto(fd: u32, buf: u64, len: u32, flags: u32, addr_ptr: u64, addr_len: u32) i64 {
    if (!@import("socket_address_policy.zig").optionalUserAddressValid(addr_ptr, 0x0000_8000_0000_0000)) return -14;
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS) return -9; // EBADF

    // UDP, ping and raw sockets have no urgent data (udp_sendmsg / raw_sendmsg: EOPNOTSUPP).
    if (flags & urg.MSG_OOB != 0 and (t.fd_table.fds[fd].fd_type == .udp_socket or t.fd_table.fds[fd].fd_type == .raw_socket)) return -95;
    if (t.fd_table.fds[fd].fd_type == .tcp_socket) {
        if (buf == 0 or buf >= 0x0000_8000_0000_0000 or len == 0) return -1;
        const tcb_idx = t.fd_table.fds[fd].tcb_idx;
        if (flags & urg.MSG_OOB != 0) return @import("../fs/namespace_policy.zig").sendResult(net_mod.tcp.tcpSendOobBlocking(tcb_idx, buf, len, net_mod.tcp_recv_policy.nonblockRequested(vfs_mod.statusFlagsOf(&t.fd_table.fds[fd]), flags)), flags);
        return @import("../fs/namespace_policy.zig").sendResult(net_mod.tcp.tcpSendBlocking(tcb_idx, buf, true, len, net_mod.tcp_recv_policy.nonblockRequested(vfs_mod.statusFlagsOf(&t.fd_table.fds[fd]), flags)), flags);
    } else if (t.fd_table.fds[fd].fd_type == .udp_socket and t.fd_table.fds[fd].udp_ping) {
        if (buf >= 0x0000_8000_0000_0000) return -14;
        var pbuf: [@import("ping_policy.zig").MAX_MESSAGE]u8 = undefined;
        if (len > pbuf.len) return -90; // EMSGSIZE
        if (len != 0 and copy.copyFromUser(pbuf[0..len], @ptrFromInt(buf), len) != len) return -14;
        return pingSend(&t.fd_table.fds[fd], pbuf[0..len], addr_ptr, addr_len, &.{});
    } else if (t.fd_table.fds[fd].fd_type == .raw_socket) {
        // The destination is the address given or the connected peer; rawSendFrom checks it before the length.
        if (len != 0 and (buf == 0 or buf >= 0x0000_8000_0000_0000)) return -14;
        var pbuf: [@import("raw_icmp.zig").MAX_HDRINCL]u8 = undefined;
        if (len > pbuf.len) return -90; // EMSGSIZE
        if (len != 0 and copy.copyFromUser(pbuf[0..len], @ptrFromInt(buf), len) != len) return -14;
        if (addr_ptr == 0) return rawSendFrom(&t.fd_table.fds[fd], pbuf[0..len], null, &.{});
        return rawSendFrom(&t.fd_table.fds[fd], pbuf[0..len], .{ .ptr = addr_ptr, .len = addr_len }, &.{});
    } else if (t.fd_table.fds[fd].fd_type == .udp_socket) {
        // inet_send_prepare: the socket is named before anything else is checked, so even a send that fails leaves it a port.
        const ab = udpAutobind(&t.fd_table.fds[fd]);
        if (ab != 0) return ab;
        if (buf == 0 or buf >= 0x0000_8000_0000_0000 or len == 0) return -1;
        const is_v6 = t.fd_table.fds[fd].udp_is_v6;
        const src_key = t.fd_table.fds[fd].udpKey();
        // A pending ICMP error (port unreachable) fails this send, once.
        const pending_send_err = udp.takePendingError(t.fd_table.fds[fd].udpKey());
        if (pending_send_err != 0) return -@as(i64, pending_send_err);
        if (is_v6) {
            var tmp6: [1452]u8 = undefined;
            const to_copy6 = @min(len, tmp6.len);
            var dst6: [16]u8 = @splat(0);
            var dst_port6: u16 = 0;
            var scope6: u32 = 0;
            if (addr_ptr != 0 and addr_ptr < 0x0000_8000_0000_0000) {
                if (addr_len < sa.SOCKADDR_IN6_LEN) return -22;
                var sa6: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
                if (copy.copyFromUser(&sa6, @ptrFromInt(addr_ptr), sa.SOCKADDR_IN6_LEN) < sa.SOCKADDR_IN6_LEN)
                    return -22;
                const parsed = sa.parseInet6(&sa6) orelse return -97; // EAFNOSUPPORT
                dst6 = parsed.addr;
                dst_port6 = parsed.port;
                scope6 = parsed.scope_id;
            } else if (t.fd_table.fds[fd].udp_connected) {
                dst6 = t.fd_table.fds[fd].udp_dst_ip6;
                dst_port6 = t.fd_table.fds[fd].udp_dst_port;
            } else {
                return -89; // EDESTADDRREQ
            }
            const oif6 = udp.sendOif6(src_key, dst6, scope6);
            const unreach6 = bind_addr_policy.routeErrno6(dst6, oif6);
            if (unreach6 != 0) return unreach6;
            if (udpOversize6(src_key, dst6, dst_port6, len)) |e| return e;
            const n6 = copy.copyFromUser(&tmp6, @ptrFromInt(buf), to_copy6);
            if (n6 == 0) return -1;
            if (udp.sendToV6From(t.fd_table.fds[fd].udp_local_ip6, dst6, dst_port6, src_key, oif6, &tmp6, @intCast(n6))) {
                return @intCast(n6);
            } else {
                return -1;
            }
        }
        var tmp_buf2: [1472]u8 = undefined;
        const to_copy2 = @min(len, 1472);
        var dst_ip: [4]u8 = .{ 0, 0, 0, 0 };
        var dst_port: u16 = 0;
        if (addr_ptr != 0 and addr_ptr < 0x0000_8000_0000_0000) {
            if (addr_len < SOCKADDR_IN_MIN_LEN) return -22;
            var sa_buf: [16]u8 = undefined;
            if (copy.copyFromUser(sa_buf[0..SOCKADDR_IN_MIN_LEN], @ptrFromInt(addr_ptr), SOCKADDR_IN_MIN_LEN) != SOCKADDR_IN_MIN_LEN) return -14;
            dst_port = bo.readU16BeAt(&sa_buf, 2);
            dst_ip = .{ sa_buf[4], sa_buf[5], sa_buf[6], sa_buf[7] };
        } else if (t.fd_table.fds[fd].udp_connected) {
            // Use connected destination when no address provided (send() on connected UDP)
            dst_ip = t.fd_table.fds[fd].udp_dst_ip;
            dst_port = t.fd_table.fds[fd].udp_dst_port;
        } else {
            return -89; // EDESTADDRREQ — unconnected UDP socket, no destination given
        }
        const lo_rc = @import("route4_policy.zig").loopbackSourceErrno(t.fd_table.fds[fd].udp_local_ip, dst_ip, netif.getOurIp(), @import("arp.zig").loopbackAllowed());
        if (lo_rc != 0) return lo_rc;
        if (udpOversize4(src_key, dst_ip, dst_port, len)) |e| return e;
        // A datagram longer than one frame (it will be fragmented): staged in a kmalloc buffer, not on the stack.
        if (len > tmp_buf2.len) {
            const big = bigStage(len) orelse return -105; // ENOBUFS
            defer @import("../mm/slab.zig").kfree(big.ptr);
            if (copy.copyFromUser(big, @ptrFromInt(buf), len) != len) return -14;
            return if (udp.sendToFrom(t.fd_table.fds[fd].udp_local_ip, dst_ip, dst_port, src_key, big.ptr, @intCast(len))) @intCast(len) else -1;
        }
        const n2 = copy.copyFromUser(&tmp_buf2, @ptrFromInt(buf), to_copy2);
        if (n2 == 0) return -1;
        if (udp.sendToFrom(t.fd_table.fds[fd].udp_local_ip, dst_ip, dst_port, src_key, &tmp_buf2, @intCast(n2))) {
            return @intCast(n2);
        } else {
            return -1;
        }
    } else if (t.fd_table.fds[fd].fd_type == .unix_socket) {
        // AF_UNIX: connected sockets only (STREAM pair, or DGRAM after
        // connect() set a default peer). An explicit destination address is
        // not supported — unixSend routes through the established peer_idx.
        if (buf == 0 or buf >= 0x0000_8000_0000_0000 or len == 0) return -1;
        var tmp_unix: [8192]u8 = undefined;
        const to_copy_unix = @min(len, 8192);
        const n_unix = copy.copyFromUser(&tmp_unix, @ptrFromInt(buf), to_copy_unix);
        if (n_unix == 0) return -1;
        const unix_idx = t.fd_table.fds[fd].unix_sock_idx;
        // sendto(addr): an explicit destination path (datagram sockets).
        if (addr_ptr != 0 and addr_len != 0) {
            var dest_buf: [110]u8 = undefined;
            const dlen = switch (unixDestPath(addr_ptr, addr_len, &dest_buf)) {
                .ok => |n| n,
                .err => |e| return e,
            };
            return @import("../fs/namespace_policy.zig").sendResult(net_mod.unix_socket.unixSendToBlocking(unix_idx, &tmp_unix, n_unix, dest_buf[2..][0..dlen], @import("../fs/namespace_policy.zig").nonblockRequested(vfs_mod.statusFlagsOf(&t.fd_table.fds[fd]), flags)), flags);
        }
        return @import("../fs/namespace_policy.zig").sendResult(net_mod.unix_socket.unixSendBlocking(unix_idx, &tmp_unix, n_unix, @import("../fs/namespace_policy.zig").nonblockRequested(vfs_mod.statusFlagsOf(&t.fd_table.fds[fd]), flags)), flags);
    } else {
        // Not a socket — use regular write
        var tmp_buf: [4096]u8 = undefined;
        const to_copy = @min(len, 4096);
        const n = copy.copyFromUser(&tmp_buf, @ptrFromInt(buf), to_copy);
        if (n == 0) return -1;
        const result = vfs_mod.FdTable.write(t.fd_table, fd, &tmp_buf, n);
        return result;
    }
}

/// Wait until a datagram is queued for `port`. Returns 0 when one is there (or
/// may be: the caller re-checks), -EAGAIN for a non-blocking socket or an
/// expired SO_RCVTIMEO, -EINTR when a signal ended the wait. The wait is a
/// series of short sleeps that also pump the loopback device, so a datagram
/// sent from another process on 127/8 arrives without an explicit net_poll.
fn udpWaitForDatagram(port: u32, is_v6: bool, nonblock: bool) i64 {
    const urp = @import("udp_recv_policy.zig");
    const tsc = @import("../arch/arch.zig").tsc;
    const lo = @import("lo.zig");
    const se = @import("../arch/x86_64/syscall_entry.zig");
    var deadline: ?u64 = null;
    var armed = false;
    while (true) {
        if (!armed) {
            const ms = if (udp.getPortOpts(port)) |o| o.rcv_ms else 0;
            deadline = urp.deadlineNs(tsc.nanos(), ms);
            armed = true;
        }
        _ = lo.drain();
        const step = urp.step(udp.hasQueuedDatagramFor(port, is_v6), nonblock, urp.timedOut(deadline, tsc.nanos()));
        switch (step) {
            .deliver => return 0,
            .eagain => return -11,
            .wait => {},
        }
        const now = tsc.nanos();
        const slice = now +| 5 * 1_000_000;
        const rc = se.sleepUntil(if (deadline) |d| @min(slice, d) else slice, 0);
        if (rc < 0) return rc;
    }
}

/// recvfrom(fd, buf, len, flags, addr_ptr, addr_len_ptr) → bytes received or -errno
pub fn recvfrom(fd: u32, buf: u64, len: u32, flags: u32, addr_ptr: u64, addr_len_ptr: u64) i64 {
    // UDP honors MSG_PEEK (leave the datagram queued) and MSG_TRUNC (report
    // the full datagram length even when the buffer is smaller). Other flag
    // bits keep the historical ignore behavior.
    const msg_peek = (flags & 0x02) != 0;
    const msg_trunc = (flags & 0x20) != 0;
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS) return -9;

    if (t.fd_table.fds[fd].fd_type == .raw_socket) {
        var pbuf: [@import("raw_icmp.zig").RAW_QUEUE_LEN]u8 = undefined;
        const want = @min(@as(usize, len), pbuf.len);
        if (buf == 0 or buf >= 0x0000_8000_0000_0000) return -14;
        if (len != 0 and !copy.validateUserBufferWritable(buf, want)) return -14;
        var src: [16]u8 = @splat(0);
        const got = rawRecvInto(&t.fd_table.fds[fd], pbuf[0..want], flags, &src);
        if (got < 0) return got;
        const copy_len: usize = @intCast(@min(@as(i64, @intCast(want)), got));
        if (copy_len != 0 and copy.copyToUser(@ptrFromInt(buf), pbuf[0..copy_len], copy_len) != copy_len) return -14;
        if (addr_ptr != 0 and addr_len_ptr != 0) {
            var len_bytes: [4]u8 = undefined;
            if (!copy.validateUserBuffer(addr_len_ptr, 4) or copy.copyFromUser(&len_bytes, @ptrFromInt(addr_len_ptr), 4) != 4) return -14;
            const rip = @import("raw_icmp_policy.zig");
            var name: [28]u8 = @splat(0);
            var name_len: u32 = 16;
            if (@import("raw_icmp.zig").isV6(t.fd_table.fds[fd].raw_idx)) {
                name = rip.fromName6(src, sa.nameScope6(src));
                name_len = 28;
            } else @memcpy(name[0..16], &rip.fromName(src[0..4].*));
            const to_copy: u32 = @min(bo.readU32Le(&len_bytes), name_len);
            if (to_copy != 0 and copy.copyToUser(@ptrFromInt(addr_ptr), name[0..to_copy], to_copy) != to_copy) return -14;
            bo.writeU32Le(&len_bytes, name_len);
            if (copy.copyToUser(@ptrFromInt(addr_len_ptr), &len_bytes, 4) != 4) return -14;
        }
        return got;
    }

    if (t.fd_table.fds[fd].fd_type == .unix_socket) {
        if (buf == 0 or buf >= 0x0000_8000_0000_0000 or len == 0) return -1;
        var tmp_buf: [8192]u8 = undefined;
        const to_read = @min(len, 8192);
        if (!copy.validateUserBufferWritable(buf, to_read)) return -14; // EFAULT
        const unix_idx = t.fd_table.fds[fd].unix_sock_idx;
        const rf = @import("recv_flags_policy.zig");
        const nonblock_u = @import("../fs/namespace_policy.zig").nonblockRequested(vfs_mod.statusFlagsOf(&t.fd_table.fds[fd]), flags);
        var full_len_u: usize = 0;
        var src_u: net_mod.unix_socket.SrcName = .{};
        var result: i64 = undefined;
        if (rf.peek(flags)) {
            result = net_mod.unix_socket.unixPeek(unix_idx, &tmp_buf, to_read, &full_len_u);
            // Like a blocking read, a peek waits for something to look at.
            while (result == -11 and !nonblock_u) {
                const w = net_mod.unix_socket.unixWaitReadable(unix_idx);
                if (w != 0) return w;
                result = net_mod.unix_socket.unixPeek(unix_idx, &tmp_buf, to_read, &full_len_u);
            }
        } else {
            var rights_out: net_mod.unix_socket.RightsOut = .{};
            const is_stream_u = net_mod.unix_socket.unixIsStream(unix_idx);
            result = net_mod.unix_socket.unixRecvBlockingRights(unix_idx, &tmp_buf, to_read, nonblock_u, &rights_out);
            full_len_u = rights_out.full_len;
            src_u = rights_out.src;
            for (rights_out.descs[0..rights_out.count]) |*d| vfs_mod.releaseDescriptor(d);
            // MSG_WAITALL: keep reading until the buffer is full (stream only).
            if (result > 0 and rf.waitAll(flags, is_stream_u, nonblock_u)) {
                var got: usize = @intCast(result);
                while (rf.waitAllStep(to_read, got, 1) == .again) {
                    var more: net_mod.unix_socket.RightsOut = .{};
                    const r2 = net_mod.unix_socket.unixRecvBlockingRights(unix_idx, @as([*]u8, @ptrCast(&tmp_buf)) + got, to_read - got, false, &more);
                    for (more.descs[0..more.count]) |*d| vfs_mod.releaseDescriptor(d);
                    if (rf.waitAllStep(to_read, got, r2) == .stop) break;
                    got += @intCast(r2);
                }
                result = @intCast(got);
            }
        }
        if (result > 0) {
            const copied = copy.copyToUser(@ptrFromInt(buf), @as([*]const u8, @ptrCast(&tmp_buf))[0..@intCast(result)], @intCast(result));
            if (copied != @as(usize, @intCast(result))) return -14; // EFAULT
            // The sender's bound name, as Linux reports it (a datagram from an unbound sender has no address: length 0).
            if (addr_ptr != 0 and addr_len_ptr != 0) {
                var nb: [2 + net_mod.unix_socket.UNIX_PATH_MAX + 1]u8 = undefined;
                const nl: u32 = if (src_u.len == 0) 0 else @import("socket_address_policy.zig").unixNameEncode(src_u.name[0..src_u.len], &nb);
                const rc = copySockaddrToUser(addr_ptr, addr_len_ptr, nb[0..nl], nl);
                if (rc != 0) return rc;
            }
            // MSG_TRUNC on a datagram socket reports the real message length.
            if (rf.truncReportsFullLength(flags) and full_len_u > @as(usize, @intCast(result))) return @intCast(full_len_u);
        }
        return result;
    } else if (t.fd_table.fds[fd].fd_type == .tcp_socket) {
        if (flags & urg.MSG_OOB != 0) return tcpRecvOobTo(t.fd_table.fds[fd].tcb_idx, buf, len, flags);
        if (buf == 0 or buf >= 0x0000_8000_0000_0000 or len == 0) return -1;
        var tmp_buf: [4096]u8 = undefined;
        const to_read = @min(len, 4096);
        if (!copy.validateUserBufferWritable(buf, to_read)) return -14; // EFAULT
        const tcb_idx = t.fd_table.fds[fd].tcb_idx;
        const nonblock = net_mod.tcp_recv_policy.nonblockRequested(vfs_mod.statusFlagsOf(&t.fd_table.fds[fd]), flags);
        const rf = @import("recv_flags_policy.zig");
        var result: i64 = undefined;
        if (rf.peek(flags)) {
            result = net_mod.tcp.tcpPeek(tcb_idx, &tmp_buf, to_read);
            while (result == -11 and !nonblock) {
                const w = net_mod.tcp.tcpWaitReadable(tcb_idx);
                if (w != 0) return w;
                result = net_mod.tcp.tcpPeek(tcb_idx, &tmp_buf, to_read);
            }
        } else {
            result = net_mod.tcp.tcpRecvBlocking(tcb_idx, &tmp_buf, to_read, nonblock);
            // MSG_WAITALL: keep reading until the buffer is full or the stream ends.
            if (result > 0 and rf.waitAll(flags, true, nonblock)) {
                var got: usize = @intCast(result);
                while (rf.waitAllStep(to_read, got, 1) == .again) {
                    const r2 = net_mod.tcp.tcpRecvBlocking(tcb_idx, @as([*]u8, @ptrCast(&tmp_buf)) + got, @intCast(to_read - got), false);
                    if (rf.waitAllStep(to_read, got, r2) == .stop) break;
                    got += @intCast(r2);
                }
                result = @intCast(got);
            }
        }
        if (result > 0) {
            const copied = copy.copyToUser(@ptrFromInt(buf), @as([*]const u8, @ptrCast(&tmp_buf))[0..@intCast(result)], @intCast(result));
            if (copied != @as(usize, @intCast(result))) return -14; // EFAULT
        }
        return result;
    } else if (t.fd_table.fds[fd].fd_type == .udp_socket) {
        if (buf == 0 or buf >= 0x0000_8000_0000_0000 or len == 0) return -1;
        const is_v6 = t.fd_table.fds[fd].udp_is_v6;
        const sock_key = t.fd_table.fds[fd].udpKey();
        // An ICMP port-unreachable for what this connected socket sent is
        // reported once, before any queued data (Linux: the next call fails).
        const pending = udp.takePendingError(sock_key);
        if (pending != 0) return -@as(i64, pending);
        const wait_rc = udpWaitForDatagram(sock_key, is_v6, @import("../fs/namespace_policy.zig").nonblockRequested(vfs_mod.statusFlagsOf(&t.fd_table.fds[fd]), flags));
        if (wait_rc != 0) return wait_rc;
        var user_addr_len: u32 = 0;
        if (addr_ptr != 0) {
            if (addr_len_ptr == 0 or !copy.validateUserBufferWritable(addr_len_ptr, 4)) return -14;
            var len_bytes: [4]u8 = undefined;
            if (copy.copyFromUser(&len_bytes, @ptrFromInt(addr_len_ptr), 4) != 4) return -14;
            user_addr_len = @bitCast(len_bytes);
        }
        if (is_v6) {
            var tmp6: [1452]u8 = undefined;
            const to_read6 = @min(len, tmp6.len);
            if (!copy.validateUserBufferWritable(buf, to_read6)) return -14; // EFAULT
            if (addr_ptr != 0) {
                const addr_copy_len = @min(user_addr_len, sa.SOCKADDR_IN6_LEN);
                if (addr_copy_len != 0 and !copy.validateUserBufferWritable(addr_ptr, addr_copy_len)) return -14;
            }
            var src6: [16]u8 = @splat(0);
            var src_port_out6: u16 = 0;
            var full_len6: u16 = 0;
            const result6 = udp.recvFromV6Ex(sock_key, &tmp6, @intCast(tmp6.len), &src6, &src_port_out6, &full_len6, msg_peek);
            if (result6 > 0) {
                const to_write6 = @min(@as(u32, @intCast(result6)), to_read6);
                if (copy.copyToUser(@ptrFromInt(buf), @as([*]const u8, @ptrCast(&tmp6))[0..to_write6], to_write6) != to_write6) return -14;
                if (addr_ptr != 0 and addr_ptr < 0x0000_8000_0000_0000) {
                    var sa_out6: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
                    const alen = sa.writeInet6(&sa_out6, src_port_out6, src6, sa.nameScope6(src6));
                    const addr_copy_len = @min(user_addr_len, alen);
                    if (addr_copy_len != 0 and copy.copyToUser(@ptrFromInt(addr_ptr), sa_out6[0..addr_copy_len], addr_copy_len) != addr_copy_len) return -14;
                    var al6: [4]u8 = .{
                        @truncate(alen),
                        @truncate(alen >> 8),
                        @truncate(alen >> 16),
                        @truncate(alen >> 24),
                    };
                    if (copy.copyToUser(@ptrFromInt(addr_len_ptr), &al6, 4) != 4) return -14;
                }
                return if (msg_trunc) @as(i64, full_len6) else @intCast(to_write6);
            }
            return 0;
        }
        var tmp_buf2: [1472]u8 = undefined;
        const to_read2 = @min(len, 1472);
        if (!copy.validateUserBufferWritable(buf, to_read2)) return -14; // EFAULT
        if (addr_ptr != 0) {
            const addr_copy_len = @min(user_addr_len, sa.SOCKADDR_IN_LEN);
            if (addr_copy_len != 0 and !copy.validateUserBufferWritable(addr_ptr, addr_copy_len)) return -14;
        }
        var src_ip: [4]u8 = .{ 0, 0, 0, 0 };
        var src_port_out: u16 = 0;
        var full_len: u16 = 0;
        var big_meta: ip_cmsg_policy.RecvInfo = .{};
        // A reassembled datagram longer than one frame: copied straight from its pinned buffer.
        const big = udp.takeBig(sock_key, &src_ip, &src_port_out, msg_peek, &big_meta);
        defer if (big) |bt| udp.releaseBig(bt, msg_peek);
        const result2: i64 = if (big) |bt| bt.len else udp.recvFromEx(sock_key, &tmp_buf2, @intCast(tmp_buf2.len), &src_ip, &src_port_out, &full_len, msg_peek);
        if (big) |bt| full_len = bt.len;
        if (result2 > 0) {
            const to_write: u32 = if (big != null) @intCast(@min(@as(u64, full_len), len)) else @min(@as(u32, @intCast(result2)), to_read2);
            if (big) |bt| {
                if (!copy.validateUserBufferWritable(buf, to_write)) return -14;
                if (copy.copyToUser(@ptrFromInt(buf), udp.bigBytes(bt)[0..to_write], to_write) != to_write) return -14;
            } else if (copy.copyToUser(@ptrFromInt(buf), @as([*]const u8, @ptrCast(&tmp_buf2))[0..to_write], to_write) != to_write) return -14;
            if (addr_ptr != 0 and addr_ptr < 0x0000_8000_0000_0000) {
                // A whole sockaddr_in (16 bytes, sin_zero cleared), cut to the caller's length; the reported length is 16 (Linux
                // udp_recvmsg / ping_recvmsg set msg_namelen to sizeof(struct sockaddr_in)).
                var sa_out: [sa.SOCKADDR_IN_LEN]u8 = @splat(0);
                _ = sa.writeInet4(&sa_out, src_port_out, src_ip);
                const addr_copy_len = @min(user_addr_len, sa.SOCKADDR_IN_LEN);
                if (addr_copy_len != 0 and copy.copyToUser(@ptrFromInt(addr_ptr), sa_out[0..addr_copy_len], addr_copy_len) != addr_copy_len) return -14;
                var al: [4]u8 = .{ sa.SOCKADDR_IN_LEN, 0, 0, 0 };
                if (copy.copyToUser(@ptrFromInt(addr_len_ptr), &al, 4) != 4) return -14;
            }
            return if (msg_trunc) @as(i64, full_len) else @intCast(to_write);
        } else {
            return 0;
        }
    } else {
        // Not a socket — use regular read
        var tmp_buf: [4096]u8 = undefined;
        const to_read = @min(len, 4096);
        if (!copy.validateUserBufferWritable(buf, to_read)) return -14; // EFAULT
        const result = vfs_mod.FdTable.read(t.fd_table, fd, &tmp_buf, to_read);
        if (result > 0) {
            const copied = copy.copyToUser(@ptrFromInt(buf), @as([*]const u8, @ptrCast(&tmp_buf))[0..@intCast(result)], @intCast(result));
            if (copied != @as(usize, @intCast(result))) return -14; // EFAULT
        }
        return result;
    }
}

/// setsockopt(fd, level, optname, optval, optlen) → 0 or -errno
pub fn setsockopt(fd: u64, level: u64, optname: u64, optval: u64, optlen: u64) i64 {
    const result = net_mod.socket_opt.sysSetSockopt(fd, level, optname, optval, optlen);
    return result;
}

/// getsockopt(fd, level, optname, optval, optlen_ptr) → 0 or -errno
pub fn getsockopt(fd: u64, level: u64, optname: u64, optval: u64, optlen_ptr: u64) i64 {
    const result = net_mod.socket_opt.sysGetSockopt(fd, level, optname, optval, optlen_ptr);
    return result;
}

/// connect(fd, addr_ptr, addr_len) → 0 or -errno
pub fn connect(fd: u32, addr_ptr: u64, addr_len: u32) i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS) return -88;

    if (t.fd_table.fds[fd].fd_type == .raw_socket) return rawConnect(&t.fd_table.fds[fd], addr_ptr, addr_len);

    // AF_UNIX connect: sockaddr_un (family + path), routed to unixConnect.
    if (t.fd_table.fds[fd].fd_type == .unix_socket) {
        const unix_idx = t.fd_table.fds[fd].unix_sock_idx;
        if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000) return -14;
        if (!@import("socket_address_policy.zig").unixLengthValid(addr_len, SOCKADDR_UN_PATH_OFFSET)) return -22;
        var sock_addr_buf: [110]u8 = undefined;
        const to_copy = @min(@as(usize, addr_len), sock_addr_buf.len);
        const copied = copy.copyFromUser(sock_addr_buf[0..to_copy], @ptrFromInt(addr_ptr), to_copy);
        if (copied <= SOCKADDR_UN_PATH_OFFSET) return -22; // EINVAL
        const path_len = @import("socket_address_policy.zig").unixNameLen(sock_addr_buf[2..copied]);
        const result = net_mod.unix_socket.unixConnect(unix_idx, @ptrCast(sock_addr_buf[2 .. 2 + path_len].ptr), path_len);
        return @as(i64, result);
    }

    // UDP connect: set default destination
    if (t.fd_table.fds[fd].fd_type == .udp_socket) {
        if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000) return -14;
        var fam: [2]u8 = @splat(0);
        if (addr_len >= 2 and copy.copyFromUser(&fam, @ptrFromInt(addr_ptr), 2) != 2) return -14;
        const sap = @import("socket_address_policy.zig");
        const action = if (t.fd_table.fds[fd].udp_is_v6) sap.dgramConnectAction6(addr_len, bo.readU16Le(&fam)) else sap.dgramConnectAction(addr_len, bo.readU16Le(&fam));
        switch (action) {
            .einval => return -22,
            .eafnosupport => return -97,
            .disconnect => {
                t.fd_table.fds[fd].udp_connected = false;
                t.fd_table.fds[fd].udp_dst_ip = @splat(0);
                t.fd_table.fds[fd].udp_dst_ip6 = @splat(0);
                t.fd_table.fds[fd].udp_dst_port = 0;
                udp.disconnect(t.fd_table.fds[fd].udpKey());
                return 0;
            },
            .address => {},
        }
        // ip4_datagram_connect autobinds before it touches the address, so even a connect that fails names the socket.
        if (!t.fd_table.fds[fd].udp_ping) {
            const ab = udpAutobind(&t.fd_table.fds[fd]);
            if (ab != 0) return ab;
        }
        if (t.fd_table.fds[fd].udp_is_v6) {
            if (!@import("socket_address_policy.zig").inetLengthValid(addr_len, true)) return -22;
            var sa6: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
            if (copy.copyFromUser(&sa6, @ptrFromInt(addr_ptr), sa.SOCKADDR_IN6_LEN) < sa.SOCKADDR_IN6_LEN)
                return -22;
            const parsed = sa.parseInet6(&sa6) orelse return -97;
            // A scoped peer ties the socket to its interface; the route is checked before the socket counts as connected.
            const dev_rc = udp.connectDev6(t.fd_table.fds[fd].udpKey(), parsed.addr, parsed.scope_id);
            if (dev_rc != 0) return dev_rc;
            t.fd_table.fds[fd].udp_connected = true;
            t.fd_table.fds[fd].udp_dst_ip6 = parsed.addr;
            t.fd_table.fds[fd].udp_dst_port = parsed.port;
            // A ping socket has no remote port: setPeer's nonzero port only marks it connected.
            udp.setPeer(t.fd_table.fds[fd].udpKey(), if (t.fd_table.fds[fd].udp_ping) 1 else parsed.port, parsed.addr);
            if (t.fd_table.fds[fd].udp_ping and !t.fd_table.fds[fd].udp_ping_bound) {
                udp.pingRehash(t.fd_table.fds[fd].udpKey());
                t.fd_table.fds[fd].udp_ping_bound = true;
            }
            return 0;
        }
        if (!@import("socket_address_policy.zig").inetLengthValid(addr_len, false)) return -22;
        var sock_addr: [8]u8 = undefined;
        if (copy.copyFromUser(&sock_addr, @ptrFromInt(addr_ptr), 8) != 8) return -14;
        if (!@import("socket_address_policy.zig").inet4FamilyValid(bo.readU16Le(sock_addr[0..2]))) return -97;
        const dst_port = bo.readU16BeAt(&sock_addr, 2);
        const dst_ip = [4]u8{ sock_addr[4], sock_addr[5], sock_addr[6], sock_addr[7] };
        // ip4_datagram_connect routes the peer first: a 127/8-bound socket cannot connect out through the NIC, and stays unconnected.
        const lo_rc = @import("route4_policy.zig").loopbackSourceErrno(t.fd_table.fds[fd].udp_local_ip, dst_ip, netif.getOurIp(), @import("arp.zig").loopbackAllowed());
        if (lo_rc != 0) return lo_rc;
        t.fd_table.fds[fd].udp_connected = true;
        t.fd_table.fds[fd].udp_dst_ip = dst_ip;
        t.fd_table.fds[fd].udp_dst_port = dst_port;
        var peer16: [16]u8 = @splat(0);
        @memcpy(peer16[0..4], &dst_ip);
        // A ping socket has no remote port; its receive filter is the peer address alone (setPeer's port marks it connected).
        udp.setPeer(t.fd_table.fds[fd].udpKey(), if (t.fd_table.fds[fd].udp_ping) 1 else dst_port, peer16);
        // connect() of a ping socket hashes it (ip4_datagram_connect autobinds), so getsockname names its ident.
        if (t.fd_table.fds[fd].udp_ping and !t.fd_table.fds[fd].udp_ping_bound) {
            udp.pingRehash(t.fd_table.fds[fd].udpKey());
            t.fd_table.fds[fd].udp_ping_bound = true;
        }
        return 0;
    }

    if (t.fd_table.fds[fd].fd_type != .tcp_socket) return -88;
    const tcb_idx = t.fd_table.fds[fd].tcb_idx;

    if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000) return -14;
    const info = net_mod.tcp.tcpGetAddrInfo(tcb_idx) orelse return -1;
    if (info.is_v6) {
        if (!@import("socket_address_policy.zig").inetLengthValid(addr_len, true)) return -22;
        var sa6: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
        if (copy.copyFromUser(&sa6, @ptrFromInt(addr_ptr), sa.SOCKADDR_IN6_LEN) < sa.SOCKADDR_IN6_LEN)
            return -22;
        const parsed = sa.parseInet6(&sa6) orelse return -97;
        // A link-local peer ties the socket to its interface; a group or a missing interface fails before the handshake starts.
        const dev_rc = net_mod.tcp.tcpConnectDev6(tcb_idx, parsed.addr, parsed.scope_id);
        if (dev_rc != 0) return dev_rc;
        return finishTcpConnect(t, fd, net_mod.tcp.tcpConnectSocketV6(tcb_idx, parsed.addr, parsed.port));
    }
    if (!@import("socket_address_policy.zig").inetLengthValid(addr_len, false)) return -22;
    var sock_addr: [8]u8 = undefined;
    if (copy.copyFromUser(&sock_addr, @ptrFromInt(addr_ptr), 8) != 8) return -14;
    if (!@import("socket_address_policy.zig").inet4FamilyValid(bo.readU16Le(sock_addr[0..2]))) return -97;
    const port = bo.readU16BeAt(&sock_addr, 2);
    const ip = [4]u8{ sock_addr[4], sock_addr[5], sock_addr[6], sock_addr[7] };
    // tcp_v4_connect routes first (ip_route_connect): from a 127/8 address only lo destinations, else EINVAL with nothing sent.
    const lo_rc = @import("route4_policy.zig").loopbackSourceErrno(info.local_ip, ip, netif.getOurIp(), @import("arp.zig").loopbackAllowed());
    if (lo_rc != 0) return lo_rc;
    return finishTcpConnect(t, fd, net_mod.tcp.tcpConnectSocket(tcb_idx, ip, port));
}

/// connect() returns once the handshake is started: EINPROGRESS for a
/// non-blocking socket (completion shows up as POLLOUT, or POLLERR with the
/// reason in SO_ERROR), otherwise it waits for the outcome.
fn finishTcpConnect(t: *task_mod.Task, fd: u32, started: i64) i64 {
    if (started != 0) return started;
    if (net_mod.tcp_recv_policy.nonblockRequested(vfs_mod.statusFlagsOf(&t.fd_table.fds[fd]), 0)) return -115; // EINPROGRESS
    return net_mod.tcp.tcpWaitConnected(t.fd_table.fds[fd].tcb_idx);
}

fn copySockaddrToUser(addr_ptr: u64, addrlen_ptr: u64, sa_buf: []const u8, alen: u32) i64 {
    if (!copy.validateUserBuffer(addrlen_ptr, 4)) return -14;
    var len_bytes: [4]u8 = undefined;
    if (copy.copyFromUser(&len_bytes, @ptrFromInt(addrlen_ptr), 4) != 4) return -14;
    const user_len: u32 = @bitCast(len_bytes);
    const to_copy = @min(@min(user_len, alen), @as(u32, @intCast(sa_buf.len)));
    if (!copy.validateUserRange(addr_ptr, to_copy) or
        !copy.validateUserBufferWritable(addrlen_ptr, 4)) return -14;
    if (to_copy != 0) {
        if (!copy.validateUserBufferWritable(addr_ptr, to_copy)) return -14;
        if (copy.copyToUser(@ptrFromInt(addr_ptr), sa_buf[0..to_copy], to_copy) != to_copy) return -14;
    }
    len_bytes = @bitCast(alen);
    if (copy.copyToUser(@ptrFromInt(addrlen_ptr), &len_bytes, 4) != 4) return -14;
    return 0;
}

/// A sockaddr_un for `n`: the family, then — for a named socket — the path and its NUL.
/// The unnamed address is the family alone (2 bytes).
fn unixNameBytes(n: net_mod.unix_socket.NameResult, out: []u8) u32 {
    return @import("socket_address_policy.zig").unixNameEncode(n.path[0..n.len], out);
}

/// getsockname(fd, addr_ptr, addrlen_ptr) → 0 or -errno
pub fn getsockname(fd: u32, addr_ptr: u64, addrlen_ptr: u64) i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS) return -88;
    const desc = cur.fd_table.fds[fd];

    if (desc.fd_type == .raw_socket) {
        // inet_getname: AF_INET, the protocol as the port (inet_num), the bound address; a raw socket reports no peer.
        const raw = @import("raw_icmp.zig");
        if (raw.isV6(desc.raw_idx)) {
            const name6 = @import("raw_icmp_policy.zig").sockName6(raw.boundAddr6(desc.raw_idx), raw.protocolOf(desc.raw_idx));
            return copySockaddrToUser(addr_ptr, addrlen_ptr, &name6, 28);
        }
        const name = @import("raw_icmp_policy.zig").sockName(raw.boundAddr(desc.raw_idx), raw.protocolOf(desc.raw_idx));
        return copySockaddrToUser(addr_ptr, addrlen_ptr, &name, 16);
    }

    if (desc.fd_type == .udp_socket) {
        var sa_buf: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
        const our4 = net_mod.tcp_port_policy.nameAddr(desc.udp_local_ip, desc.udp_connected, desc.udp_dst_ip, netif.getOurIp());
        // An unbound socket with a non-loopback peer reports the source address chosen for that peer (SK-86: the preferred global
        // address, or the link-local one for a link-local peer or when there is no global address).
        const pref6 = ndp.selectSourceAddress(desc.udp_dst_ip6, netif.getMac());
        const our6 = net_mod.tcp_port_policy.nameAddr6(desc.udp_local_ip6, desc.udp_connected, desc.udp_dst_ip6, pref6);
        // A socket tied to an interface by a scoped bind names that interface.
        // A ping socket names port 0 until bind or its first send gives it an ident (Linux inet_num is 0 before that).
        // A UDP socket names port 0 until bind, connect or a send gives it one, and again after connect(AF_UNSPEC) gave up a port the
        // user did not choose (Linux inet_sport 0).
        const name_port: u16 = if (desc.udp_ping and !desc.udp_ping_bound) 0 else if (!desc.udp_ping and !udp.isNamed(desc.udpKey())) 0 else desc.udp_port;
        const alen = if (desc.udp_is_v6) sa.writeInet6(&sa_buf, name_port, our6, sa.boundScope6(our6, udp.boundDev6(desc.udpKey()))) else sa.encodeUdpName(false, name_port, our4, our6, &sa_buf);
        if (alen == 0) return -1;
        return copySockaddrToUser(addr_ptr, addrlen_ptr, sa_buf[0..alen], alen);
    }

    if (desc.fd_type == .unix_socket) {
        const n = net_mod.unix_socket.unixSockName(desc.unix_sock_idx) orelse return -9;
        var ub: [2 + net_mod.unix_socket.UNIX_PATH_MAX + 1]u8 = undefined;
        const ulen = unixNameBytes(n, &ub);
        return copySockaddrToUser(addr_ptr, addrlen_ptr, ub[0..ulen], ulen);
    }

    if (desc.fd_type != .tcp_socket) return -88;
    const info = net_mod.tcp.tcpGetAddrInfo(desc.tcb_idx) orelse return -1;

    var sa_buf: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
    const alen = sa.encodeInetName(info.is_v6, info.local_port, info.local_ip, info.local_ip6, &sa_buf);
    if (alen == 0) return -1;
    return copySockaddrToUser(addr_ptr, addrlen_ptr, sa_buf[0..alen], alen);
}

/// getpeername(fd, addr_ptr, addrlen_ptr) → 0 or -errno
pub fn getpeername(fd: u32, addr_ptr: u64, addrlen_ptr: u64) i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS) return -88;
    const desc = cur.fd_table.fds[fd];

    if (desc.fd_type == .raw_socket) {
        // __inet_get_peer: without a peer port (a raw socket's inet_dport stays 0) there is no peer name.
        return ENOTCONN;
    }

    if (desc.fd_type == .udp_socket) {
        // A ping socket has no peer port, so even a connected one has no peer name (inet_getname / inet6_getname want inet_dport).
        if (!desc.udp_connected or desc.udp_ping) return ENOTCONN;
        var sa_buf: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
        const alen = sa.encodeUdpName(desc.udp_is_v6, desc.udp_dst_port, desc.udp_dst_ip, desc.udp_dst_ip6, &sa_buf);
        if (alen == 0) return -1;
        return copySockaddrToUser(addr_ptr, addrlen_ptr, sa_buf[0..alen], alen);
    }

    if (desc.fd_type == .unix_socket) {
        const n = net_mod.unix_socket.unixPeerName(desc.unix_sock_idx) orelse return -9;
        if (!n.ok) return ENOTCONN;
        var ub: [2 + net_mod.unix_socket.UNIX_PATH_MAX + 1]u8 = undefined;
        const ulen = unixNameBytes(n, &ub);
        return copySockaddrToUser(addr_ptr, addrlen_ptr, ub[0..ulen], ulen);
    }

    if (desc.fd_type != .tcp_socket) return -88;
    const peer_rc = net_mod.tcp.tcpPeerErrno(desc.tcb_idx);
    if (peer_rc != 0) return peer_rc;
    const info = net_mod.tcp.tcpGetAddrInfo(desc.tcb_idx) orelse return -1;

    var sa_buf: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
    const alen = sa.encodeInetName(info.is_v6, info.remote_port, info.remote_ip, info.remote_ip6, &sa_buf);
    if (alen == 0) return -1;
    return copySockaddrToUser(addr_ptr, addrlen_ptr, sa_buf[0..alen], alen);
}

/// shutdown(fd, how) → 0 or -errno
pub fn shutdown(fd: u32, how: u32) i64 {
    if (!@import("socket_policy.zig").shutdownHowValid(how)) return -22;
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS or cur.fd_table.fds[fd].fd_type == .none) return -9; // EBADF
    // inet_shutdown: a raw socket takes the flags; it is ENOTCONN unless connected.
    if (cur.fd_table.fds[fd].fd_type == .raw_socket) return @import("raw_icmp.zig").shutdown(cur.fd_table.fds[fd].raw_idx, how);
    if (cur.fd_table.fds[fd].fd_type == .unix_socket) {
        return net_mod.unix_socket.unixShutdown(cur.fd_table.fds[fd].unix_sock_idx, how);
    }
    if (cur.fd_table.fds[fd].fd_type != .tcp_socket) return -88; // ENOTSOCK
    const result = net_mod.tcp.tcpShutdown(cur.fd_table.fds[fd].tcb_idx, how);
    return result;
}

/// Gather an iovec array into `dst`; returns the byte count or a negative errno.
fn gatherIov(iov_ptr: u64, iov_len: u64, dst: []u8) i64 {
    var total: usize = 0;
    var i: usize = 0;
    while (i < iov_len and total < dst.len) : (i += 1) {
        var iov_buf: [16]u8 = undefined;
        if (copy.copyFromUser(&iov_buf, @ptrFromInt(iov_ptr + @as(u64, @intCast(i)) * 16), 16) != 16) return -14;
        const base = bo.readU64At(&iov_buf, 0);
        const sz: usize = @intCast(@min(bo.readU64At(&iov_buf, 8), dst.len - total));
        if (sz == 0) continue;
        if (base == 0 or base >= 0x0000_8000_0000_0000) return -14;
        if (copy.copyFromUser(dst[total..][0..sz], @ptrFromInt(base), sz) != sz) return -14;
        total += sz;
    }
    return @intCast(total);
}

/// sendmsg on an AF_UNIX socket: the iovec bytes plus optional SCM_RIGHTS.
fn unixSendmsg(cur: *task_mod.Task, fd: u32, msghdr: *const [56]u8) i64 {
    const sp = @import("scm_policy.zig");
    const iov_ptr: u64 = bo.readU64At(msghdr, 16);
    const iov_len: u64 = bo.readU64At(msghdr, 24);
    const ctl_ptr: u64 = bo.readU64At(msghdr, 32);
    const ctl_len: u64 = bo.readU64At(msghdr, 40);
    if (iov_len > 1024) return -22;
    if (iov_len != 0 and (iov_ptr == 0 or iov_ptr >= 0x0000_8000_0000_0000)) return -14;

    var rights: net_mod.unix_socket.RightsIn = .{};
    if (ctl_ptr != 0 and ctl_len != 0) {
        if (ctl_len > 256 or ctl_ptr >= 0x0000_8000_0000_0000) return -22;
        var ctl: [256]u8 = undefined;
        const n: usize = @intCast(ctl_len);
        if (copy.copyFromUser(ctl[0..n], @ptrFromInt(ctl_ptr), n) != n) return -14;
        const parsed = switch (sp.parseRights(ctl[0..n])) {
            .ok => |p| p,
            .err => |e| return if (e == .too_many) @as(i64, -22) else @as(i64, -22),
        };
        if (parsed.has_cred) {
            const own_pid: i32 = @intCast(if (cur.is_thread and cur.parent_tid != 0) cur.parent_tid else cur.tid);
            const caps = cur.effective_caps;
            if (!sp.credsAcceptable(parsed.cred_pid, parsed.cred_uid, parsed.cred_gid, own_pid, cur.uid, cur.gid, caps.cap_sys_admin, caps.cap_setuid, caps.cap_setgid)) return -1; // EPERM
            rights.cred_override = .{ .pid = parsed.cred_pid, .uid = parsed.cred_uid, .gid = parsed.cred_gid };
        }
        for (parsed.fds[0..parsed.count]) |raw| {
            if (raw < 0 or @as(u32, @intCast(raw)) >= vfs_mod.MAX_FDS) {
                releaseRights(&rights);
                return -9; // EBADF
            }
            const snap = vfs_mod.snapshotForPassing(cur.fd_table, @intCast(raw)) orelse {
                releaseRights(&rights);
                return -9; // EBADF (closed, or a kind that cannot be passed)
            };
            rights.descs[rights.count] = snap;
            rights.count += 1;
        }
    }

    var data: [8192]u8 = undefined;
    const got = gatherIov(iov_ptr, iov_len, &data);
    if (got < 0) {
        releaseRights(&rights);
        return got;
    }
    const idx = cur.fd_table.fds[fd].unix_sock_idx;
    // A descriptor set rides on at least one data byte.
    if (rights.count > 0 and got == 0) {
        releaseRights(&rights);
        return -22;
    }
    // msg_name / msg_namelen (offsets 0 and 8): an explicit destination path.
    const name_ptr: u64 = bo.readU64At(msghdr, 0);
    const name_len: u32 = @truncate(bo.readU64At(msghdr, 8));
    var dest_buf: [110]u8 = undefined;
    var dest: ?[]const u8 = null;
    if (name_ptr != 0 and name_len != 0) {
        const dlen = switch (unixDestPath(name_ptr, name_len, &dest_buf)) {
            .ok => |n| n,
            .err => |e| {
                releaseRights(&rights);
                return e;
            },
        };
        dest = dest_buf[2..][0..dlen];
    }
    const sent = net_mod.unix_socket.unixSendRightsTo(idx, &data, @intCast(got), &rights, dest);
    releaseRights(&rights); // still held only if the send did not take them
    return sent;
}

fn releaseRights(r: *net_mod.unix_socket.RightsIn) void {
    for (r.descs[0..r.count]) |*d| vfs_mod.releaseDescriptor(d);
    r.count = 0;
}

/// recvmsg on an AF_UNIX socket: scatter the bytes, install received
/// descriptors, and write the control message, msg_controllen and msg_flags.
fn unixRecvmsg(cur: *task_mod.Task, fd: u32, msg_ptr: u64, msghdr: *const [56]u8, flags: u32) i64 {
    const sp = @import("scm_policy.zig");
    const iov_ptr: u64 = bo.readU64At(msghdr, 16);
    const iov_len: u64 = bo.readU64At(msghdr, 24);
    const ctl_ptr: u64 = bo.readU64At(msghdr, 32);
    const ctl_len: u64 = bo.readU64At(msghdr, 40);
    if (iov_len > 1024) return -22;
    if (iov_len != 0 and (iov_ptr == 0 or iov_ptr >= 0x0000_8000_0000_0000)) return -14;
    const want_ctl = ctl_ptr != 0 and ctl_len >= sp.HDR;

    // Total room across the iovecs.
    var room: usize = 0;
    var i: usize = 0;
    while (i < iov_len) : (i += 1) {
        var iov_buf: [16]u8 = undefined;
        if (copy.copyFromUser(&iov_buf, @ptrFromInt(iov_ptr + @as(u64, @intCast(i)) * 16), 16) != 16) return -14;
        room += @intCast(@min(bo.readU64At(&iov_buf, 8), 8192));
        if (room >= 8192) {
            room = 8192;
            break;
        }
    }
    if (room == 0) return 0;

    var data: [8192]u8 = undefined;
    var out: net_mod.unix_socket.RightsOut = .{};
    const idx = cur.fd_table.fds[fd].unix_sock_idx;
    const nonblock = @import("../fs/namespace_policy.zig").nonblockRequested(vfs_mod.statusFlagsOf(&cur.fd_table.fds[fd]), flags);
    const rf = @import("recv_flags_policy.zig");
    const is_stream = net_mod.unix_socket.unixIsStream(idx);
    var n: i64 = undefined;
    if (rf.peek(flags)) {
        // MSG_PEEK: look without consuming; no descriptor set is delivered.
        var full: usize = 0;
        n = net_mod.unix_socket.unixPeek(idx, &data, room, &full);
        while (n == -11 and !nonblock) {
            const w = net_mod.unix_socket.unixWaitReadable(idx);
            if (w != 0) return w;
            n = net_mod.unix_socket.unixPeek(idx, &data, room, &full);
        }
        out.full_len = full;
        out.cred = net_mod.unix_socket.unixSenderCred(idx);
    } else {
        // Always ask for the set: a receiver without a control buffer still must
        // learn (MSG_CTRUNC) that descriptors were dropped.
        n = net_mod.unix_socket.unixRecvBlockingRights(idx, &data, room, nonblock, &out);
        // MSG_WAITALL: keep reading until the iovecs are full (stream only). A
        // descriptor set that arrives after the first one cannot be delivered
        // in the same call: it is dropped and reported as MSG_CTRUNC.
        if (n > 0 and rf.waitAll(flags, is_stream, nonblock)) {
            var got: usize = @intCast(n);
            while (rf.waitAllStep(room, got, 1) == .again) {
                var more: net_mod.unix_socket.RightsOut = .{};
                const r2 = net_mod.unix_socket.unixRecvBlockingRights(idx, @as([*]u8, @ptrCast(&data)) + got, room - got, false, &more);
                if (more.count > 0) {
                    if (out.count == 0) {
                        out = more;
                    } else {
                        for (more.descs[0..more.count]) |*d| vfs_mod.releaseDescriptor(d);
                        out.dropped = true;
                    }
                }
                if (rf.waitAllStep(room, got, r2) == .stop) break;
                got += @intCast(r2);
            }
            n = @intCast(got);
        }
    }
    if (n < 0) return n;

    // Scatter the bytes.
    var done: usize = 0;
    i = 0;
    while (i < iov_len and done < @as(usize, @intCast(n))) : (i += 1) {
        var iov_buf: [16]u8 = undefined;
        if (copy.copyFromUser(&iov_buf, @ptrFromInt(iov_ptr + @as(u64, @intCast(i)) * 16), 16) != 16) break;
        const base = bo.readU64At(&iov_buf, 0);
        const sz: usize = @intCast(@min(bo.readU64At(&iov_buf, 8), @as(u64, @intCast(n)) - done));
        if (sz == 0) continue;
        if (copy.copyToUser(@ptrFromInt(base), data[done..][0..sz], sz) != sz) break;
        done += sz;
    }

    // SO_PASSCRED: the sender's credentials come first in the control data.
    var out_flags: u32 = 0;
    var written: usize = 0;
    var ctl_buf: [256]u8 = undefined;
    const pass_cred = (net_mod.unix_socket.unixOptView(idx) orelse return -9).opts.flags & 32 != 0;
    if (pass_cred) {
        const cb = sp.buildCredentials(out.cred.pid, out.cred.uid, out.cred.gid, if (want_ctl) @intCast(@min(ctl_len, 256)) else 0, &ctl_buf);
        if (cb.truncated) {
            out_flags |= sp.MSG_CTRUNC;
        } else {
            written = cb.written;
        }
    }

    // Install the descriptors and build the control message.
    var newfds: [sp.MAX_FDS]i32 = undefined;
    var installed: usize = 0;
    if (out.count > 0 and !want_ctl) {
        for (out.descs[0..out.count]) |*d| vfs_mod.releaseDescriptor(d);
        out_flags |= sp.MSG_CTRUNC;
    } else if (out.count > 0) {
        const cloexec = (flags & sp.MSG_CMSG_CLOEXEC) != 0;
        const room_for_fds = @as(usize, @intCast(@min((ctl_len -| written) -| sp.HDR, 4 * sp.MAX_FDS))) / 4;
        for (out.descs[0..out.count]) |d| {
            if (installed >= room_for_fds) {
                vfs_mod.releaseDescriptor(&d);
                out_flags |= sp.MSG_CTRUNC;
                continue;
            }
            if (vfs_mod.installPassed(cur.fd_table, d, cloexec)) |slot| {
                newfds[installed] = @intCast(slot);
                installed += 1;
            } else {
                vfs_mod.releaseDescriptor(&d);
                out_flags |= sp.MSG_CTRUNC;
            }
        }
        if (installed > 0) {
            const base = written;
            const bl = sp.buildRights(newfds[0..installed], @intCast(@min(ctl_len, 256) -| base), ctl_buf[base..]);
            written = base + bl.written;
            if (bl.truncated) out_flags |= sp.MSG_CTRUNC;
        }
    }
    if (written > 0) {
        if (copy.copyToUser(@ptrFromInt(ctl_ptr), ctl_buf[0..written], written) != written) {
            // Descriptors installed for the control message must not leak.
            for (newfds[0..installed]) |nf| _ = cur.fd_table.close(@intCast(nf));
            return -14;
        }
    }
    if (out.dropped) out_flags |= sp.MSG_CTRUNC;
    // A datagram longer than the buffers is cut: say so (Linux sets MSG_TRUNC
    // in msg_flags whenever data was discarded).
    const cut_datagram = out.full_len > @as(usize, @intCast(n));
    if (cut_datagram) out_flags |= rf.MSG_TRUNC;
    // msg_name / msg_namelen: the sender's bound name (an unbound sender: length 0).
    const rname_ptr: u64 = bo.readU64At(msghdr, 0);
    const rname_cap: u32 = bo.readU32Le(msghdr[8..12]);
    if (rname_ptr != 0 and rname_ptr < 0x0000_8000_0000_0000) {
        var nb: [2 + net_mod.unix_socket.UNIX_PATH_MAX + 1]u8 = undefined;
        const nl: u32 = if (out.src.len == 0) 0 else @import("socket_address_policy.zig").unixNameEncode(out.src.name[0..out.src.len], &nb);
        const to_copy = @min(nl, rname_cap);
        if (to_copy != 0 and copy.copyToUser(@ptrFromInt(rname_ptr), nb[0..to_copy], to_copy) != to_copy) return -14;
        var nlb: [4]u8 = undefined;
        bo.writeU32Le(&nlb, nl);
        _ = copy.copyToUser(@ptrFromInt(msg_ptr + 8), &nlb, 4);
    }
    // msg_controllen and msg_flags
    var tail: [8]u8 = undefined;
    bo.writeU64Le(&tail, written);
    _ = copy.copyToUser(@ptrFromInt(msg_ptr + 40), &tail, 8);
    var fl: [4]u8 = undefined;
    bo.writeU32Le(&fl, out_flags);
    _ = copy.copyToUser(@ptrFromInt(msg_ptr + 48), &fl, 4);
    // MSG_TRUNC as an input flag returns the real datagram length.
    if (rf.truncReportsFullLength(flags) and cut_datagram) return @intCast(out.full_len);
    return n;
}

/// A kmalloc staging buffer of `n` bytes for a datagram that will be fragmented (freed by the caller with slab.kfree(ptr)).
fn bigStage(n: usize) ?[]u8 {
    const p = @import("../mm/slab.zig").kmalloc(n) orelse return null;
    return @as([*]u8, @ptrCast(p))[0..n];
}

/// Whether a sendmsg on this UDP socket may carry a datagram longer than one frame: an IPv4 UDP socket (fragmented on the way out);
/// IPv6 and ping sockets still refuse it.
fn udpSendmsgFragmentable(fd: u32) bool {
    const cur_idx = sched_mod.currentTaskIndex() orelse return false;
    const t = task_mod.getTask(cur_idx) orelse return false;
    const d = &t.fd_table.fds[fd];
    return !d.udp_is_v6 and !d.udp_ping;
}

/// sendmsg on a UDP socket: gather the iovecs into one datagram and send it
/// through sendto (destination from msg_name, or the connected peer).
fn udpSendmsg(fd: u32, msghdr: *const [56]u8) i64 {
    const name_ptr: u64 = bo.readU64At(msghdr, 0);
    const name_len: u32 = bo.readU32Le(msghdr[8..12]);
    const iov_ptr: u64 = bo.readU64At(msghdr, 16);
    const iov_len: u64 = bo.readU64At(msghdr, 24);
    if (iov_len > 1024) return -22;
    if (iov_len != 0 and (iov_ptr == 0 or iov_ptr >= 0x0000_8000_0000_0000)) return -14;
    // msg_control is copied in whole first (____sys_sendmsg): a bad pointer is EFAULT; more than this stack keeps is ENOBUFS.
    const ctl_ptr: u64 = bo.readU64At(msghdr, 32);
    const ctl_len: u64 = bo.readU64At(msghdr, 40);
    var ctl: [UDP_SEND_CTL_MAX]u8 = undefined;
    if (ctl_len > UDP_SEND_CTL_MAX) return -105;
    const cl: usize = @intCast(ctl_len);
    if (cl != 0) {
        if (ctl_ptr == 0 or ctl_ptr >= 0x0000_8000_0000_0000) return -14;
        if (copy.copyFromUser(ctl[0..cl], @ptrFromInt(ctl_ptr), cl) != cl) return -14;
    }
    var data: [1472]u8 = undefined;
    // The datagram is the whole iovec. One longer than the stack buffer is gathered into a kmalloc buffer when it may be sent
    // (fragmented: an IPv4 socket); otherwise udpSendBytesFull refuses it (EMSGSIZE), never a cut copy.
    const total = iovTotal(iov_ptr, iov_len);
    if (total < 0) return total;
    if (total > data.len and total <= udp.MAX_UDP_PAYLOAD_BIG and udpSendmsgFragmentable(fd)) {
        const big = bigStage(@intCast(total)) orelse return -105;
        defer @import("../mm/slab.zig").kfree(big.ptr);
        const g = gatherIov(iov_ptr, iov_len, big);
        if (g < 0) return g;
        return udpSendBytesFull(fd, big[0..@intCast(g)], @intCast(total), name_ptr, name_len, ctl[0..cl]);
    }
    const got = gatherIov(iov_ptr, iov_len, &data);
    if (got < 0) return got;
    if (total == 0) return 0;
    return udpSendBytesFull(fd, data[0..@intCast(got)], @intCast(total), name_ptr, name_len, ctl[0..cl]);
}

/// The longest msg_control a UDP or raw sendmsg takes (Linux allows up to net.core.optmem_max).
const UDP_SEND_CTL_MAX: usize = 512;

/// Who may send the privileged SOL_SOCKET control messages (SO_MARK, a high SO_PRIORITY).
fn sendCaps() ip_cmsg_policy.SendCaps {
    const idx = sched_mod.currentTaskIndex() orelse return .{};
    return .{ .net_admin = cap_mod.hasSysCap(idx, "cap_net_admin"), .net_raw = cap_mod.hasSysCap(idx, "cap_net_raw") };
}

/// Whether `a` is an address of the NIC (its link-local or a global one), for IPV6_PKTINFO's source check.
fn isOwnNicAddr6(a: [16]u8) bool {
    return ndp.isOwnAddress(a, netif.getMac());
}

/// Send `payload` as one datagram on UDP socket `fd` (the sendto UDP path without the user-buffer copy). `control` is sendmsg's
/// msg_control: it is parsed once the destination is known (udp_sendmsg / udpv6_sendmsg: EDESTADDRREQ comes first), and its
/// IP_TTL / IP_TOS / IP_PKTINFO (IPv4) or IPV6_HOPLIMIT / IPV6_TCLASS / IPV6_PKTINFO (IPv6) apply to this datagram only. An IPv4 ping
/// socket reads it in pingSend; an IPv6 one does not.
/// The summed length of `iov_len` iovecs at `iov_ptr`, or -EFAULT when the array cannot be read.
fn iovTotal(iov_ptr: u64, iov_len: u64) i64 {
    var total: u64 = 0;
    var i: usize = 0;
    while (i < iov_len) : (i += 1) {
        var iov_buf: [16]u8 = undefined;
        if (copy.copyFromUser(&iov_buf, @ptrFromInt(iov_ptr + @as(u64, @intCast(i)) * 16), 16) != 16) return -14;
        total +|= bo.readU64At(&iov_buf, 8);
    }
    return @intCast(@min(total, 0x7FFF_FFFF));
}

/// Send one UDP datagram of `full_len` bytes of which `payload` holds the start (all of it whenever it fits a frame).
fn udpSendBytesFull(fd: u32, payload: []const u8, full_len: usize, addr_ptr: u64, addr_len: u32, control: []const u8) i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;
    const d = &t.fd_table.fds[fd];
    if (d.udp_ping) return pingSend(d, payload, addr_ptr, addr_len, control);
    const ab = udpAutobind(d);
    if (ab != 0) return ab;
    const src_key = d.udpKey();
    if (d.udp_is_v6) {
        var dst6: [16]u8 = @splat(0);
        var dst_port6: u16 = 0;
        var scope6: u32 = 0;
        if (addr_ptr != 0 and addr_ptr < 0x0000_8000_0000_0000) {
            if (addr_len < sa.SOCKADDR_IN6_LEN) return -22;
            var sa6: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
            if (copy.copyFromUser(&sa6, @ptrFromInt(addr_ptr), sa.SOCKADDR_IN6_LEN) < sa.SOCKADDR_IN6_LEN) return -22;
            const parsed = sa.parseInet6(&sa6) orelse return -97;
            dst6 = parsed.addr;
            dst_port6 = parsed.port;
            scope6 = parsed.scope_id;
        } else if (d.udp_connected) {
            dst6 = d.udp_dst_ip6;
            dst_port6 = d.udp_dst_port;
        } else return -89;
        if (udpOversize6(src_key, dst6, dst_port6, full_len)) |e| return e;
        const n6 = payload.len;
        var oif6 = udp.sendOif6(src_key, dst6, scope6);
        // ip6_datagram_send_ctl runs once the destination is known; IPV6_PKTINFO may name the interface and the source.
        const ctx6: ip_cmsg_policy.Ctx6 = .{ .pre_oif = oif6, .nic_active = nic_mod.isActive(), .isOwnNic = isOwnNicAddr6 };
        const ov6 = switch (ip_cmsg_policy.parseSend6(control, sendCaps(), ctx6)) {
            .ok => |v| v,
            .err => |e| return e,
        };
        if (ov6.pktinfo and ov6.oif != 0) oif6 = @intCast(@min(ov6.oif, 255));
        const src6 = if (ov6.pktinfo and !std.mem.allEqual(u8, &ov6.src, 0)) ov6.src else d.udp_local_ip6;
        const unreach6 = bind_addr_policy.routeErrno6(dst6, oif6);
        if (unreach6 != 0) return unreach6;
        return if (udp.sendToV6FromOv(src6, dst6, dst_port6, src_key, oif6, payload.ptr, @intCast(n6), ov6.hops, ov6.tclass)) @intCast(n6) else -1;
    }
    var dst_ip: [4]u8 = .{ 0, 0, 0, 0 };
    var dst_port: u16 = 0;
    if (addr_ptr != 0 and addr_ptr < 0x0000_8000_0000_0000) {
        if (addr_len < SOCKADDR_IN_MIN_LEN) return -22;
        var sa_buf: [16]u8 = undefined;
        if (copy.copyFromUser(sa_buf[0..SOCKADDR_IN_MIN_LEN], @ptrFromInt(addr_ptr), SOCKADDR_IN_MIN_LEN) != SOCKADDR_IN_MIN_LEN) return -14;
        dst_port = bo.readU16BeAt(&sa_buf, 2);
        dst_ip = .{ sa_buf[4], sa_buf[5], sa_buf[6], sa_buf[7] };
    } else if (d.udp_connected) {
        dst_ip = d.udp_dst_ip;
        dst_port = d.udp_dst_port;
    } else return -89;
    const ov = switch (ip_cmsg_policy.parseSend4(control, sendCaps())) {
        .ok => |v| v,
        .err => |e| return e,
    };
    // IP_PKTINFO replaces the source (ipc.addr), the bound address included; the route lookup then checks it, then the interface.
    var src = d.udp_local_ip;
    if (ov.pktinfo) {
        src = ov.spec_dst;
        const src_rc = ip_cmsg_policy.sourceErrno4(src, netif.getOurIp(), nic_mod.isActive());
        if (src_rc != 0) return src_rc;
        const oif_rc = ip_cmsg_policy.oifErrno4(ov.oif, nic_mod.isActive());
        if (oif_rc != 0) return oif_rc;
    }
    const lo_rc = @import("route4_policy.zig").loopbackSourceErrno(src, dst_ip, netif.getOurIp(), @import("arp.zig").loopbackAllowed());
    if (lo_rc != 0) return lo_rc;
    if (udpOversize4(src_key, dst_ip, dst_port, full_len)) |e| return e;
    return if (udp.sendToFromOv(src, dst_ip, dst_port, src_key, payload.ptr, @intCast(payload.len), ov.ttl, ov.tos)) @intCast(payload.len) else -1;
}

/// udpOversize4 for IPv6 (__ip6_append_data → ipv6_local_error): EMSGSIZE for a datagram over the path MTU, queued with IPV6_RECVERR
/// under IPV6_PMTUDISC_DO or PROBE.
fn udpOversize6(key: u32, dst: [16]u8, dst_port: u16, len: usize) ?i64 {
    const ipo = (udp.getPortOpts(key) orelse return null).ip;
    const o = errq.oversize6(len, @import("ipv6.zig").getSendMtu(dst), ipo.pmtudisc6, ipo.recverr6) orelse return null;
    if (o.queue) udp.queueLocalError(key, errq.localEntry6(90, o.info, dst, dst_port));
    return -90; // EMSGSIZE
}

/// A UDP datagram that does not fit the path MTU (this stack does not fragment): EMSGSIZE, and with IP_RECVERR under IP_PMTUDISC_DO or
/// PROBE a local error-queue entry (Linux __ip_append_data → ip_local_error). Null when it fits.
fn udpOversize4(key: u32, dst_ip: [4]u8, dst_port: u16, len: usize) ?i64 {
    const ipo = (udp.getPortOpts(key) orelse return null).ip;
    const o = errq.oversize(len, @import("ipv4.zig").getSendMtu(dst_ip), ipo.pmtudisc, ipo.recverr) orelse return null;
    if (o.queue) udp.queueLocalError(key, errq.localEntry(90, o.info, dst_ip, dst_port));
    return -90; // EMSGSIZE
}

/// recvmsg on a UDP socket: wait like recvfrom, scatter the datagram over the
/// iovecs, fill msg_name, and report MSG_TRUNC in msg_flags.
fn udpRecvmsg(cur: *task_mod.Task, fd: u32, msg_ptr: u64, msghdr: *const [56]u8, flags: u32) i64 {
    if (flags & errq.MSG_ERRQUEUE != 0) return udpRecvErrqueue(cur.fd_table.fds[fd].udpKey(), cur.fd_table.fds[fd].udp_is_v6, msg_ptr, msghdr);
    const name_ptr: u64 = bo.readU64At(msghdr, 0);
    const name_len: u32 = bo.readU32Le(msghdr[8..12]);
    const iov_ptr: u64 = bo.readU64At(msghdr, 16);
    const iov_len: u64 = bo.readU64At(msghdr, 24);
    if (iov_len > 1024) return -22;
    if (iov_len != 0 and (iov_ptr == 0 or iov_ptr >= 0x0000_8000_0000_0000)) return -14;
    const d = &cur.fd_table.fds[fd];
    const is_v6 = d.udp_is_v6;
    const port = d.udpKey();
    const wait_rc = udpWaitForDatagram(port, is_v6, @import("../fs/namespace_policy.zig").nonblockRequested(vfs_mod.statusFlagsOf(d), flags));
    if (wait_rc != 0) return wait_rc;

    var data: [1472]u8 = undefined;
    var full: u16 = 0;
    var got: i64 = 0;
    var src4: [4]u8 = .{ 0, 0, 0, 0 };
    var src6: [16]u8 = @splat(0);
    var src_port: u16 = 0;
    const peek = (flags & 0x02) != 0;
    var meta: ip_cmsg_policy.RecvInfo = .{};
    var meta6: ip_cmsg_policy.RecvInfo6 = .{};
    var big: ?udp.BigTake = null;
    if (is_v6) {
        got = udp.recvFromV6Meta(port, &data, @intCast(data.len), &src6, &src_port, &full, peek, &meta6);
    } else {
        big = udp.takeBig(port, &src4, &src_port, peek, &meta);
        if (big) |bt| {
            got = bt.len;
            full = bt.len;
        } else got = udp.recvFromMeta(port, &data, @intCast(data.len), &src4, &src_port, &full, peek, &meta);
    }
    defer if (big) |bt| udp.releaseBig(bt, peek);
    if (got < 0) return got;
    const src_bytes: []const u8 = if (big) |bt| udp.bigBytes(bt) else data[0..@intCast(@max(got, 0))];

    // Scatter.
    var done: usize = 0;
    var i: usize = 0;
    while (i < iov_len and done < @as(usize, @intCast(got))) : (i += 1) {
        var iov_buf: [16]u8 = undefined;
        if (copy.copyFromUser(&iov_buf, @ptrFromInt(iov_ptr + @as(u64, @intCast(i)) * 16), 16) != 16) break;
        const base = bo.readU64At(&iov_buf, 0);
        const sz: usize = @intCast(@min(bo.readU64At(&iov_buf, 8), @as(u64, @intCast(got)) - done));
        if (sz == 0) continue;
        if (base == 0 or base >= 0x0000_8000_0000_0000) return -14;
        if (copy.copyToUser(@ptrFromInt(base), src_bytes[done..][0..sz], sz) != sz) return -14;
        done += sz;
    }

    // msg_name / msg_namelen
    if (name_ptr != 0 and name_ptr < 0x0000_8000_0000_0000) {
        var out: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
        const alen: u32 = if (is_v6) sa.writeInet6(&out, src_port, src6, sa.nameScope6(src6)) else sa.writeInet4(&out, src_port, src4);
        const n = @min(name_len, alen);
        if (n != 0 and copy.copyToUser(@ptrFromInt(name_ptr), out[0..n], n) != n) return -14;
        var al: [4]u8 = undefined;
        bo.writeU32Le(&al, alen);
        _ = copy.copyToUser(@ptrFromInt(msg_ptr + 8), &al, 4);
    }
    // Control messages (ip_cmsg_recv_offset for IPv4, ip6_datagram_recv_ctl for IPv6), then msg_controllen and msg_flags.
    const ctl_ptr: u64 = bo.readU64At(msghdr, 32);
    const ctl_cap: usize = if (ctl_ptr == 0) 0 else @intCast(@min(bo.readU64At(msghdr, 40), 1 << 20));
    const port_opts = udp.getPortOpts(port);
    const opts_ip: ip_opt_policy.IpOpts = if (port_opts) |po| po.ip else .{};
    const sol_flags: u16 = if (port_opts) |po| po.flags else 0;
    var ctl_buf: [192]u8 = undefined;
    const cm = if (is_v6)
        ip_cmsg_policy.build6(ip_cmsg_policy.Wanted.of6(opts_ip).withStamp(sol_flags), meta6, ctl_cap, &ctl_buf)
    else
        ip_cmsg_policy.build(ip_cmsg_policy.Wanted.of(opts_ip).withStamp(sol_flags), meta, ctl_cap, &ctl_buf);
    if (cm.written != 0) {
        if (ctl_ptr >= 0x0000_8000_0000_0000) return -14;
        if (copy.copyToUser(@ptrFromInt(ctl_ptr), ctl_buf[0..cm.written], cm.written) != cm.written) return -14;
    }
    var cl: [8]u8 = undefined;
    bo.writeU64Le(&cl, cm.written);
    _ = copy.copyToUser(@ptrFromInt(msg_ptr + 40), &cl, 8);
    const truncated = @as(usize, full) > done;
    var fl: [4]u8 = undefined;
    bo.writeU32Le(&fl, (if (truncated) @as(u32, 0x20) else 0) | (if (cm.truncated) @as(u32, 0x08) else 0));
    _ = copy.copyToUser(@ptrFromInt(msg_ptr + 48), &fl, 4);
    return if ((flags & 0x20) != 0) @as(i64, full) else @intCast(done);
}

const errq = @import("errqueue_policy.zig");

/// recvmsg(MSG_ERRQUEUE) on a UDP socket (ip_recv_error / ipv6_recv_error): the oldest queued ICMP or ICMPv6 error, never blocking (EAGAIN when there is none).
/// The quoted payload goes to the iovecs (MSG_TRUNC when cut), msg_name is the datagram's destination, the control message
/// IP_RECVERR (IPV6_RECVERR at SOL_IPV6) carries struct sock_extended_err and the ICMP sender, and msg_flags has MSG_ERRQUEUE.
fn udpRecvErrqueue(key: u32, is_v6: bool, msg_ptr: u64, msghdr: *const [56]u8) i64 {
    _ = is_v6;
    return recvErrqueueEntry(udp.takeQueuedError(key) orelse return -11, msg_ptr, msghdr);
}

/// recvmsg(MSG_ERRQUEUE)'s copy-out of one taken entry, for any datagram socket.
fn recvErrqueueEntry(e: errq.Entry, msg_ptr: u64, msghdr: *const [56]u8) i64 {
    const name_ptr: u64 = bo.readU64At(msghdr, 0);
    const name_len: u32 = bo.readU32Le(msghdr[8..12]);
    const iov_ptr: u64 = bo.readU64At(msghdr, 16);
    const iov_len: u64 = bo.readU64At(msghdr, 24);
    if (iov_len > 1024) return -90;
    const data = e.payload[0..e.len];
    var done: usize = 0;
    var i: usize = 0;
    while (i < iov_len and done < data.len) : (i += 1) {
        var iov_buf: [16]u8 = undefined;
        if (copy.copyFromUser(&iov_buf, @ptrFromInt(iov_ptr + @as(u64, @intCast(i)) * 16), 16) != 16) return -14;
        const base = bo.readU64At(&iov_buf, 0);
        const sz: usize = @intCast(@min(bo.readU64At(&iov_buf, 8), @as(u64, data.len - done)));
        if (sz == 0) continue;
        if (base == 0 or base >= 0x0000_8000_0000_0000) return -14;
        if (copy.copyToUser(@ptrFromInt(base), data[done..][0..sz], sz) != sz) return -14;
        done += sz;
    }
    if (name_ptr != 0 and name_ptr < 0x0000_8000_0000_0000) {
        var out: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
        const alen: u32 = if (e.v6) sa.writeInet6(&out, e.dst_port, e.dst, 0) else sa.writeInet4(&out, e.dst_port, e.dst[0..4].*);
        const n = @min(name_len, alen);
        if (n != 0 and copy.copyToUser(@ptrFromInt(name_ptr), out[0..n], n) != n) return -14;
        var al: [4]u8 = undefined;
        bo.writeU32Le(&al, alen);
        _ = copy.copyToUser(@ptrFromInt(msg_ptr + 8), &al, 4);
    }
    const ctl_ptr: u64 = bo.readU64At(msghdr, 32);
    const ctl_cap: usize = if (ctl_ptr == 0) 0 else @intCast(@min(bo.readU64At(msghdr, 40), 1 << 20));
    var ctl_buf: [64]u8 = undefined;
    const ext = errq.encodeExtErr(e);
    const cm = ip_cmsg_policy.buildRecvErr(ext.bytes[0..ext.len], e.v6, ctl_cap, &ctl_buf);
    if (cm.written != 0) {
        if (ctl_ptr >= 0x0000_8000_0000_0000) return -14;
        if (copy.copyToUser(@ptrFromInt(ctl_ptr), ctl_buf[0..cm.written], cm.written) != cm.written) return -14;
    }
    var cl: [8]u8 = undefined;
    bo.writeU64Le(&cl, cm.written);
    _ = copy.copyToUser(@ptrFromInt(msg_ptr + 40), &cl, 8);
    var fl: [4]u8 = undefined;
    bo.writeU32Le(&fl, errq.MSG_ERRQUEUE | (if (done < data.len) @as(u32, 0x20) else 0) | (if (cm.truncated) @as(u32, 0x08) else 0));
    _ = copy.copyToUser(@ptrFromInt(msg_ptr + 48), &fl, 4);
    return @intCast(done);
}

/// sendmsg on a raw ICMP socket (raw_sendmsg / rawv6_sendmsg): msg_control is copied in whole first (a bad pointer is EFAULT, more
/// than UDP_SEND_CTL_MAX ENOBUFS), the iovecs are gathered into one message, msg_name (or the connected peer) is the destination,
/// and the rest is the sendto path with the control messages.
fn rawSendmsg(d: *const vfs_mod.FileDescriptor, msghdr: *const [56]u8) i64 {
    const name_ptr: u64 = bo.readU64At(msghdr, 0);
    const name_len: u32 = bo.readU32Le(msghdr[8..12]);
    const iov_ptr: u64 = bo.readU64At(msghdr, 16);
    const iov_len: u64 = bo.readU64At(msghdr, 24);
    if (iov_len > 1024) return -22;
    if (iov_len != 0 and (iov_ptr == 0 or iov_ptr >= 0x0000_8000_0000_0000)) return -14;
    if (name_ptr >= 0x0000_8000_0000_0000) return -14;
    const ctl_ptr: u64 = bo.readU64At(msghdr, 32);
    const ctl_len: u64 = bo.readU64At(msghdr, 40);
    var ctl: [UDP_SEND_CTL_MAX]u8 = undefined;
    if (ctl_len > UDP_SEND_CTL_MAX) return -105;
    const cl: usize = @intCast(ctl_len);
    if (cl != 0) {
        if (ctl_ptr == 0 or ctl_ptr >= 0x0000_8000_0000_0000) return -14;
        if (copy.copyFromUser(ctl[0..cl], @ptrFromInt(ctl_ptr), cl) != cl) return -14;
    }
    var data: [@import("raw_icmp.zig").MAX_HDRINCL]u8 = undefined;
    const got = gatherIov(iov_ptr, iov_len, &data);
    if (got < 0) return got;
    return rawSendFrom(d, data[0..@intCast(got)], if (name_ptr != 0) RawDest{ .ptr = name_ptr, .len = name_len } else null, ctl[0..cl]);
}

/// recvmsg on a raw ICMP socket (raw_recvmsg / rawv6_recvmsg): the next datagram is scattered over the iovecs, msg_name gets the
/// sender (sockaddr_in, or sockaddr_in6 for an IPv6 socket), the control buffer gets what IP_PKTINFO / IP_RECVTTL / IP_RECVTOS
/// (ip_cmsg_recv) or IPV6_RECVPKTINFO / IPV6_RECVHOPLIMIT / IPV6_RECVTCLASS (ip6_datagram_recv_ctl) ask for, and msg_flags carries
/// MSG_TRUNC when the datagram did not fit, MSG_CTRUNC when a control message did not. The MSG_TRUNC flag returns the datagram's
/// whole length.
fn rawRecvmsg(d: *vfs_mod.FileDescriptor, msg_ptr: u64, msghdr: *const [56]u8, flags: u32) i64 {
    // raw_recvmsg: MSG_ERRQUEUE takes the oldest IP_RECVERR entry instead (ip_recv_error), never blocking.
    if (flags & errq.MSG_ERRQUEUE != 0) return recvErrqueueEntry(@import("raw_icmp.zig").takeQueuedError(d.raw_idx) orelse return -11, msg_ptr, msghdr);
    const name_ptr: u64 = bo.readU64At(msghdr, 0);
    const name_cap: u32 = bo.readU32Le(msghdr[8..12]);
    const iov_ptr: u64 = bo.readU64At(msghdr, 16);
    const iov_len: u64 = bo.readU64At(msghdr, 24);
    if (iov_len > 1024) return -22;
    if (iov_len != 0 and (iov_ptr == 0 or iov_ptr >= 0x0000_8000_0000_0000)) return -14;
    var data: [@import("raw_icmp.zig").RAW_QUEUE_LEN]u8 = undefined;
    var room: usize = 0;
    var i: usize = 0;
    while (i < iov_len and room < data.len) : (i += 1) {
        var iov_buf: [16]u8 = undefined;
        if (copy.copyFromUser(&iov_buf, @ptrFromInt(iov_ptr + @as(u64, @intCast(i)) * 16), 16) != 16) return -14;
        room += @intCast(@min(bo.readU64At(&iov_buf, 8), data.len - room));
    }
    var src: [16]u8 = @splat(0);
    var got_meta: RawMeta = .{};
    const got = rawRecvIntoMeta(d, data[0..room], flags | 0x20, &src, &got_meta);
    if (got < 0) return got;
    const full: usize = @intCast(got);
    const n = @min(full, room);
    var done: usize = 0;
    i = 0;
    while (i < iov_len and done < n) : (i += 1) {
        var iov_buf: [16]u8 = undefined;
        if (copy.copyFromUser(&iov_buf, @ptrFromInt(iov_ptr + @as(u64, @intCast(i)) * 16), 16) != 16) return -14;
        const base = bo.readU64At(&iov_buf, 0);
        const sz: usize = @intCast(@min(bo.readU64At(&iov_buf, 8), @as(u64, @intCast(n - done))));
        if (sz == 0) continue;
        if (base == 0 or base >= 0x0000_8000_0000_0000) return -14;
        if (copy.copyToUser(@ptrFromInt(base), data[done..][0..sz], sz) != sz) return -14;
        done += sz;
    }
    if (name_ptr != 0 and name_ptr < 0x0000_8000_0000_0000) {
        const rip = @import("raw_icmp_policy.zig");
        var name: [28]u8 = @splat(0);
        var name_len: u32 = 16;
        if (@import("raw_icmp.zig").isV6(d.raw_idx)) {
            name = rip.fromName6(src, sa.nameScope6(src));
            name_len = 28;
        } else @memcpy(name[0..16], &rip.fromName(src[0..4].*));
        const to_copy = @min(name_cap, name_len);
        if (to_copy != 0 and copy.copyToUser(@ptrFromInt(name_ptr), name[0..to_copy], to_copy) != to_copy) return -14;
        var al: [4]u8 = undefined;
        bo.writeU32Le(&al, name_len);
        _ = copy.copyToUser(@ptrFromInt(msg_ptr + 8), &al, 4);
    }
    const ctl_ptr: u64 = bo.readU64At(msghdr, 32);
    const ctl_cap: usize = if (ctl_ptr == 0) 0 else @intCast(@min(bo.readU64At(msghdr, 40), 1 << 20));
    const opts_ip = rawIpOpts(d.raw_idx);
    var ctl_buf: [192]u8 = undefined;
    const cm = if (@import("raw_icmp.zig").isV6(d.raw_idx))
        ip_cmsg_policy.build6(ip_cmsg_policy.Wanted.of6(opts_ip), got_meta.v6, ctl_cap, &ctl_buf)
    else
        ip_cmsg_policy.build(ip_cmsg_policy.Wanted.of(opts_ip), got_meta.v4, ctl_cap, &ctl_buf);
    if (cm.written != 0) {
        if (ctl_ptr >= 0x0000_8000_0000_0000) return -14;
        if (copy.copyToUser(@ptrFromInt(ctl_ptr), ctl_buf[0..cm.written], cm.written) != cm.written) return -14;
    }
    var cl8: [8]u8 = undefined;
    bo.writeU64Le(&cl8, cm.written);
    _ = copy.copyToUser(@ptrFromInt(msg_ptr + 40), &cl8, 8);
    const truncated = full > done;
    var fl: [4]u8 = undefined;
    bo.writeU32Le(&fl, (if (truncated) @as(u32, 0x20) else 0) | (if (cm.truncated) @as(u32, 0x08) else 0));
    _ = copy.copyToUser(@ptrFromInt(msg_ptr + 48), &fl, 4);
    return if ((flags & 0x20) != 0) @intCast(full) else @intCast(done);
}

/// sendmsg(fd, msg_ptr, flags) → bytes sent or -errno
pub fn sendmsg(fd: u32, msg_ptr: u64, flags: u32) i64 {
    if (msg_ptr == 0 or msg_ptr >= 0x0000_8000_0000_0000) return -22;

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (fd < vfs_mod.MAX_FDS and cur.fd_table.fds[fd].fd_type == .unix_socket) {
        var hdr: [56]u8 = undefined;
        if (copy.copyFromUser(&hdr, @ptrFromInt(msg_ptr), 56) != 56) return -14;
        return @import("../fs/namespace_policy.zig").sendResult(unixSendmsg(cur, fd, &hdr), flags);
    }
    if (fd < vfs_mod.MAX_FDS and flags & urg.MSG_OOB != 0 and (cur.fd_table.fds[fd].fd_type == .udp_socket or cur.fd_table.fds[fd].fd_type == .raw_socket)) return -95;
    if (fd < vfs_mod.MAX_FDS and cur.fd_table.fds[fd].fd_type == .udp_socket) {
        var hdr: [56]u8 = undefined;
        if (copy.copyFromUser(&hdr, @ptrFromInt(msg_ptr), 56) != 56) return -14;
        return udpSendmsg(fd, &hdr);
    }
    if (fd < vfs_mod.MAX_FDS and cur.fd_table.fds[fd].fd_type == .raw_socket) {
        var hdr: [56]u8 = undefined;
        if (copy.copyFromUser(&hdr, @ptrFromInt(msg_ptr), 56) != 56) return -14;
        return rawSendmsg(&cur.fd_table.fds[fd], &hdr);
    }
    if (fd >= vfs_mod.MAX_FDS or cur.fd_table.fds[fd].fd_type != .tcp_socket) return -88;

    var msghdr_buf: [56]u8 = undefined;
    const hdr_copied = copy.copyFromUser(&msghdr_buf, @ptrFromInt(msg_ptr), 56);
    if (hdr_copied < 32) return -22;

    const iov_ptr: u64 = bo.readU64At(&msghdr_buf, 16);
    const iov_len: u64 = bo.readU64At(&msghdr_buf, 24);

    if (iov_ptr == 0 or iov_ptr >= 0x0000_8000_0000_0000 or iov_len == 0 or iov_len > 1024) return -22;

    const tcb_idx = cur.fd_table.fds[fd].tcb_idx;
    var total: usize = 0;

    for (0..@as(usize, @intCast(iov_len))) |i| {
        var iov_buf: [16]u8 = undefined;
        const src: [*]const u8 = @ptrFromInt(iov_ptr + @as(u64, @intCast(i)) * 16);
        const iov_copied = copy.copyFromUser(&iov_buf, src, 16);
        if (iov_copied < 16) break;

        const iov_base: u64 = bo.readU64At(&iov_buf, 0);
        const iov_sz: u64 = bo.readU64At(&iov_buf, 8);

        if (iov_base == 0 or iov_base >= 0x0000_8000_0000_0000 or iov_sz == 0) continue;

        const to_send: u32 = @intCast(@min(iov_sz, @as(u64, 0xffff_ffff)));
        const nb = net_mod.tcp_recv_policy.nonblockRequested(vfs_mod.statusFlagsOf(&cur.fd_table.fds[fd]), flags);
        // MSG_OOB marks the last byte of the whole message: every segment but the final one goes out as plain data.
        const last = i + 1 == @as(usize, @intCast(iov_len));
        const result = if (flags & urg.MSG_OOB != 0 and last) net_mod.tcp.tcpSendOobBlocking(tcb_idx, iov_base, to_send, nb) else net_mod.tcp.tcpSendBlocking(tcb_idx, iov_base, true, to_send, nb);
        if (result <= 0) {
            if (total == 0) return @import("../fs/namespace_policy.zig").sendResult(result, flags);
            break;
        }
        total += @intCast(result);
        if (result < to_send) break;
    }
    return @intCast(total);
}

/// recvmsg(fd, msg_ptr, flags) → bytes received or -errno
pub fn recvmsg(fd: u32, msg_ptr: u64, flags: u32) i64 {
    if (msg_ptr == 0 or msg_ptr >= 0x0000_8000_0000_0000) return -14;

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (fd < vfs_mod.MAX_FDS and cur.fd_table.fds[fd].fd_type == .unix_socket) {
        var hdr: [56]u8 = undefined;
        if (copy.copyFromUser(&hdr, @ptrFromInt(msg_ptr), 56) != 56) return -14;
        return unixRecvmsg(cur, fd, msg_ptr, &hdr, flags);
    }
    if (fd < vfs_mod.MAX_FDS and cur.fd_table.fds[fd].fd_type == .udp_socket) {
        var hdr: [56]u8 = undefined;
        if (copy.copyFromUser(&hdr, @ptrFromInt(msg_ptr), 56) != 56) return -14;
        return udpRecvmsg(cur, fd, msg_ptr, &hdr, flags);
    }
    if (fd < vfs_mod.MAX_FDS and cur.fd_table.fds[fd].fd_type == .raw_socket) {
        var hdr: [56]u8 = undefined;
        if (copy.copyFromUser(&hdr, @ptrFromInt(msg_ptr), 56) != 56) return -14;
        return rawRecvmsg(&cur.fd_table.fds[fd], msg_ptr, &hdr, flags);
    }
    const rf_tcp = @import("recv_flags_policy.zig");
    // Supported TCP recvmsg flags: MSG_OOB, MSG_PEEK, MSG_DONTWAIT, MSG_WAITALL.
    // tcp_recvmsg → inet_recv_error: MSG_ERRQUEUE reads the error queue, which only a connect an ICMP error ended with IP_RECVERR
    // fills (an established connection takes ICMP errors as sk_err); never blocking, EAGAIN when empty.
    if (flags & errq.MSG_ERRQUEUE != 0 and fd < vfs_mod.MAX_FDS and cur.fd_table.fds[fd].fd_type == .tcp_socket) {
        var hdr: [56]u8 = undefined;
        if (copy.copyFromUser(&hdr, @ptrFromInt(msg_ptr), 56) != 56) return -14;
        return recvErrqueueEntry(net_mod.tcp.tcpTakeQueuedError(cur.fd_table.fds[fd].tcb_idx) orelse return -11, msg_ptr, &hdr);
    }
    if (flags & ~(urg.MSG_OOB | rf_tcp.MSG_PEEK | net_mod.tcp_recv_policy.MSG_DONTWAIT | rf_tcp.MSG_WAITALL) != 0) return -22;
    if (fd >= vfs_mod.MAX_FDS or cur.fd_table.fds[fd].fd_type != .tcp_socket) return -88;
    if (flags & urg.MSG_OOB != 0) return tcpRecvmsgOob(cur.fd_table.fds[fd].tcb_idx, msg_ptr, flags);

    var msghdr_buf: [56]u8 = undefined;
    const hdr_copied = copy.copyFromUser(&msghdr_buf, @ptrFromInt(msg_ptr), 56);
    if (hdr_copied != msghdr_buf.len) return -14;

    const iov_ptr: u64 = bo.readU64At(&msghdr_buf, 16);
    const iov_len: u64 = bo.readU64At(&msghdr_buf, 24);

    if (iov_ptr == 0 or iov_ptr >= 0x0000_8000_0000_0000) return -14;
    if (iov_len == 0 or iov_len > 1024) return -22;

    const tcb_idx = cur.fd_table.fds[fd].tcb_idx;
    const base_nonblock = net_mod.tcp_recv_policy.nonblockRequested(vfs_mod.statusFlagsOf(&cur.fd_table.fds[fd]), flags);
    const want_all = rf_tcp.waitAll(flags, true, base_nonblock);

    // Validate every iovec and total the room first (nothing is consumed yet).
    const IovSeg = struct { base: u64, len: u32 };
    var segs: [16]IovSeg = undefined;
    var nsegs: usize = 0;
    var room: u32 = 0;
    for (0..@as(usize, @intCast(iov_len))) |i| {
        var iov_buf: [16]u8 = undefined;
        const src: [*]const u8 = @ptrFromInt(iov_ptr + @as(u64, @intCast(i)) * 16);
        if (copy.copyFromUser(&iov_buf, src, 16) != iov_buf.len) return -14;
        const iov_base: u64 = bo.readU64At(&iov_buf, 0);
        const iov_sz: u64 = bo.readU64At(&iov_buf, 8);
        if (iov_base == 0 or iov_base >= 0x0000_8000_0000_0000) return -14;
        if (iov_sz == 0) return -22;
        if (nsegs == segs.len or room >= 4096) break;
        const take: u32 = @intCast(@min(iov_sz, @as(u64, 4096 - room)));
        if (!copy.validateUserBufferWritable(iov_base, take)) {
            if (nsegs == 0) return -14;
            break;
        }
        segs[nsegs] = .{ .base = iov_base, .len = take };
        nsegs += 1;
        room += take;
    }
    if (nsegs == 0) return -22;

    var tmp: [4096]u8 = undefined;
    var got: u32 = 0;
    if (rf_tcp.peek(flags)) {
        var r = net_mod.tcp.tcpPeek(tcb_idx, &tmp, room);
        while (r == -11 and !base_nonblock) {
            const w = net_mod.tcp.tcpWaitReadable(tcb_idx);
            if (w != 0) return w;
            r = net_mod.tcp.tcpPeek(tcb_idx, &tmp, room);
        }
        if (r <= 0) return r;
        got = @intCast(r);
    } else {
        // The first read may wait; later ones only with MSG_WAITALL (and then
        // until the iovecs are full, the stream ends, or a signal arrives).
        while (got < room) {
            const nonblock = if (want_all) false else (got != 0 or base_nonblock);
            const r = net_mod.tcp.tcpRecvBlocking(tcb_idx, @as([*]u8, @ptrCast(&tmp)) + got, room - got, nonblock);
            if (r > 0) {
                got += @intCast(r);
                if (!want_all) break;
            } else {
                // An empty-ring -EAGAIN must not collapse into a 0 (EOF) return.
                if (r < 0 and got == 0) return r;
                break;
            }
        }
    }
    if (got == 0) return 0;

    // Scatter across the iovecs.
    var off: u32 = 0;
    for (segs[0..nsegs]) |sg| {
        if (off >= got) break;
        const n = @min(sg.len, got - off);
        if (copy.copyToUser(@ptrFromInt(sg.base), tmp[off..][0..n], n) != n) return if (off == 0) -14 else @intCast(off);
        off += n;
    }
    return @intCast(off);
}

const urg = @import("tcp_urg_policy.zig");

/// recv(MSG_OOB) on TCP: the urgent byte into `buf` (a zero-length buffer still reports it, as Linux does with MSG_TRUNC set in
/// msg_flags); never blocks.
fn tcpRecvOobTo(tcb_idx: u32, buf: u64, len: u32, flags: u32) i64 {
    const rf = @import("recv_flags_policy.zig");
    if (len != 0 and (buf == 0 or buf >= 0x0000_8000_0000_0000)) return -14;
    const r = net_mod.tcp.tcpRecvOob(tcb_idx, rf.peek(flags));
    if (r < 0 or len == 0) return if (r < 0) r else 0;
    const b: [1]u8 = .{@intCast(r)};
    if (copy.copyToUser(@ptrFromInt(buf), &b, 1) != 1) return -14;
    return 1;
}

/// recvmsg(MSG_OOB) on TCP: the urgent byte into the first non-empty iovec, MSG_OOB in msg_flags.
fn tcpRecvmsgOob(tcb_idx: u32, msg_ptr: u64, flags: u32) i64 {
    var hdr: [56]u8 = undefined;
    if (copy.copyFromUser(&hdr, @ptrFromInt(msg_ptr), 56) != 56) return -14;
    const iov_ptr: u64 = bo.readU64At(&hdr, 16);
    const iov_len: u64 = bo.readU64At(&hdr, 24);
    if (iov_len > 1024) return -90; // EMSGSIZE (UIO_MAXIOV)
    var base: u64 = 0;
    var room: u32 = 0;
    for (0..@as(usize, @intCast(iov_len))) |i| {
        var iov: [16]u8 = undefined;
        if (copy.copyFromUser(&iov, @ptrFromInt(iov_ptr + @as(u64, @intCast(i)) * 16), 16) != 16) return -14;
        const sz = bo.readU64At(&iov, 8);
        if (sz == 0) continue;
        base = bo.readU64At(&iov, 0);
        room = 1;
        break;
    }
    const r = tcpRecvOobTo(tcb_idx, base, room, flags);
    if (r < 0) return r;
    var fl: [4]u8 = undefined;
    bo.writeU32Le(&fl, urg.MSG_OOB | (if (room == 0) @as(u32, 0x20) else 0)); // MSG_TRUNC when there was no room
    _ = copy.copyToUser(@ptrFromInt(msg_ptr + 48), &fl, 4);
    return r;
}

/// socketpair(domain, type, protocol, sv_ptr) → 0 or -errno
pub fn socketpair(domain: u32, sock_type: u32, protocol: u32, sv_ptr: u64) i64 {
    const policy_result = socketpair_policy.validate(domain, sock_type, protocol);
    if (policy_result != 0) return policy_result;
    if (!copy.validateUserBufferWritable(sv_ptr, 8)) return -14;

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    const pair_result = net_mod.unix_socket.unixSocketPair(sock_type & 0xff);
    if (pair_result < 0) return if (pair_result == -24) -24 else -12;
    const first_idx: u32 = @intCast(pair_result & 0xff);
    const second_idx: u32 = @intCast((@as(u32, @intCast(pair_result)) >> 8) & 0xff);
    const pair_cred: @import("sockopt_policy.zig").Cred = .{ .pid = @intCast(if (cur.is_thread and cur.parent_tid != 0) cur.parent_tid else cur.tid), .uid = cur.euid, .gid = cur.egid };
    net_mod.unix_socket.unixSetCred(first_idx, pair_cred);
    net_mod.unix_socket.unixSetCred(second_idx, pair_cred);
    const first_fd = cur.fd_table.allocFd() orelse {
        net_mod.unix_socket.unixClose(first_idx);
        net_mod.unix_socket.unixClose(second_idx);
        return -24;
    };
    cur.fd_table.fds[first_fd] = .{
        .fd_type = .unix_socket,
        .unix_sock_idx = first_idx,
        .writable = true,
        .fd_flags = if ((sock_type & socketpair_policy.SOCK_CLOEXEC) != 0) 1 else 0,
        .status_flags = sock_type & socketpair_policy.SOCK_NONBLOCK,
    };
    cur.fd_table.publishFd(first_fd);
    const second_fd = cur.fd_table.allocFd() orelse {
        _ = cur.fd_table.close(first_fd);
        net_mod.unix_socket.unixClose(second_idx);
        return -24;
    };
    cur.fd_table.fds[second_fd] = .{
        .fd_type = .unix_socket,
        .unix_sock_idx = second_idx,
        .writable = true,
        .fd_flags = if ((sock_type & socketpair_policy.SOCK_CLOEXEC) != 0) 1 else 0,
        .status_flags = sock_type & socketpair_policy.SOCK_NONBLOCK,
    };
    cur.fd_table.publishFd(second_fd);
    var fds: [8]u8 = undefined;
    bo.writeU32Le(fds[0..4], first_fd);
    bo.writeU32Le(fds[4..8], second_fd);
    if (copy.copyToUser(@ptrFromInt(sv_ptr), &fds, 8) != 8) {
        _ = cur.fd_table.close(first_fd);
        _ = cur.fd_table.close(second_fd);
        return -14;
    }
    return 0;
}

/// net_poll() → count of packets processed
pub fn netPoll() i64 {
    const nic = @import("nic.zig");
    const lo = @import("lo.zig");
    var count: u64 = 0;
    if (nic.isActive()) {
        var rx_tmp: [2048]u8 = undefined;
        var poll_limit: u32 = 0;
        while (poll_limit < 16) {
            const n = nic.receivePacket(&rx_tmp, 2048);
            if (n == 0) break;
            net_mod.handleRxPacket(&rx_tmp, n);
            count += 1;
            poll_limit += 1;
        }
    }
    // F2: deliver frames queued on the loopback device (runs even when no
    // hardware NIC is active — lo traffic must not depend on one).
    count += lo.drain();
    return @intCast(count);
}

/// Validate one mmsghdr of a batch: the header and its iovec array must be
/// readable; for receives the buffers must be writable, for sends readable.
fn batchEntryOk(entry_ptr: u64, receiving: bool) i64 {
    if (!copy.validateUserBuffer(entry_ptr, 56)) return -14;
    if (receiving and !copy.validateUserBufferWritable(entry_ptr + 56, 4)) return -14;
    if (!receiving and !copy.validateUserBuffer(entry_ptr + 56, 4)) return -14;
    var header: [56]u8 = undefined;
    if (copy.copyFromUser(&header, @ptrFromInt(entry_ptr), 56) < 32) return -14;
    const iov_ptr = bo.readU64At(&header, 16);
    const iov_len = bo.readU64At(&header, 24);
    if (iov_len == 0) return 0; // an empty message (no buffers) is legal
    if (iov_len > 1024 or iov_ptr == 0 or iov_ptr > 0x0000_8000_0000_0000 -| iov_len * 16) return -22;
    if (!copy.validateUserBuffer(iov_ptr, @intCast(iov_len * 16))) return -14;
    for (0..@as(usize, @intCast(iov_len))) |j| {
        var iov: [16]u8 = undefined;
        if (copy.copyFromUser(&iov, @ptrFromInt(iov_ptr + @as(u64, @intCast(j)) * 16), 16) != 16) return -14;
        const base = bo.readU64At(&iov, 0);
        const len = bo.readU64At(&iov, 8);
        if (len == 0) continue;
        if (base == 0 or base >= 0x0000_8000_0000_0000 or len > 0x0000_8000_0000_0000 - base) return if (receiving) -14 else -22;
        const n: usize = @intCast(@min(len, 0xFFFF_FFFF));
        if (receiving) {
            if (!copy.validateUserBufferWritable(base, n)) return -14;
        } else if (!copy.validateUserBuffer(base, n)) return -14;
    }
    return 0;
}

/// recvmmsg(sockfd, msgvec, vlen, flags, timeout) → count or -errno
pub fn recvmmsg(sockfd: u32, msgvec_ptr: u64, vlen_raw: u64, flags: u32, timeout: u64) i64 {
    const mp = message_batch_policy;
    const flag_rc = mp.validateRecvFlags(flags);
    if (flag_rc != 0) return flag_rc;
    const vlen = mp.clampVlen(vlen_raw);
    if (vlen == 0) return 0;
    if (msgvec_ptr == 0 or msgvec_ptr >= 0x0000_8000_0000_0000) return -14;

    // Optional struct timespec: the batch ends between messages once it passed.
    const tsc = @import("../arch/arch.zig").tsc;
    var deadline: ?u64 = null;
    if (timeout != 0) {
        var raw: [16]u8 = undefined;
        if (!copy.validateUserBuffer(timeout, 16) or copy.copyFromUser(&raw, @ptrFromInt(timeout), 16) != 16) return -14;
        switch (mp.timeoutDeadline(true, @bitCast(bo.readU64Le(raw[0..8])), @bitCast(bo.readU64Le(raw[8..16])), tsc.nanos())) {
            .none => {},
            .deadline => |d| deadline = d,
            .invalid => return -22,
        }
    }

    // Preflight every entry so a first-message failure cannot leave a partial
    // batch of user-visible writes behind.
    for (0..@as(usize, @intCast(vlen))) |i| {
        const rc = batchEntryOk(msgvec_ptr + @as(u64, @intCast(i)) * 64, true);
        if (rc != 0) return rc;
    }

    var count: u64 = 0;
    var err: i64 = 0;
    for (0..@as(usize, @intCast(vlen))) |i| {
        const entry_ptr = msgvec_ptr + @as(u64, @intCast(i)) * 64;
        const result = recvmsg(sockfd, entry_ptr, mp.messageFlags(flags, count));
        if (result < 0) {
            err = result;
            break;
        }

        var len_buf: [4]u8 = undefined;
        bo.writeU32Le(&len_buf, @intCast(result));
        if (copy.copyToUser(@ptrFromInt(entry_ptr + 56), &len_buf, 4) != 4) {
            err = -14;
            break;
        }
        count += 1;
        if (mp.expired(deadline, tsc.nanos())) break;
    }
    if (count == 0) return err;
    // __sys_recvmmsg: once something arrived, the timeout holds the time that is left, however the batch ended.
    if (deadline) |d| {
        if (!writeTimeoutLeft(timeout, d, tsc.nanos())) return -14;
    }
    return @intCast(count);
}

/// Store the rest of a recvmmsg timeout ending at `deadline` into the user timespec at `ptr`; false when it cannot be written.
fn writeTimeoutLeft(ptr: u64, deadline: u64, now: u64) bool {
    const left = message_batch_policy.remainingNs(deadline, now);
    var raw: [16]u8 = undefined;
    bo.writeU64Le(raw[0..8], left / 1_000_000_000);
    bo.writeU64Le(raw[8..16], left % 1_000_000_000);
    return copy.copyToUser(@ptrFromInt(ptr), &raw, 16) == 16;
}

/// sendmmsg(sockfd, msgvec, vlen, flags) → count or -errno
pub fn sendmmsg(sockfd: u32, msgvec_ptr: u64, vlen_raw: u64, flags: u32) i64 {
    const mp = message_batch_policy;
    const flag_rc = mp.validateSendFlags(flags);
    if (flag_rc != 0) return flag_rc;
    const vlen = mp.clampVlen(vlen_raw);
    if (vlen == 0) return 0;
    if (msgvec_ptr == 0 or msgvec_ptr >= 0x0000_8000_0000_0000) return -14;

    // Validate every header and its iovec descriptors before sending anything;
    // this preserves the no-mutation-on-first-failure contract.
    for (0..@as(usize, @intCast(vlen))) |i| {
        const rc = batchEntryOk(msgvec_ptr + @as(u64, @intCast(i)) * 64, false);
        if (rc != 0) return rc;
    }

    var count: u64 = 0;
    for (0..@as(usize, @intCast(vlen))) |i| {
        const entry_ptr = msgvec_ptr + @as(u64, @intCast(i)) * 64;
        const result = sendmsg(sockfd, entry_ptr, flags);
        if (result < 0) return mp.batchResult(count, result);
        var len_buf: [4]u8 = undefined;
        bo.writeU32Le(&len_buf, @intCast(result));
        if (copy.copyToUser(@ptrFromInt(entry_ptr + 56), &len_buf, 4) != 4) return mp.batchResult(count, -14);
        count += 1;
    }
    return @intCast(count);
}
