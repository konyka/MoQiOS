//! IP-level socket options (SOL_IP / SOL_IPV6): TTL, TOS, hop limit, traffic
//! class and IPV6_V6ONLY as pure validation, encoding and header-patch rules.

const std = @import("std");

pub const SOL_IP: u64 = 0;
pub const SOL_IPV6: u64 = 41;

pub const IP_TOS: u64 = 1;
pub const IP_TTL: u64 = 2;
/// The caller writes the IPv4 header of a raw socket's sends (Linux raw_send_hdrinc).
pub const IP_HDRINCL: u64 = 3;
/// Path MTU discovery mode (Linux inet->pmtudisc): what sets DF and whether the stack may fragment.
pub const IP_PKTINFO: u64 = 8;
pub const IP_MTU_DISCOVER: u64 = 10;
/// Receive flags: recvmsg then carries an IP_TTL / IP_TOS control message (Linux inet IP_CMSG_TTL / IP_CMSG_TOS).
pub const IP_RECVTTL: u64 = 12;
pub const IP_RECVTOS: u64 = 13;
/// ICMP errors about what the socket sent are queued for recvmsg(MSG_ERRQUEUE) (Linux inet RECVERR, errqueue_policy.zig).
pub const IP_RECVERR: u64 = 11;
/// recvmsg then brings IP_ORIGDSTADDR, the datagram's destination as a struct sockaddr_in (Linux IP_CMSG_ORIGDSTADDR).
pub const IP_RECVORIGDSTADDR: u64 = 20;
/// The same for IPv6: IPV6_ORIGDSTADDR with a struct sockaddr_in6.
pub const IPV6_RECVORIGDSTADDR: u64 = 74;
/// ICMPv6 errors about what the socket sent are queued for recvmsg(MSG_ERRQUEUE) (Linux np->recverr).
pub const IPV6_RECVERR: u64 = 25;
pub const PMTUDISC_DONT: u8 = 0;
pub const PMTUDISC_WANT: u8 = 1;
pub const PMTUDISC_DO: u8 = 2;
pub const PMTUDISC_PROBE: u8 = 3;
pub const PMTUDISC_INTERFACE: u8 = 4;
pub const PMTUDISC_OMIT: u8 = 5;
pub const IP_MULTICAST_IF: u64 = 32;
pub const IP_MULTICAST_TTL: u64 = 33;
pub const IP_MULTICAST_LOOP: u64 = 34;
pub const IP_ADD_MEMBERSHIP: u64 = 35;
pub const IP_DROP_MEMBERSHIP: u64 = 36;
pub const IP_MULTICAST_ALL: u64 = 49;
pub const IPV6_UNICAST_HOPS: u64 = 16;
/// IPv6 path MTU discovery mode (Linux np->pmtudisc), the same values as IP_MTU_DISCOVER; IPV6_PMTUDISC_WANT unless set.
pub const IPV6_MTU_DISCOVER: u64 = 23;
/// IPV6_DONTFRAG: datagrams over the path MTU are refused (EMSGSIZE) instead of fragmented.
pub const IPV6_DONTFRAG: u64 = 62;
/// IPV6_RECVPATHMTU: a send IPV6_DONTFRAG refused leaves an IPV6_PATHMTU message for the next recvmsg; IPV6_PATHMTU (getsockopt on a
/// connected socket) reads the path MTU.
pub const IPV6_RECVPATHMTU: u64 = 60;
pub const IPV6_PATHMTU: u64 = 61;
/// IPV6_FLOWINFO_SEND: a send's sin6_flowinfo gives the packet's flow label (np->sndflow).
pub const IPV6_FLOWINFO_SEND: u64 = 33;
pub const IPV6_FLOWINFO: u64 = 11;
pub const IPV6_MULTICAST_IF: u64 = 17;
pub const IPV6_MULTICAST_HOPS: u64 = 18;
pub const IPV6_MULTICAST_LOOP: u64 = 19;
pub const IPV6_ADD_MEMBERSHIP: u64 = 20;
pub const IPV6_DROP_MEMBERSHIP: u64 = 21;
pub const IPV6_V6ONLY: u64 = 26;
pub const IPV6_MULTICAST_ALL: u64 = 29;
/// Receive flags: recvmsg then carries an IPV6_PKTINFO / IPV6_HOPLIMIT / IPV6_TCLASS control message (Linux rxopt.bits.rxinfo,
/// rxhlim, rxtclass; ip6_datagram_recv_common_ctl / _specific_ctl).
pub const IPV6_RECVPKTINFO: u64 = 49;
pub const IPV6_PKTINFO: u64 = 50;
pub const IPV6_RECVHOPLIMIT: u64 = 51;
pub const IPV6_HOPLIMIT: u64 = 52;
pub const IPV6_RECVTCLASS: u64 = 66;
pub const IPV6_TCLASS: u64 = 67;

pub const DEFAULT_TTL: u8 = 64;
/// Hop limit of a multicast datagram when IPV6_MULTICAST_HOPS is unset or -1 (Linux IPV6_DEFAULT_MCASTHOPS).
pub const DEFAULT_MCAST_HOPS: u8 = 1;
/// The two low bits of TOS / traffic class belong to ECN, which TCP manages itself.
pub const ECN_MASK: u8 = 0x03;

/// Per-socket values; 0 means "not set, use the default".
pub const IpOpts = struct {
    ttl: u8 = 0,
    tos: u8 = 0,
    hops: u8 = 0,
    tclass: u8 = 0,
    /// IPV6_MULTICAST_HOPS / _LOOP / _IF / _ALL (Linux mcast_hops, MC6_LOOP, mcast_oif, MC6_ALL); these hold the value itself.
    mc_hops: u8 = DEFAULT_MCAST_HOPS,
    mc_loop: bool = true,
    mc_if: u8 = 0,
    mc_all: bool = true,
    /// IP_MULTICAST_TTL / _LOOP / _ALL and IP_MULTICAST_IF (Linux mc_ttl, MC_LOOP, MC_ALL, mc_addr and mc_index).
    mc4_ttl: u8 = 1,
    mc4_loop: bool = true,
    mc4_all: bool = true,
    mc4_addr: [4]u8 = .{ 0, 0, 0, 0 },
    mc4_index: u8 = 0,
    /// IP_HDRINCL: only a raw socket may set it; any other socket reads it as 0.
    hdrincl: bool = false,
    /// IP_MTU_DISCOVER, IP_PMTUDISC_WANT unless set (inet_create with ip_no_pmtu_disc 0).
    pmtudisc: u8 = PMTUDISC_WANT,
    /// IP_PKTINFO, IP_RECVTTL, IP_RECVTOS: which control messages a received IPv4 datagram brings (ip_cmsg_recv_offset).
    pktinfo: bool = false,
    recvttl: bool = false,
    recvtos: bool = false,
    origdst: bool = false,
    recverr: bool = false,
    /// IPV6_RECVPKTINFO, IPV6_RECVHOPLIMIT, IPV6_RECVTCLASS: the same for a received IPv6 datagram.
    pktinfo6: bool = false,
    recvhops6: bool = false,
    recvtclass6: bool = false,
    origdst6: bool = false,
    recverr6: bool = false,
    pmtudisc6: u8 = PMTUDISC_WANT,
    dontfrag6: bool = false,
    rxpmtu6: bool = false,
    sndflow6: bool = false,
    /// IPV6_FLOWINFO (rxflow): received datagrams bring their flowinfo as a control message.
    rxflow6: bool = false,
};

pub const Family = enum { v4, v6 };

pub const SockKind = enum { inet4, inet6, unix };

/// getsockopt (`get`) or setsockopt at a level the socket does not handle. An IPv4 TCP, UDP or raw socket passes it on to
/// ip_getsockopt, which answers EOPNOTSUPP for a level other than SOL_IP; ip_setsockopt answers ENOPROTOOPT. An IPv6 socket's
/// ipv6_getsockopt / ipv6_setsockopt answer ENOPROTOOPT. AF_UNIX has no getsockopt / setsockopt of its own beyond SOL_SOCKET, so
/// do_sock_getsockopt / do_sock_setsockopt answer EOPNOTSUPP both ways.
pub fn unknownLevelErrno(kind: SockKind, get: bool) i64 {
    return switch (kind) {
        .inet4 => if (get) -95 else -92,
        .inet6 => -92,
        .unix => -95,
    };
}

/// Which level a socket of this family answers.
pub fn levelApplies(level: u64, family: Family) bool {
    return switch (family) {
        .v4 => level == SOL_IP,
        .v6 => level == SOL_IPV6,
    };
}

/// An option value as the kernel reads it: an int, or a single byte for the
/// byte-sized options when the caller passes only one byte.
pub fn readInt(val: []const u8) ?i32 {
    if (val.len >= 4) return std.mem.readInt(i32, val[0..4], .little);
    if (val.len == 1) return val[0];
    return null;
}

pub const SetResult = union(enum) { ok: IpOpts, err: i64 };

/// Apply setsockopt(level, optname, val) to `cur`.
pub fn applySet(cur: IpOpts, level: u64, optname: u64, val: []const u8) SetResult {
    var o = cur;
    // do_ipv6_setsockopt reads an int only when optlen >= sizeof(int) (val is 0 otherwise); IPV6_DONTFRAG takes any length.
    if (level == SOL_IPV6 and optname == IPV6_DONTFRAG) {
        o.dontfrag6 = val.len >= 4 and std.mem.readInt(i32, val[0..4], .little) != 0;
        return .{ .ok = o };
    }
    const v = readInt(val) orelse return .{ .err = -22 };
    switch (level) {
        SOL_IP => switch (optname) {
            // 1..255 sets, -1 restores the default; 0 and anything else is invalid.
            IP_TTL => {
                if (v == -1) {
                    o.ttl = 0;
                } else if (v >= 1 and v <= 255) {
                    o.ttl = @intCast(v);
                } else return .{ .err = -22 };
            },
            // Only the low byte; the ECN bits are not the user's to set.
            IP_TOS => o.tos = @as(u8, @truncate(@as(u32, @bitCast(v)))) & ~ECN_MASK,
            // -1 restores the default 1; 0..255 (0 keeps the datagram on this host).
            IP_MULTICAST_TTL => {
                if (v < -1 or v > 255) return .{ .err = -22 };
                o.mc4_ttl = if (v == -1) 1 else @intCast(v);
            },
            IP_MULTICAST_LOOP => o.mc4_loop = v != 0,
            IP_HDRINCL => o.hdrincl = v != 0,
            IP_PKTINFO => o.pktinfo = v != 0,
            IP_RECVTTL => o.recvttl = v != 0,
            IP_RECVTOS => o.recvtos = v != 0,
            IP_RECVORIGDSTADDR => o.origdst = v != 0,
            IP_RECVERR => o.recverr = v != 0,
            // ip_sock_set_mtu_discover: DONT..OMIT, anything else EINVAL.
            IP_MTU_DISCOVER => {
                if (v < PMTUDISC_DONT or v > PMTUDISC_OMIT) return .{ .err = -22 };
                o.pmtudisc = @intCast(v);
            },
            IP_MULTICAST_ALL => {
                if (v != 0 and v != 1) return .{ .err = -22 };
                o.mc4_all = v == 1;
            },
            else => return .{ .err = -92 },
        },
        SOL_IPV6 => switch (optname) {
            IPV6_UNICAST_HOPS => {
                if (v == -1) {
                    o.hops = 0;
                } else if (v >= 0 and v <= 255) {
                    // 0 is a legal hop limit on the wire but useless; keep it distinct from "unset".
                    o.hops = if (v == 0) 1 else @intCast(v);
                } else return .{ .err = -22 };
            },
            IPV6_TCLASS => {
                if (v == -1) {
                    o.tclass = 0;
                } else if (v >= 0 and v <= 255) {
                    o.tclass = @as(u8, @intCast(v)) & ~ECN_MASK;
                } else return .{ .err = -22 };
            },
            IPV6_V6ONLY => {
                // This stack has no IPv4-mapped dual-stack: an AF_INET6 socket is always v6-only.
                if (v == 0) return .{ .err = -22 };
            },
            // The multicast options need a full int (Linux checks optlen < sizeof(int) first).
            IPV6_MULTICAST_HOPS => {
                if (val.len < 4 or v < -1 or v > 255) return .{ .err = -22 };
                o.mc_hops = if (v == -1) DEFAULT_MCAST_HOPS else @intCast(v);
            },
            IPV6_MULTICAST_LOOP => {
                if (val.len < 4 or (v != 0 and v != 1)) return .{ .err = -22 };
                o.mc_loop = v == 1;
            },
            // The interface itself is checked by mcastIfErrno before this.
            IPV6_MULTICAST_IF => {
                if (val.len < 4 or v < 0 or v > 255) return .{ .err = -22 };
                o.mc_if = @intCast(v);
            },
            IPV6_MULTICAST_ALL => {
                if (val.len < 4) return .{ .err = -22 };
                o.mc_all = v != 0;
            },
            // do_ipv6_setsockopt: the boolean options need a full int.
            // do_ipv6_setsockopt: IPV6_PMTUDISC_DONT..OMIT, anything else EINVAL.
            IPV6_MTU_DISCOVER => {
                if (val.len < 4) return .{ .err = -22 };
                if (v < PMTUDISC_DONT or v > PMTUDISC_OMIT) return .{ .err = -22 };
                o.pmtudisc6 = @intCast(v);
            },
            IPV6_RECVPATHMTU => o.rxpmtu6 = v != 0,
            IPV6_FLOWINFO_SEND => o.sndflow6 = v != 0,
            IPV6_FLOWINFO => o.rxflow6 = v != 0,
            IPV6_RECVPKTINFO, IPV6_RECVHOPLIMIT, IPV6_RECVTCLASS, IPV6_RECVORIGDSTADDR, IPV6_RECVERR => {
                if (val.len < 4) return .{ .err = -22 };
                switch (optname) {
                    IPV6_RECVPKTINFO => o.pktinfo6 = v != 0,
                    IPV6_RECVHOPLIMIT => o.recvhops6 = v != 0,
                    IPV6_RECVORIGDSTADDR => o.origdst6 = v != 0,
                    IPV6_RECVERR => o.recverr6 = v != 0,
                    else => o.recvtclass6 = v != 0,
                }
            },
            else => return .{ .err = -92 },
        },
        else => return .{ .err = -92 },
    }
    return .{ .ok = o };
}

/// The interface an IPv4 multicast request names (Linux ip_mc_find_dev, ip_dev_find): an index (1 lo, 2 the NIC while it is up), else
/// an address of this host (127/8 is lo, `our` the NIC). Null: no such interface.
pub fn ifaceOf4(addr: [4]u8, index: u32, nic_active: bool, our: [4]u8) ?u8 {
    if (index != 0) {
        if (index == 1) return 1;
        if (index == 2 and nic_active) return 2;
        return null;
    }
    if (addr[0] == 127) return 1;
    if (nic_active and @as(u32, @bitCast(addr)) == @as(u32, @bitCast(our))) return 2;
    return null;
}

/// IP_MULTICAST_IF takes an in_addr (4 bytes), a struct ip_mreq (8: the interface address is the second word) or a struct ip_mreqn
/// (12: an address and an index); shorter is EINVAL. 0.0.0.0 without an index clears it; an interface that does not exist is
/// EADDRNOTAVAIL. getsockopt reports the address given.
pub fn setMulticastIf4(cur: IpOpts, val: []const u8, nic_active: bool, our: [4]u8) SetResult {
    if (val.len < 4) return .{ .err = -22 };
    const addr: [4]u8 = if (val.len >= 8) val[4..8].* else val[0..4].*;
    const index: u32 = if (val.len >= 12) std.mem.readInt(u32, val[8..12], .little) else 0;
    var o = cur;
    if (index == 0 and @as(u32, @bitCast(addr)) == 0) {
        o.mc4_addr = .{ 0, 0, 0, 0 };
        o.mc4_index = 0;
        return .{ .ok = o };
    }
    o.mc4_index = ifaceOf4(addr, index, nic_active, our) orelse return .{ .err = -99 };
    o.mc4_addr = addr;
    return .{ .ok = o };
}

/// The SOL_IP options a TCP socket refuses (do_ip_setsockopt on SOCK_STREAM): MULTICAST_TTL and MULTICAST_IF are EINVAL, group
/// membership EPROTO. Null: handled as for any socket.
pub fn streamSetErrno4(optname: u64) ?i64 {
    return switch (optname) {
        IP_MULTICAST_TTL, IP_MULTICAST_IF => -22,
        IP_ADD_MEMBERSHIP, IP_DROP_MEMBERSHIP => -71,
        else => null,
    };
}

/// IPV6_MULTICAST_IF names an interface that must exist: 0 (none), lo (1) or the active NIC (2); anything else is ENODEV.
pub fn mcastIfErrno(v: i32, nic_active: bool) i64 {
    if (v == 0 or v == 1 or (nic_active and v == 2)) return 0;
    return -19;
}

/// The SOL_IPV6 options a TCP socket refuses (Linux do_ipv6_setsockopt on SOCK_STREAM / inet_csk sockets): MULTICAST_HOPS and
/// MULTICAST_IF are ENOPROTOOPT, group membership EPROTO. Null: the option is handled as for any socket.
pub fn streamSetErrno(optname: u64) ?i64 {
    return switch (optname) {
        IPV6_MULTICAST_HOPS, IPV6_MULTICAST_IF => -92,
        IPV6_ADD_MEMBERSHIP, IPV6_DROP_MEMBERSHIP => -71,
        else => null,
    };
}

/// getsockopt value as an int, or null when the option does not exist.
pub fn getValue(o: IpOpts, level: u64, optname: u64) ?i32 {
    return switch (level) {
        SOL_IP => switch (optname) {
            IP_TTL => if (o.ttl == 0) DEFAULT_TTL else o.ttl,
            IP_TOS => o.tos,
            IP_HDRINCL => @intFromBool(o.hdrincl),
            IP_MTU_DISCOVER => o.pmtudisc,
            IP_PKTINFO => @intFromBool(o.pktinfo),
            IP_RECVTTL => @intFromBool(o.recvttl),
            IP_RECVTOS => @intFromBool(o.recvtos),
            IP_RECVORIGDSTADDR => @intFromBool(o.origdst),
            IP_RECVERR => @intFromBool(o.recverr),
            IP_MULTICAST_TTL => o.mc4_ttl,
            IP_MULTICAST_LOOP => @intFromBool(o.mc4_loop),
            IP_MULTICAST_ALL => @intFromBool(o.mc4_all),
            IP_MULTICAST_IF => @bitCast(o.mc4_addr),
            else => null,
        },
        SOL_IPV6 => switch (optname) {
            IPV6_UNICAST_HOPS => if (o.hops == 0) DEFAULT_TTL else o.hops,
            IPV6_TCLASS => o.tclass,
            IPV6_V6ONLY => 1,
            IPV6_MULTICAST_HOPS => o.mc_hops,
            IPV6_MULTICAST_LOOP => @intFromBool(o.mc_loop),
            IPV6_MULTICAST_IF => o.mc_if,
            IPV6_MULTICAST_ALL => @intFromBool(o.mc_all),
            IPV6_RECVPKTINFO => @intFromBool(o.pktinfo6),
            IPV6_RECVHOPLIMIT => @intFromBool(o.recvhops6),
            IPV6_RECVTCLASS => @intFromBool(o.recvtclass6),
            IPV6_RECVORIGDSTADDR => @intFromBool(o.origdst6),
            IPV6_RECVERR => @intFromBool(o.recverr6),
            IPV6_MTU_DISCOVER => o.pmtudisc6,
            IPV6_DONTFRAG => @intFromBool(o.dontfrag6),
            IPV6_RECVPATHMTU => @intFromBool(o.rxpmtu6),
            IPV6_FLOWINFO_SEND => @intFromBool(o.sndflow6),
            IPV6_FLOWINFO => @intFromBool(o.rxflow6),
            else => null,
        },
        else => null,
    };
}

/// A datagram (UDP, ping, raw) of a socket in IP_MTU_DISCOVER `mode` carries DF (__ip_make_skb: DO and PROBE always, WANT while
/// it fits the route's MTU, which every datagram sent here does; measured in hello419).
pub fn datagramDf(mode: u8) bool {
    return mode == PMTUDISC_WANT or mode == PMTUDISC_DO or mode == PMTUDISC_PROBE;
}

/// A TCP segment carries DF (ip_queue_xmit → ip_dont_fragment: DO, and WANT unless the route's MTU is locked).
pub fn streamDf(mode: u8) bool {
    return mode == PMTUDISC_WANT or mode == PMTUDISC_DO;
}

/// ip_sk_ignore_df: the stack may still fragment the socket's datagrams (DONT, WANT, OMIT).
pub fn ignoreDf(mode: u8) bool {
    return mode < PMTUDISC_DO or mode == PMTUDISC_OMIT;
}

/// The TTL / TOS to put in an IPv4 header (defaults when unset).
pub fn effectiveTtl(o: IpOpts) u8 {
    return if (o.ttl == 0) DEFAULT_TTL else o.ttl;
}

pub fn effectiveHops(o: IpOpts) u8 {
    return if (o.hops == 0) DEFAULT_TTL else o.hops;
}

/// Whether the header needs patching at all (everything default: leave it).
pub fn ipv4NeedsPatch(o: IpOpts) bool {
    return o.ttl != 0 or o.tos != 0;
}

pub fn ipv6NeedsPatch(o: IpOpts) bool {
    return o.hops != 0 or o.tclass != 0;
}

/// Patch an IPv4 header's TTL (byte 8) and TOS (byte 1) keeping the ECN bits
/// already there, then recompute the header checksum. `csum` computes the
/// RFC 1071 sum over the 20 header bytes.
pub fn patchIpv4(hdr: *[20]u8, o: IpOpts, csum: *const fn ([*]const u8, u16) u16) void {
    hdr[8] = effectiveTtl(o);
    hdr[1] = (hdr[1] & ECN_MASK) | o.tos;
    hdr[10] = 0;
    hdr[11] = 0;
    std.mem.writeInt(u16, hdr[10..12], csum(hdr, 20), .big);
}

/// Write the 20-bit flow label (the low bits of `label`, network order already decoded) into an IPv6 header.
pub fn setFlowLabel6(hdr: *[40]u8, label: u32) void {
    const l = label & 0xFFFFF;
    hdr[1] = (hdr[1] & 0xF0) | @as(u8, @intCast(l >> 16));
    hdr[2] = @truncate(l >> 8);
    hdr[3] = @truncate(l);
}

/// Set an IPv4 header's TTL (byte 8) and recompute its checksum.
pub fn setTtl4(hdr: *[20]u8, ttl: u8, csum: *const fn ([*]const u8, u16) u16) void {
    hdr[8] = ttl;
    hdr[10] = 0;
    hdr[11] = 0;
    std.mem.writeInt(u16, hdr[10..12], csum(hdr, 20), .big);
}

/// Patch an IPv6 header's hop limit (byte 7) and traffic class (bits 20..27),
/// keeping the ECN bits already there.
pub fn patchIpv6(hdr: *[40]u8, o: IpOpts) void {
    hdr[7] = effectiveHops(o);
    const old_tc: u8 = ((hdr[0] & 0x0f) << 4) | (hdr[1] >> 4);
    const tc: u8 = (old_tc & ECN_MASK) | o.tclass;
    hdr[0] = (hdr[0] & 0xF0) | (tc >> 4);
    hdr[1] = (hdr[1] & 0x0F) | (tc << 4);
}
