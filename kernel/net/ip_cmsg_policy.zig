//! IPv4 and IPv6 receive control messages (Linux ip_cmsg_recv_offset, ip_cmsg_recv_pktinfo / _ttl / _tos, put_cmsg). A message is
//! { u64 cmsg_len; i32 level; i32 type; data } padded to 8 bytes; IP_PKTINFO carries a struct in_pktinfo (i32 ifindex, in_addr
//! spec_dst, in_addr addr), IP_TTL an int and IP_TOS one byte, in that order. Host-testable.

const std = @import("std");
const ipo = @import("ip_opt_policy.zig");
const scm = @import("scm_policy.zig");

/// What a datagram brings with it: the interface it arrived on, the header destination (also the address a reply is sent from: this
/// stack answers from the address a datagram was sent to), TTL and TOS.
pub const RecvInfo = struct {
    ifindex: u8 = 0,
    dst: [4]u8 = .{ 0, 0, 0, 0 },
    /// in_pktinfo's ipi_spec_dst when it is not the destination: an ICMP echo reply never went through ipv4_pktinfo_prepare, so a
    /// ping socket reports 0.0.0.0 (null: the destination, as for a UDP or raw datagram).
    spec_dst: ?[4]u8 = null,
    ttl: u8 = 0,
    tos: u8 = 0,
    /// The datagram's destination port (IP_ORIGDSTADDR) and its arrival time on the real-time clock (SO_TIMESTAMP*), in ns.
    dst_port: u16 = 0,
    stamp_ns: u64 = 0,
    /// skb->mark and skb->priority: what the sender's SO_MARK / SO_PRIORITY (or its control messages) gave the datagram.
    mark: u32 = 0,
    priority: u32 = 0,
    /// The IPv4 options as ip_options_compile left them (IP_RECVOPTS), and what IP_RETOPTS reports (ip_options_echo + undo).
    optlen: u8 = 0,
    opts: [40]u8 = @splat(0),
    retlen: u8 = 0,
    ret_bad: bool = false,
    retopts: [40]u8 = @splat(0),
};

/// Receive timestamps a socket asked for (SO_TIMESTAMP: struct timeval, SO_TIMESTAMPNS: struct timespec).
pub const Stamp = enum { none, micro, nano };

pub const Wanted = struct {
    pktinfo: bool = false,
    recvttl: bool = false,
    recvtos: bool = false,
    origdst: bool = false,
    stamp: Stamp = .none,
    /// IP_RECVOPTS / IP_RETOPTS: the received IPv4 options, as they arrived (with this host's additions) and as a reply would
    /// carry them.
    recvopts: bool = false,
    retopts: bool = false,
    /// IPV6_FLOWINFO (rxflow): the received flowinfo, when it is not 0.
    flowinfo: bool = false,
    /// SO_RCVMARK / SO_RCVPRIORITY.
    rcvmark: bool = false,
    rcvprio: bool = false,

    pub fn of(o: ipo.IpOpts) Wanted {
        return .{ .pktinfo = o.pktinfo, .recvttl = o.recvttl, .recvtos = o.recvtos, .origdst = o.origdst, .recvopts = o.recvopts, .retopts = o.retopts };
    }

    /// The IPv6 flags in the same slots: IPV6_RECVPKTINFO, IPV6_RECVHOPLIMIT, IPV6_RECVTCLASS, IPV6_RECVORIGDSTADDR.
    pub fn of6(o: ipo.IpOpts) Wanted {
        return .{ .pktinfo = o.pktinfo6, .recvttl = o.recvhops6, .recvtos = o.recvtclass6, .origdst = o.origdst6, .flowinfo = o.rxflow6 };
    }

    /// `of` / `of6` plus the SOL_SOCKET timestamp flags (sockopt_policy.TS_FLAG / TSNS_FLAG in Stored.flags).
    pub fn withStamp(self: Wanted, sol_flags: u16) Wanted {
        var w = self;
        w.stamp = if (sol_flags & 128 == 0) .none else if (sol_flags & 256 != 0) .nano else .micro;
        w.rcvmark = sol_flags & 512 != 0;
        w.rcvprio = sol_flags & 1024 != 0;
        return w;
    }
};

const SOL_SOCKET: i32 = 1;
const SO_TIMESTAMP: i32 = 29;
const SO_TIMESTAMPNS: i32 = 35;

/// __sock_recv_timestamp: SCM_TIMESTAMP (struct timeval) or SCM_TIMESTAMPNS (struct timespec) first, at SOL_SOCKET.
/// sock_recv_mark then sock_recv_priority (after the timestamp in __sock_recv_cmsgs): SOL_SOCKET / SO_MARK and SO_PRIORITY as u32.
fn putMarkPrio(out: []u8, used: *usize, cap: usize, w: Wanted, mark: u32, priority: u32, truncated: *bool) void {
    var v: [4]u8 = undefined;
    if (w.rcvmark) {
        std.mem.writeInt(u32, &v, mark, .little);
        put(out, used, cap, SOL_SOCKET, 36, &v, truncated);
    }
    if (w.rcvprio) {
        std.mem.writeInt(u32, &v, priority, .little);
        put(out, used, cap, SOL_SOCKET, 12, &v, truncated);
    }
}

fn putStamp(out: []u8, used: *usize, cap: usize, stamp: Stamp, ns: u64, truncated: *bool) void {
    if (stamp == .none) return;
    var t: [16]u8 = undefined;
    std.mem.writeInt(i64, t[0..8], @intCast(ns / std.time.ns_per_s), .little);
    const frac = ns % std.time.ns_per_s;
    std.mem.writeInt(i64, t[8..16], @intCast(if (stamp == .nano) frac else frac / 1000), .little);
    put(out, used, cap, SOL_SOCKET, if (stamp == .nano) SO_TIMESTAMPNS else SO_TIMESTAMP, &t, truncated);
}

/// What an IPv6 datagram brings with it: the interface it arrived on, the header destination, hop limit and traffic class.
pub const RecvInfo6 = struct {
    ifindex: u8 = 0,
    dst: [16]u8 = @splat(0),
    hops: u8 = 0,
    tclass: u8 = 0,
    dst_port: u16 = 0,
    stamp_ns: u64 = 0,
    /// Traffic class and flow label of the IPv6 header (ip6_flowinfo), for IPV6_FLOWINFO.
    flowinfo: u32 = 0,
    mark: u32 = 0,
    priority: u32 = 0,
};

pub const Built = struct {
    /// Bytes of the control buffer used (the new msg_controllen).
    written: usize,
    /// MSG_CTRUNC.
    truncated: bool,
};

/// put_cmsg: with no room for a header the message is dropped and MSG_CTRUNC set; a message longer than what is left is cut to it
/// (MSG_CTRUNC) and uses the buffer up; otherwise it takes CMSG_SPACE.
fn put(out: []u8, used: *usize, cap: usize, level: i32, typ: i32, data: []const u8, truncated: *bool) void {
    const left = cap - used.*;
    if (left < scm.HDR) {
        truncated.* = true;
        return;
    }
    var len = scm.cmsgLen(data.len);
    if (left < len) {
        truncated.* = true;
        len = left;
    }
    const base = used.*;
    // cmsg_len is written as cut (put_cmsg stores cmlen after clamping it).
    std.mem.writeInt(u64, out[base..][0..8], len, .little);
    std.mem.writeInt(i32, out[base + 8 ..][0..4], level, .little);
    std.mem.writeInt(i32, out[base + 12 ..][0..4], typ, .little);
    @memcpy(out[base + scm.HDR ..][0 .. len - scm.HDR], data[0 .. len - scm.HDR]);
    const space = @min(scm.cmsgSpace(data.len), left);
    @memset(out[base + len .. base + space], 0);
    used.* += space;
}

/// Lay out the wanted messages for `info` in a control buffer of `cap` bytes (`out` holds at least min(cap, 144) bytes).
pub fn build(w: Wanted, info: RecvInfo, cap_in: usize, out: []u8) Built {
    const cap = @min(cap_in, out.len);
    var used: usize = 0;
    var truncated = false;
    putStamp(out, &used, cap, w.stamp, info.stamp_ns, &truncated);
    putMarkPrio(out, &used, cap, w, info.mark, info.priority, &truncated);
    if (w.pktinfo) {
        var pi: [12]u8 = undefined;
        std.mem.writeInt(i32, pi[0..4], info.ifindex, .little);
        @memcpy(pi[4..8], &(info.spec_dst orelse info.dst));
        @memcpy(pi[8..12], &info.dst);
        put(out, &used, cap, @intCast(ipo.SOL_IP), @intCast(ipo.IP_PKTINFO), &pi, &truncated);
    }
    if (w.recvttl) {
        var t: [4]u8 = undefined;
        std.mem.writeInt(i32, &t, info.ttl, .little);
        put(out, &used, cap, @intCast(ipo.SOL_IP), @intCast(ipo.IP_TTL), &t, &truncated);
    }
    if (w.recvtos) put(out, &used, cap, @intCast(ipo.SOL_IP), @intCast(ipo.IP_TOS), &.{info.tos}, &truncated);
    // ip_cmsg_recv_opts / ip_cmsg_recv_retopts (in that order, after IP_TOS): only a datagram that had options.
    if (w.recvopts and info.optlen != 0) put(out, &used, cap, @intCast(ipo.SOL_IP), IP_RECVOPTS, info.opts[0..info.optlen], &truncated);
    if (w.retopts and info.optlen != 0) {
        if (info.ret_bad) truncated = true else put(out, &used, cap, @intCast(ipo.SOL_IP), IP_RETOPTS, info.retopts[0..info.retlen], &truncated);
    }
    if (w.origdst) {
        // ip_cmsg_recv_dstaddr: a struct sockaddr_in of the header destination and the UDP destination port.
        var sa: [16]u8 = @splat(0);
        sa[0] = 2;
        std.mem.writeInt(u16, sa[2..4], info.dst_port, .big);
        @memcpy(sa[4..8], &info.dst);
        put(out, &used, cap, @intCast(ipo.SOL_IP), @intCast(ipo.IP_RECVORIGDSTADDR), &sa, &truncated);
    }
    return .{ .written = used, .truncated = truncated };
}

/// getsockopt(IP_PKTOPTIONS) of a TCP socket (do_ip_getsockopt): the control messages a stream socket stands for, in a buffer of
/// `cap` bytes cut like put_cmsg: IP_PKTINFO with `addr` (inet_rcv_saddr) as both addresses and `ifindex` (mc_index), IP_TTL with
/// `ttl` (mc_ttl) and IP_TOS with `tos` (rcv_tos) as an int, each when the socket asked for it.
pub fn buildPktOptions(w: Wanted, addr: [4]u8, ifindex: u8, ttl: u8, tos: u8, cap_in: usize, out: []u8) Built {
    const cap = @min(cap_in, out.len);
    var used: usize = 0;
    var truncated = false;
    if (w.pktinfo) {
        var pi: [12]u8 = undefined;
        std.mem.writeInt(i32, pi[0..4], ifindex, .little);
        @memcpy(pi[4..8], &addr);
        @memcpy(pi[8..12], &addr);
        put(out, &used, cap, @intCast(ipo.SOL_IP), @intCast(ipo.IP_PKTINFO), &pi, &truncated);
    }
    if (w.recvttl) {
        var t: [4]u8 = undefined;
        std.mem.writeInt(i32, &t, ttl, .little);
        put(out, &used, cap, @intCast(ipo.SOL_IP), @intCast(ipo.IP_TTL), &t, &truncated);
    }
    if (w.recvtos) {
        var t: [4]u8 = undefined;
        std.mem.writeInt(i32, &t, tos, .little);
        put(out, &used, cap, @intCast(ipo.SOL_IP), @intCast(ipo.IP_TOS), &t, &truncated);
    }
    return .{ .written = used, .truncated = truncated };
}

/// getsockopt(IPV6_2292PKTOPTIONS) with no queued packet options (do_ipv6_getsockopt): the six receive messages in Linux order.
/// A fresh stream has a zero sticky address, while the interface and hop limit are its multicast values; flowinfo is the last one
/// received (np->rcv_flowinfo). Unlike recvmsg, the flowinfo message is present even when its value is zero.
pub fn buildPktOptions6(o: ipo.IpOpts, flowinfo: u32, cap_in: usize, out: []u8) Built {
    const cap = @min(cap_in, out.len);
    var used: usize = 0;
    var truncated = false;
    const lv: i32 = @intCast(ipo.SOL_IPV6);
    var pi: [20]u8 = @splat(0);
    std.mem.writeInt(i32, pi[16..20], o.mc_if, .little);
    if (o.pktinfo6) put(out, &used, cap, lv, @intCast(ipo.IPV6_PKTINFO), &pi, &truncated);
    if (o.recvhops6) {
        var h: [4]u8 = undefined;
        std.mem.writeInt(i32, &h, o.mc_hops, .little);
        put(out, &used, cap, lv, @intCast(ipo.IPV6_HOPLIMIT), &h, &truncated);
    }
    if (o.recvtclass6) {
        var t: [4]u8 = undefined;
        std.mem.writeInt(i32, &t, @intCast((flowinfo >> 20) & 0xff), .little);
        put(out, &used, cap, lv, @intCast(ipo.IPV6_TCLASS), &t, &truncated);
    }
    if (o.flags6 & ipo.F6_2292PKTINFO != 0) put(out, &used, cap, lv, IPV6_2292PKTINFO, &pi, &truncated);
    if (o.flags6 & ipo.F6_2292HOPLIMIT != 0) {
        var h: [4]u8 = undefined;
        std.mem.writeInt(i32, &h, o.mc_hops, .little);
        put(out, &used, cap, lv, IPV6_2292HOPLIMIT, &h, &truncated);
    }
    if (o.rxflow6) {
        var f: [4]u8 = undefined;
        std.mem.writeInt(u32, &f, flowinfo, .big);
        put(out, &used, cap, lv, IPV6_FLOWINFO, &f, &truncated);
    }
    return .{ .written = used, .truncated = truncated };
}

/// ip6_datagram_recv_common_ctl then _specific_ctl: IPV6_PKTINFO (struct in6_pktinfo: in6_addr, then int ifindex), IPV6_HOPLIMIT
/// (int), IPV6_TCLASS (int), then IPV6_ORIGDSTADDR, after the timestamp (`out` holds at least min(cap, 160) bytes).
/// ipv6_recv_rxpmtu's message: one IPV6_PATHMTU control message holding struct ip6_mtuinfo (a sockaddr_in6 with the destination,
/// then the MTU: 32 bytes), cut like put_cmsg when `cap` is short.
pub fn buildPathMtu(dst: [16]u8, scope: u32, mtu: u32, cap_in: usize, out: []u8) Built {
    const cap = @min(cap_in, out.len);
    var data: [32]u8 = @splat(0);
    data[0] = 10;
    @memcpy(data[8..24], &dst);
    std.mem.writeInt(u32, data[24..28], scope, .little);
    std.mem.writeInt(u32, data[28..32], mtu, .little);
    var used: usize = 0;
    var truncated = false;
    put(out, &used, cap, @intCast(ipo.SOL_IPV6), @intCast(ipo.IPV6_PATHMTU), &data, &truncated);
    return .{ .written = used, .truncated = truncated };
}

pub fn build6(w: Wanted, info: RecvInfo6, cap_in: usize, out: []u8) Built {
    const cap = @min(cap_in, out.len);
    var used: usize = 0;
    var truncated = false;
    const lv: i32 = @intCast(ipo.SOL_IPV6);
    putStamp(out, &used, cap, w.stamp, info.stamp_ns, &truncated);
    putMarkPrio(out, &used, cap, w, info.mark, info.priority, &truncated);
    if (w.pktinfo) {
        var pi: [20]u8 = undefined;
        @memcpy(pi[0..16], &info.dst);
        std.mem.writeInt(i32, pi[16..20], info.ifindex, .little);
        put(out, &used, cap, lv, @intCast(ipo.IPV6_PKTINFO), &pi, &truncated);
    }
    if (w.recvttl) {
        var h: [4]u8 = undefined;
        std.mem.writeInt(i32, &h, info.hops, .little);
        put(out, &used, cap, lv, @intCast(ipo.IPV6_HOPLIMIT), &h, &truncated);
    }
    if (w.recvtos) {
        var t: [4]u8 = undefined;
        std.mem.writeInt(i32, &t, info.tclass, .little);
        put(out, &used, cap, lv, @intCast(ipo.IPV6_TCLASS), &t, &truncated);
    }
    if (w.flowinfo and info.flowinfo != 0) {
        var f: [4]u8 = undefined;
        std.mem.writeInt(u32, &f, info.flowinfo, .big);
        put(out, &used, cap, lv, IPV6_FLOWINFO, &f, &truncated);
    }
    if (w.origdst) {
        // A struct sockaddr_in6 (family, port, flowinfo 0, address, scope 0), after the other IPv6 messages.
        var sa: [28]u8 = @splat(0);
        sa[0] = 10;
        std.mem.writeInt(u16, sa[2..4], info.dst_port, .big);
        @memcpy(sa[8..24], &info.dst);
        put(out, &used, cap, lv, @intCast(ipo.IPV6_RECVORIGDSTADDR), &sa, &truncated);
    }
    return .{ .written = used, .truncated = truncated };
}

/// ip_recv_error's one control message: SOL_IP / IP_RECVERR with struct sock_extended_err and the offender (errqueue_policy); for
/// IPv6 (ipv6_recv_error) SOL_IPV6 / IPV6_RECVERR.
pub fn buildRecvErr(ext: []const u8, v6: bool, cap_in: usize, out: []u8) Built {
    const cap = @min(cap_in, out.len);
    var used: usize = 0;
    var truncated = false;
    if (v6) {
        put(out, &used, cap, @intCast(ipo.SOL_IPV6), @intCast(ipo.IPV6_RECVERR), ext, &truncated);
    } else put(out, &used, cap, @intCast(ipo.SOL_IP), @intCast(ipo.IP_RECVERR), ext, &truncated);
    return .{ .written = used, .truncated = truncated };
}

/// Who may use the privileged SOL_SOCKET send messages (SO_MARK, SO_PRIORITY above TC_PRIO_INTERACTIVE).
pub const SendCaps = struct {
    net_admin: bool = false,
    net_raw: bool = false,
};

/// What the control messages of one IPv4 UDP sendmsg change for that datagram (Linux struct ipcm_cookie): IP_TTL and IP_TOS
/// replace the socket's values; IP_PKTINFO names the source address (ipi_spec_dst, 0 to let the stack choose, replacing the bound
/// one) and the outgoing interface (ipi_ifindex, 0 for none).
pub const Send4 = struct {
    ttl: ?u8 = null,
    tos: ?u8 = null,
    pktinfo: bool = false,
    oif: u32 = 0,
    spec_dst: [4]u8 = .{ 0, 0, 0, 0 },
    /// IP_RETOPTS was given (ip_options_get: the datagram then has an options block, even an empty one, which an IP_HDRINCL raw
    /// socket refuses with EINVAL).
    retopts: bool = false,
    /// The options it gave (ip_options_compile without an skb), for this datagram only.
    opts: ?@import("ip_options_policy.zig").SendOpts = null,
    /// SOL_SOCKET SO_MARK / SO_PRIORITY messages (sockc.mark, sockc.priority): replace the socket's for this datagram.
    mark: ?u32 = null,
    priority: ?u32 = null,
};

/// The control messages parsed, or the errno that fails the send.
pub const Send4Result = union(enum) { ok: Send4, err: i64 };

pub const SOL_UDP: i32 = 17;
pub const UDP_SEGMENT: i32 = 103;
const IP_RETOPTS: i32 = 7;
const IP_RECVOPTS: i32 = 6;
const IP_PROTOCOL: i32 = 52;
const SO_PRIORITY: i32 = 12;
const SO_MARK: i32 = 36;
const SO_TIMESTAMPING_OLD: i32 = 37;
const SO_TIMESTAMPING_NEW: i32 = 65;
const SCM_TXTIME: i32 = 61;
const SCM_DEVMEM_DMABUF: i32 = 79;
const SCM_TS_OPT_ID: i32 = 81;
/// SOF_TIMESTAMPING_TX_HARDWARE | _TX_SOFTWARE | _TX_SCHED | _TX_ACK | _TX_COMPLETION.
const TX_RECORD_MASK: u32 = 1 | 2 | (1 << 8) | (1 << 9) | (1 << 18);
/// TC_PRIO_INTERACTIVE: the highest SO_PRIORITY anyone may ask for.
const TC_PRIO_INTERACTIVE: u32 = 6;

const Cmsg = struct { len: usize, level: i32, typ: i32, data: []const u8 };

/// for_each_cmsghdr with CMSG_OK: the message at `off`, or null at the end (fewer than a header's bytes left); error.Invalid when
/// cmsg_len is shorter than the header or runs past the buffer.
fn cmsgAt(control: []const u8, off: usize) error{Invalid}!?Cmsg {
    if (off + scm.HDR > control.len) return null;
    const len = std.mem.readInt(u64, control[off..][0..8], .little);
    if (len < scm.HDR or len > control.len - off) return error.Invalid;
    const l: usize = @intCast(len);
    return .{
        .len = l,
        .level = std.mem.readInt(i32, control[off + 8 ..][0..4], .little),
        .typ = std.mem.readInt(i32, control[off + 12 ..][0..4], .little),
        .data = control[off + scm.HDR .. off + l],
    };
}

fn nextOff(off: usize, len: usize) usize {
    return off + ((len + 7) & ~@as(usize, 7));
}

fn readU32(d: []const u8) u32 {
    return std.mem.readInt(u32, d[0..4], .little);
}

/// __sock_cmsg_send for a UDP socket with no SO_TXTIME and no SOF_TIMESTAMPING_OPT_ID: 0 or -errno.
fn sockCmsg(m: Cmsg, caps: SendCaps) i64 {
    const privileged = caps.net_admin or caps.net_raw;
    switch (m.typ) {
        SO_MARK => {
            if (!privileged) return -1;
            if (m.data.len != 4) return -22;
        },
        SO_TIMESTAMPING_OLD, SO_TIMESTAMPING_NEW => {
            if (m.data.len != 4) return -22;
            if (readU32(m.data) & ~TX_RECORD_MASK != 0) return -22;
        },
        SCM_TXTIME, SCM_TS_OPT_ID => return -22,
        scm.SCM_RIGHTS, scm.SCM_CREDENTIALS => {},
        SO_PRIORITY => {
            if (m.data.len != 4) return -22;
            if (readU32(m.data) > TC_PRIO_INTERACTIVE and !privileged) return -1;
        },
        SCM_DEVMEM_DMABUF => if (m.data.len != 4) return -22,
        else => return -22,
    }
    return 0;
}

/// The control messages of an IPv4 UDP sendmsg (Linux udp_cmsg_send, then ip_cmsg_send with allow_ipv6 false): every SOL_UDP message
/// is checked first (only a 2-byte UDP_SEGMENT is valid), then the rest in order. Other levels are skipped; at SOL_IP an unknown type
/// is EINVAL, as is any malformed message. IP options (IP_RETOPTS) are not supported beyond an empty list.
pub fn parseSend4(control: []const u8, caps: SendCaps) Send4Result {
    var off: usize = 0;
    var need_ip = false;
    while (cmsgAt(control, off) catch return .{ .err = -22 }) |m| : (off = nextOff(off, m.len)) {
        if (m.level != SOL_UDP) {
            need_ip = true;
            continue;
        }
        if (m.typ != UDP_SEGMENT or m.data.len != 2) return .{ .err = -22 };
    }
    if (!need_ip) return .{ .ok = .{} };
    return ipCmsgSend4(control, caps);
}

/// The control messages of an IPv4 ping or raw socket's sendmsg (ping_v4_sendmsg and raw_sendmsg call ip_cmsg_send directly, with
/// no udp_cmsg_send pass): the rules of parseSend4 at SOL_IP and SOL_SOCKET; SOL_UDP messages are skipped like any other level.
pub fn parseSendPing4(control: []const u8, caps: SendCaps) Send4Result {
    return ipCmsgSend4(control, caps);
}

/// ip_cmsg_send with allow_ipv6 false: every message in order; SOL_SOCKET through __sock_cmsg_send, SOL_IP by type, the rest skipped.
fn ipCmsgSend4(control: []const u8, caps: SendCaps) Send4Result {
    var out: Send4 = .{};
    var off: usize = 0;
    while (cmsgAt(control, off) catch return .{ .err = -22 }) |m| : (off = nextOff(off, m.len)) {
        if (m.level == scm.SOL_SOCKET) {
            const rc = sockCmsg(m, caps);
            if (rc != 0) return .{ .err = rc };
            if (m.typ == SO_MARK) out.mark = readU32(m.data);
            if (m.typ == SO_PRIORITY) out.priority = readU32(m.data);
            continue;
        }
        if (m.level != @as(i32, @intCast(ipo.SOL_IP))) continue;
        switch (m.typ) {
            IP_RETOPTS => {
                // ip_options_get: up to 40 bytes, checked as a sender's options (unknown ones need CAP_NET_RAW).
                out.opts = @import("ip_options_policy.zig").compileForSend(m.data, caps.net_raw) orelse return .{ .err = -22 };
                out.retopts = true;
            },
            @as(i32, @intCast(ipo.IP_PKTINFO)) => {
                if (m.data.len != 12) return .{ .err = -22 };
                out.pktinfo = true;
                const ifx = readU32(m.data[0..4]);
                if (ifx != 0) out.oif = ifx;
                out.spec_dst = m.data[4..8].*;
            },
            @as(i32, @intCast(ipo.IP_TTL)) => {
                if (m.data.len != 4) return .{ .err = -22 };
                const v: i32 = @bitCast(readU32(m.data));
                if (v < 1 or v > 255) return .{ .err = -22 };
                out.ttl = @intCast(v);
            },
            @as(i32, @intCast(ipo.IP_TOS)) => {
                const v: i32 = if (m.data.len == 4) @bitCast(readU32(m.data)) else if (m.data.len == 1) m.data[0] else return .{ .err = -22 };
                if (v < 0 or v > 255) return .{ .err = -22 };
                out.tos = @intCast(v);
            },
            IP_PROTOCOL => {
                if (m.data.len != 4) return .{ .err = -22 };
                const v: i32 = @bitCast(readU32(m.data));
                if (v < 1 or v > 255) return .{ .err = -22 };
            },
            else => return .{ .err = -22 },
        }
    }
    return .{ .ok = out };
}

/// IP_PKTINFO's ipi_spec_dst as the source address (ip_route_output_key_hash_rcu): 0 lets the stack choose; a group, the limited
/// broadcast or a 0.x.y.z address is EINVAL; otherwise it must be an address of this host (127/8, or `our` while the NIC is up),
/// else ENETUNREACH.
pub fn sourceErrno4(spec: [4]u8, our: [4]u8, nic_active: bool) i64 {
    if (@as(u32, @bitCast(spec)) == 0) return 0;
    if ((spec[0] >= 224 and spec[0] <= 239) or @as(u32, @bitCast(spec)) == 0xffff_ffff or spec[0] == 0) return -22;
    if (spec[0] == 127) return 0;
    if (nic_active and @as(u32, @bitCast(spec)) == @as(u32, @bitCast(our))) return 0;
    return -101;
}

/// IP_PKTINFO's ipi_ifindex: 0 (none), lo (1) or the NIC (2) while it is up; any other index is ENODEV.
pub fn oifErrno4(oif: u32, nic_active: bool) i64 {
    if (oif == 0 or oif == 1 or (oif == 2 and nic_active)) return 0;
    return -19;
}

fn noNicAddress(_: [16]u8) bool {
    return false;
}

/// What the IPv6 send path knows before the control messages are read: the interface the destination's scope or the socket's
/// binding already chose (0 for none), whether the NIC (interface 2) is up, and which addresses are the NIC's.
pub const Ctx6 = struct {
    pre_oif: u32 = 0,
    nic_active: bool = false,
    isOwnNic: *const fn ([16]u8) bool = noNicAddress,
};

/// What the control messages of one IPv6 UDP sendmsg change for that datagram (Linux struct ipcm6_cookie and the flowi6 fields
/// ip6_datagram_send_ctl fills): IPV6_HOPLIMIT and IPV6_TCLASS replace the socket's values (a hop limit of -1 keeps it, null here);
/// IPV6_PKTINFO names the source address (:: lets the stack choose) and the outgoing interface (`oif`, 0 for none).
pub const Send6 = struct {
    /// IPV6_DONTFRAG of this datagram (null: the socket's).
    dontfrag: ?bool = null,
    /// The flow label of an IPV6_FLOWINFO control message (its network-order value, host order here; null: none).
    flowlabel: ?u32 = null,
    hops: ?u8 = null,
    tclass: ?u8 = null,
    pktinfo: bool = false,
    oif: u32 = 0,
    src: [16]u8 = @splat(0),
    mark: ?u32 = null,
    priority: ?u32 = null,
};

/// The IPv6 control messages parsed, or the errno that fails the send.
pub const Send6Result = union(enum) { ok: Send6, err: i64 };

const IPV6_2292PKTINFO: i32 = 2;
const IPV6_2292HOPOPTS: i32 = 3;
const IPV6_2292DSTOPTS: i32 = 4;
const IPV6_2292RTHDR: i32 = 5;
const IPV6_2292HOPLIMIT: i32 = 8;
const IPV6_FLOWINFO: i32 = 11;
const IPV6_HOPOPTS: i32 = 54;
const IPV6_RTHDRDSTOPTS: i32 = 55;
const IPV6_RTHDR: i32 = 57;
const IPV6_DSTOPTS: i32 = 59;
const IPV6_DONTFRAG: i32 = 62;

fn isLinkLocal6(a: [16]u8) bool {
    return a[0] == 0xfe and (a[1] & 0xc0) == 0x80;
}

fn isLoopback6(a: [16]u8) bool {
    return std.mem.eql(u8, a[0..15], &@as([15]u8, @splat(0))) and a[15] == 1;
}

fn isAny6(a: [16]u8) bool {
    return std.mem.allEqual(u8, &a, 0);
}

/// An int that must fill the message exactly and lie in -1..255.
fn int6(m: Cmsg) ?i32 {
    if (m.data.len != 4) return null;
    const v: i32 = @bitCast(readU32(m.data));
    if (v < -1 or v > 255) return null;
    return v;
}

/// The control messages of an IPv6 UDP sendmsg (Linux udp_cmsg_send, then ip6_datagram_send_ctl): SOL_UDP first as for IPv4, then
/// every message in order. SOL_SOCKET goes through __sock_cmsg_send, other levels are skipped, an unknown SOL_IPV6 type is EINVAL.
/// Extension headers (hop-by-hop, destination options, routing) need CAP_NET_RAW and are then refused with EOPNOTSUPP: this stack
/// does not send them.
pub fn parseSend6(control: []const u8, caps: SendCaps, ctx: Ctx6) Send6Result {
    var off: usize = 0;
    var need_ip = false;
    while (cmsgAt(control, off) catch return .{ .err = -22 }) |m| : (off = nextOff(off, m.len)) {
        if (m.level != SOL_UDP) {
            need_ip = true;
            continue;
        }
        if (m.typ != UDP_SEGMENT or m.data.len != 2) return .{ .err = -22 };
    }
    if (!need_ip) return .{ .ok = .{} };
    return datagramSendCtl6(control, caps, ctx);
}

/// The control messages of an IPv6 raw socket's sendmsg (rawv6_sendmsg calls ip6_datagram_send_ctl directly, with no
/// udp_cmsg_send pass): the rules of parseSend6 at SOL_IPV6 and SOL_SOCKET; SOL_UDP messages are skipped like any other level.
pub fn parseSendRaw6(control: []const u8, caps: SendCaps, ctx: Ctx6) Send6Result {
    return datagramSendCtl6(control, caps, ctx);
}

/// The control messages of an IPv6 ping socket's sendmsg: ping_v6_sendmsg also calls ip6_datagram_send_ctl directly, so the rules
/// are those of a raw socket. The IPV6_PKTINFO source is checked but not used (the request goes from the socket's own address).
pub fn parseSendPing6(control: []const u8, caps: SendCaps, ctx: Ctx6) Send6Result {
    return datagramSendCtl6(control, caps, ctx);
}

/// ip6_datagram_send_ctl: every message in order; SOL_SOCKET through __sock_cmsg_send, SOL_IPV6 by type, the rest skipped.
fn datagramSendCtl6(control: []const u8, caps: SendCaps, ctx: Ctx6) Send6Result {
    var out: Send6 = .{ .oif = ctx.pre_oif };
    var off: usize = 0;
    while (cmsgAt(control, off) catch return .{ .err = -22 }) |m| : (off = nextOff(off, m.len)) {
        if (m.level == scm.SOL_SOCKET) {
            const rc = sockCmsg(m, caps);
            if (rc != 0) return .{ .err = rc };
            if (m.typ == SO_MARK) out.mark = readU32(m.data);
            if (m.typ == SO_PRIORITY) out.priority = readU32(m.data);
            continue;
        }
        if (m.level != @as(i32, @intCast(ipo.SOL_IPV6))) continue;
        switch (m.typ) {
            IPV6_2292PKTINFO, @as(i32, @intCast(ipo.IPV6_PKTINFO)) => {
                if (m.data.len < 20) return .{ .err = -22 };
                const addr: [16]u8 = m.data[0..16].*;
                const ifx = readU32(m.data[16..20]);
                if (ifx != 0) {
                    if (out.oif != 0 and ifx != out.oif) return .{ .err = -22 };
                    out.oif = ifx;
                }
                if (out.oif != 0) {
                    if (!(out.oif == 1 or (out.oif == 2 and ctx.nic_active))) return .{ .err = -19 };
                } else if (isLinkLocal6(addr)) return .{ .err = -22 };
                out.pktinfo = true;
                if (!isAny6(addr)) {
                    // Loopback and link-local sources must belong to the interface itself (ipv6_chk_addr strict), others to any.
                    const strict = isLoopback6(addr) or isLinkLocal6(addr);
                    const on_lo = isLoopback6(addr);
                    const on_nic = ctx.nic_active and !on_lo and ctx.isOwnNic(addr);
                    const ok = if (on_lo) (!strict or out.oif == 0 or out.oif == 1) else if (on_nic) (!strict or out.oif == 0 or out.oif == 2) else false;
                    if (!ok) return .{ .err = -22 };
                    out.src = addr;
                }
            },
            IPV6_FLOWINFO => {
                if (m.data.len < 4) return .{ .err = -22 };
                // The value is a __be32 flowinfo; the label is its low 20 bits (ip6_datagram_send_ctl, ip6_make_flowlabel).
                out.flowlabel = (@as(u32, m.data[0]) << 24 | @as(u32, m.data[1]) << 16 | @as(u32, m.data[2]) << 8 | m.data[3]) & 0xFFFFF;
            },
            IPV6_2292HOPLIMIT, @as(i32, @intCast(ipo.IPV6_HOPLIMIT)) => {
                const v = int6(m) orelse return .{ .err = -22 };
                out.hops = if (v < 0) null else @intCast(v);
            },
            @as(i32, @intCast(ipo.IPV6_TCLASS)) => {
                const v = int6(m) orelse return .{ .err = -22 };
                out.tclass = @truncate(@as(u32, @bitCast(v)));
            },
            IPV6_DONTFRAG => {
                if (m.data.len != 4) return .{ .err = -22 };
                const v: i32 = @bitCast(readU32(m.data));
                if (v < 0 or v > 1) return .{ .err = -22 };
                out.dontfrag = v == 1;
            },
            IPV6_2292HOPOPTS, IPV6_HOPOPTS, IPV6_2292DSTOPTS, IPV6_DSTOPTS, IPV6_RTHDRDSTOPTS => {
                if (m.data.len < 2) return .{ .err = -22 };
                const len = (@as(usize, m.data[1]) + 1) * 8;
                if (m.data.len < len) return .{ .err = -22 };
                if (!caps.net_raw) return .{ .err = -1 };
                return .{ .err = -95 };
            },
            IPV6_2292RTHDR, IPV6_RTHDR => {
                if (m.data.len < 4) return .{ .err = -22 };
                // Only a type 2 (Mobile IPv6) routing header with one segment can be valid (no capability is checked); this stack
                // sends none.
                if (m.data[2] != 2 or m.data[1] != 2 or m.data[3] != 1) return .{ .err = -22 };
                if (m.data.len < 24) return .{ .err = -22 };
                return .{ .err = -95 };
            },
            else => return .{ .err = -22 },
        }
    }
    if (!out.pktinfo) out.oif = 0;
    return .{ .ok = out };
}
