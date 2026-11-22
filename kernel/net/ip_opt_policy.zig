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
pub const IP_RECVOPTS: u64 = 6;
pub const IP_OPTIONS: u64 = 4;
pub const IP_RETOPTS: u64 = 7;
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
pub const IPV6_AUTOFLOWLABEL: u64 = 70;
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
    /// IP_RECVOPTS (6) / IP_RETOPTS (7) as receive switches: a datagram with IPv4 options brings them as control messages.
    recvopts: bool = false,
    retopts: bool = false,
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
    /// IPV6_AUTOFLOWLABEL as the socket set it, null while it has not (net.ipv6.auto_flowlabels decides: flowlabel_policy).
    autoflow6: ?bool = null,
    /// One send's explicit IPv6 flow label (an IPV6_FLOWINFO control message), 0 for none: carried here so the shared ICMPv6 / raw
    /// send path sees it without another parameter. Never stored with the socket's options.
    flow_ov6: u32 = 0,
    /// One send's skb->mark and skb->priority (the socket's SO_MARK / SO_PRIORITY or that send's control messages), carried the same
    /// way to the loopback frame (lo.Meta). Never stored with the socket's options.
    skb_mark: u32 = 0,
    skb_prio: u32 = 0,
    /// Option flags shared by the protocol paths. The RFC 2292 receive switches, IPV6_RECVHOPOPTS/RTHDR/DSTOPTS/FRAGSIZE,
    /// IPV6_ROUTER_ALERT_ISOLATE, IPV6_RECVERR_RFC4884, IPV6_ADDR_PREFERENCES, IP_PASSSEC, IP_CHECKSUM, IP_BIND_ADDRESS_NO_PORT,
    /// IP_RECVFRAGSIZE and IP_RECVERR_RFC4884 are only stored; FREEBIND/TRANSPARENT and MINHOPCOUNT/MINTTL affect bind and TCP input.
    flags6: u16 = 0,
    flags4: u16 = 0,
    min_hops6: u8 = 0,
    min_ttl4: u8 = 0,
    srcprefs6: u16 = 0,
    port_range4: u32 = 0,
};

/// Bits of IpOpts.flags6 / flags4.
pub const F6_2292PKTINFO: u16 = 1 << 0;
pub const F6_2292HOPOPTS: u16 = 1 << 1;
pub const F6_2292DSTOPTS: u16 = 1 << 2;
pub const F6_2292RTHDR: u16 = 1 << 3;
pub const F6_2292HOPLIMIT: u16 = 1 << 4;
pub const F6_RA_ISOLATE: u16 = 1 << 5;
pub const F6_RFC4884: u16 = 1 << 6;
pub const F6_RECVHOPOPTS: u16 = 1 << 7;
pub const F6_RECVRTHDR: u16 = 1 << 8;
pub const F6_RECVDSTOPTS: u16 = 1 << 9;
pub const F6_RECVFRAGSIZE: u16 = 1 << 10;
pub const F6_FREEBIND: u16 = 1 << 11;
pub const F6_TRANSPARENT: u16 = 1 << 12;
pub const F4_FREEBIND: u16 = 1 << 0;
pub const F4_PASSSEC: u16 = 1 << 1;
pub const F4_CHECKSUM: u16 = 1 << 2;
pub const F4_BIND_NO_PORT: u16 = 1 << 3;
pub const F4_RECVFRAGSIZE: u16 = 1 << 4;
pub const F4_RFC4884: u16 = 1 << 5;
pub const F4_TRANSPARENT: u16 = 1 << 6;
pub const F4_ROUTER_ALERT: u16 = 1 << 7;
pub const F4_NODEFRAG: u16 = 1 << 8;

/// Option numbers handled only by the rules below (Linux include/uapi/linux/in.h, in6.h).
pub const IP_ROUTER_ALERT: u64 = 5;
pub const IP_MTU: u64 = 14;
pub const IP_FREEBIND: u64 = 15;
pub const IP_IPSEC_POLICY: u64 = 16;
pub const IP_XFRM_POLICY: u64 = 17;
pub const IP_PASSSEC: u64 = 18;
pub const IP_TRANSPARENT: u64 = 19;
pub const IP_MINTTL: u64 = 21;
pub const IP_NODEFRAG: u64 = 22;
pub const IP_CHECKSUM: u64 = 23;
pub const IP_BIND_ADDRESS_NO_PORT: u64 = 24;
pub const IP_RECVFRAGSIZE: u64 = 25;
pub const IP_RECVERR_RFC4884: u64 = 26;
pub const IP_MSFILTER: u64 = 41;
pub const MCAST_MSFILTER: u64 = 48;
pub const IP_UNICAST_IF: u64 = 50;
pub const IP_LOCAL_PORT_RANGE: u64 = 51;
pub const IP_PROTOCOL: u64 = 52;
pub const IPV6_ADDRFORM: u64 = 1;
pub const IPV6_2292PKTINFO: u64 = 2;
pub const IPV6_2292HOPOPTS: u64 = 3;
pub const IPV6_2292DSTOPTS: u64 = 4;
pub const IPV6_2292RTHDR: u64 = 5;
pub const IPV6_2292PKTOPTIONS: u64 = 6;
pub const IPV6_2292HOPLIMIT: u64 = 8;
pub const IPV6_ROUTER_ALERT: u64 = 22;
pub const IPV6_MTU: u64 = 24;
pub const IPV6_ROUTER_ALERT_ISOLATE: u64 = 30;
pub const IPV6_RECVERR_RFC4884: u64 = 31;
pub const IPV6_IPSEC_POLICY: u64 = 34;
pub const IPV6_XFRM_POLICY: u64 = 35;
pub const IPV6_RECVHOPOPTS: u64 = 53;
pub const IPV6_HOPOPTS: u64 = 54;
pub const IPV6_RTHDRDSTOPTS: u64 = 55;
pub const IPV6_RECVRTHDR: u64 = 56;
pub const IPV6_RTHDR: u64 = 57;
pub const IPV6_RECVDSTOPTS: u64 = 58;
pub const IPV6_DSTOPTS: u64 = 59;
pub const IPV6_ADDR_PREFERENCES: u64 = 72;
pub const IPV6_MINHOPCOUNT: u64 = 73;
pub const IPV6_TRANSPARENT: u64 = 75;
pub const IPV6_UNICAST_IF: u64 = 76;
pub const IPV6_RECVFRAGSIZE: u64 = 77;
pub const IPV6_FREEBIND: u64 = 78;

fn flag6Of(optname: u64) ?u16 {
    return switch (optname) {
        IPV6_2292PKTINFO => F6_2292PKTINFO,
        IPV6_2292HOPOPTS => F6_2292HOPOPTS,
        IPV6_2292DSTOPTS => F6_2292DSTOPTS,
        IPV6_2292RTHDR => F6_2292RTHDR,
        IPV6_2292HOPLIMIT => F6_2292HOPLIMIT,
        IPV6_ROUTER_ALERT_ISOLATE => F6_RA_ISOLATE,
        IPV6_RECVHOPOPTS => F6_RECVHOPOPTS,
        IPV6_RECVRTHDR => F6_RECVRTHDR,
        IPV6_RECVDSTOPTS => F6_RECVDSTOPTS,
        IPV6_RECVFRAGSIZE => F6_RECVFRAGSIZE,
        IPV6_FREEBIND => F6_FREEBIND,
        else => null,
    };
}

fn flag4Of(optname: u64) ?u16 {
    return switch (optname) {
        IP_FREEBIND => F4_FREEBIND,
        IP_PASSSEC => F4_PASSSEC,
        IP_CHECKSUM => F4_CHECKSUM,
        IP_BIND_ADDRESS_NO_PORT => F4_BIND_NO_PORT,
        IP_RECVFRAGSIZE => F4_RECVFRAGSIZE,
        else => null,
    };
}

fn setFlag(word: u16, bit: u16, on: bool) u16 {
    return if (on) word | bit else word & ~bit;
}

/// ip6_sock_set_addr_preferences: PUBLIC / TMP / PUBTMP_DEFAULT, HOME / COA and CGA / NONCGA must each name at most one choice
/// (EINVAL); the stored bits keep the earlier choice of a group the call did not mention.
pub fn addrPreferences(cur: u16, val: i32) ?u16 {
    const v: u32 = @bitCast(val);
    var mask: u16 = 0xFFFF;
    var pref: u16 = 0;
    switch (v & 0x0103) {
        0x0002 => {
            pref |= 0x0002;
            mask &= ~@as(u16, 0x0003);
        },
        0x0001 => {
            pref |= 0x0001;
            mask &= ~@as(u16, 0x0003);
        },
        0x0100 => mask &= ~@as(u16, 0x0003),
        0 => {},
        else => return null,
    }
    switch (v & 0x0404) {
        0x0400 => mask &= ~@as(u16, 0x0004),
        0x0004 => pref |= 0x0004,
        0 => {},
        else => return null,
    }
    switch (v & 0x0808) {
        0x0008, 0x0800, 0 => {},
        else => return null,
    }
    return (cur & mask) | pref;
}

/// getsockopt(IPV6_ADDR_PREFERENCES): TMP, else PUBLIC, else PUBTMP_DEFAULT; COA, else HOME.
pub fn addrPreferencesValue(prefs: u16) i32 {
    var v: i32 = if (prefs & 0x0001 != 0) 0x0001 else if (prefs & 0x0002 != 0) 0x0002 else 0x0100;
    v |= if (prefs & 0x0004 != 0) 0x0004 else 0x0400;
    return v;
}

/// IP_TOS / IPV6_TCLASS on a datagram socket keep the two ECN bits the caller gave (__ip_sock_set_tos and do_ipv6_setsockopt
/// clear them only for SOCK_STREAM, which applySet's result is shaped for). `v` is the value set; `r` applySet's answer.
pub fn keepEcnForDatagram(r: SetResult, level: u64, optname: u64, v: i32) SetResult {
    var o = switch (r) {
        .ok => |x| x,
        .err => return r,
    };
    const ecn: u8 = @as(u8, @truncate(@as(u32, @bitCast(v)))) & ECN_MASK;
    if (level == SOL_IP and optname == IP_TOS) o.tos |= ecn;
    if (level == SOL_IPV6 and optname == IPV6_TCLASS and v != -1) o.tclass |= ecn;
    return .{ .ok = o };
}

/// The rules for the options IpOpts only stores, plus the ones whose answer is fixed here (no routing alert, ipsec, anycast,
/// multicast source filters, unicast-interface binding or address-form change). `int_len` is the optlen the caller gave. Null:
/// not one of them.
pub fn applyExtra(cur: IpOpts, level: u64, optname: u64, v: i32, int_len: usize, has_net_admin: bool) ?SetResult {
    return applyExtraCaps(cur, level, optname, v, int_len, has_net_admin, has_net_admin);
}

/// Linux has one INET_FLAGS_FREEBIND bit shared by IP_FREEBIND and IPV6_FREEBIND.
pub fn freebind(o: IpOpts) bool {
    return o.flags4 & F4_FREEBIND != 0 or o.flags6 & F6_FREEBIND != 0;
}

/// IP_TRANSPARENT and IPV6_TRANSPARENT share INET_FLAGS_TRANSPARENT.
pub fn transparent(o: IpOpts) bool {
    return o.flags4 & F4_TRANSPARENT != 0 or o.flags6 & F6_TRANSPARENT != 0;
}

/// applyExtra with CAP_NET_RAW apart from "CAP_NET_RAW or CAP_NET_ADMIN" (`may_transparent`): the sticky hop-by-hop and
/// destination-option headers need CAP_NET_RAW (ipv6_set_opt_hdr), IP_TRANSPARENT / IPV6_TRANSPARENT either one.
pub fn applyExtraCaps(cur: IpOpts, level: u64, optname: u64, v: i32, int_len: usize, may_transparent: bool, has_net_raw: bool) ?SetResult {
    return applyExtraFor(cur, level, optname, v, int_len, may_transparent, has_net_raw, false);
}

/// applyExtraCaps for a raw socket (`raw`): IP_ROUTER_ALERT (ip_ra_control) and IP_NODEFRAG are its options and are stored.
pub fn applyExtraFor(cur: IpOpts, level: u64, optname: u64, v: i32, int_len: usize, may_transparent: bool, has_net_raw: bool, raw: bool) ?SetResult {
    const has_net_admin = may_transparent;
    if ((level == SOL_IP and optname == IP_FREEBIND) or (level == SOL_IPV6 and optname == IPV6_FREEBIND)) {
        if (int_len < 4) return .{ .err = -22 };
        var o = cur;
        o.flags4 = setFlag(o.flags4, F4_FREEBIND, v != 0);
        o.flags6 = setFlag(o.flags6, F6_FREEBIND, v != 0);
        return .{ .ok = o };
    }
    if (raw and level == SOL_IP and (optname == IP_ROUTER_ALERT or optname == IP_NODEFRAG)) {
        var r = cur;
        // ip_ra_control: turning the alert on again while this socket is on the chain is EADDRINUSE.
        if (optname == IP_ROUTER_ALERT and v != 0 and cur.flags4 & F4_ROUTER_ALERT != 0) return .{ .err = -98 };
        // Turning it off while it is not on finds nothing to remove and no new entry to add: ENOBUFS.
        if (optname == IP_ROUTER_ALERT and v == 0 and cur.flags4 & F4_ROUTER_ALERT == 0) return .{ .err = -105 };
        r.flags4 = setFlag(r.flags4, if (optname == IP_ROUTER_ALERT) F4_ROUTER_ALERT else F4_NODEFRAG, v != 0);
        return .{ .ok = r };
    }
    var o = cur;
    switch (level) {
        SOL_IPV6 => switch (optname) {
            IPV6_ADDRFORM => return .{ .err = -22 },
            IPV6_2292PKTOPTIONS => return .{ .ok = o },
            IPV6_ROUTER_ALERT => return .{ .err = -92 },
            IPV6_MTU => {
                if (int_len < 4) return .{ .err = -22 };
                return .{ .err = -22 };
            },
            27, 28 => return .{ .err = -22 },
            IPV6_IPSEC_POLICY, IPV6_XFRM_POLICY => return .{ .err = -1 },
            42, 43, 44, 45, 46, 47, MCAST_MSFILTER => return .{ .err = -22 },
            IPV6_PKTINFO => return .{ .err = -22 },
            // With CAP_NET_RAW the 4-byte value fails the header check (under 8 bytes or not a multiple of 8): EINVAL.
            IPV6_HOPOPTS, IPV6_RTHDRDSTOPTS, IPV6_DSTOPTS => return .{ .err = if (has_net_raw) -22 else -1 },
            IPV6_RTHDR => return .{ .err = -22 },
            IPV6_TRANSPARENT => {
                if (v != 0 and !has_net_admin) return .{ .err = -1 };
                if (int_len < 4) return .{ .err = -22 };
                o.flags6 = setFlag(o.flags6, F6_TRANSPARENT, v != 0);
                return .{ .ok = o };
            },
            IPV6_UNICAST_IF => return .{ .err = -99 },
            IPV6_RECVERR_RFC4884 => {
                if (int_len < 4 or v < 0 or v > 1) return .{ .err = -22 };
                o.flags6 = setFlag(o.flags6, F6_RFC4884, v != 0);
                return .{ .ok = o };
            },
            IPV6_MINHOPCOUNT => {
                if (int_len < 4 or v < 0 or v > 255) return .{ .err = -22 };
                o.min_hops6 = @intCast(v);
                return .{ .ok = o };
            },
            IPV6_ADDR_PREFERENCES => {
                if (int_len < 4) return .{ .err = -22 };
                o.srcprefs6 = addrPreferences(o.srcprefs6, v) orelse return .{ .err = -22 };
                return .{ .ok = o };
            },
            else => {
                const bit = flag6Of(optname) orelse return null;
                // IPV6_RECVFRAGSIZE takes any length (no optlen check in do_ipv6_setsockopt); the others need a full int.
                if (optname != IPV6_RECVFRAGSIZE and int_len < 4) return .{ .err = -22 };
                o.flags6 = setFlag(o.flags6, bit, v != 0);
                return .{ .ok = o };
            },
        },
        SOL_IP => switch (optname) {
            IP_ROUTER_ALERT => return .{ .err = -22 },
            IP_MTU, IP_NODEFRAG, IP_PROTOCOL => return .{ .err = -92 },
            IP_IPSEC_POLICY, IP_XFRM_POLICY => return .{ .err = -1 },
            IP_TRANSPARENT => {
                if (v != 0 and !has_net_admin) return .{ .err = -1 };
                if (int_len < 1) return .{ .err = -22 };
                o.flags4 = setFlag(o.flags4, F4_TRANSPARENT, v != 0);
                return .{ .ok = o };
            },
            37, 38, 39, 40, IP_MSFILTER, 42, 43, 44, 45, 46, 47, MCAST_MSFILTER => return .{ .err = -22 },
            IP_UNICAST_IF => return .{ .err = if (int_len != 4) -22 else -99 },
            IP_MINTTL => {
                if (v < 0 or v > 255) return .{ .err = -22 };
                o.min_ttl4 = @intCast(v);
                return .{ .ok = o };
            },
            IP_RECVERR_RFC4884 => {
                if (v < 0 or v > 1) return .{ .err = -22 };
                o.flags4 = setFlag(o.flags4, F4_RFC4884, v != 0);
                return .{ .ok = o };
            },
            IP_LOCAL_PORT_RANGE => {
                if (int_len != 4) return .{ .err = -22 };
                const u: u32 = @bitCast(v);
                const lo: u16 = @truncate(u);
                const hi: u16 = @truncate(u >> 16);
                if (lo != 0 and hi != 0 and lo > hi) return .{ .err = -22 };
                o.port_range4 = u;
                return .{ .ok = o };
            },
            else => {
                const bit = flag4Of(optname) orelse return null;
                o.flags4 = setFlag(o.flags4, bit, v != 0);
                return .{ .ok = o };
            },
        },
        else => return null,
    }
}

/// getsockopt of the options applyExtra handles: the stored value, a fixed one, or (as `err`) the errno Linux answers. Null: not
/// one of them.
pub fn getExtra(o: IpOpts, level: u64, optname: u64) ?union(enum) { val: i32, err: i64 } {
    if ((level == SOL_IP and optname == IP_FREEBIND) or (level == SOL_IPV6 and optname == IPV6_FREEBIND)) return .{ .val = @intFromBool(freebind(o)) };
    switch (level) {
        SOL_IPV6 => switch (optname) {
            // IPV6_ADDRFORM on a UDP socket that is not connected, IPV6_MTU without a route.
            IPV6_ADDRFORM, IPV6_MTU => return .{ .err = -107 },
            IPV6_RECVERR_RFC4884 => return .{ .val = @intFromBool(o.flags6 & F6_RFC4884 != 0) },
            IPV6_MINHOPCOUNT => return .{ .val = o.min_hops6 },
            IPV6_ADDR_PREFERENCES => return .{ .val = addrPreferencesValue(o.srcprefs6) },
            IPV6_ROUTER_ALERT => return .{ .val = 0 },
            // Linux keeps one transparent bit for both families (inet TRANSPARENT).
            IPV6_TRANSPARENT => return .{ .val = @intFromBool(o.flags6 & F6_TRANSPARENT != 0 or o.flags4 & F4_TRANSPARENT != 0) },
            IPV6_UNICAST_IF => return .{ .val = 0 },
            MCAST_MSFILTER => return .{ .err = -99 },
            // The sticky header options (ipv6_getsockopt_sticky): no options set, nothing copied.
            IPV6_HOPOPTS, IPV6_RTHDRDSTOPTS, IPV6_RTHDR, IPV6_DSTOPTS => return .{ .val = -1 },
            else => {
                const bit = flag6Of(optname) orelse return null;
                return .{ .val = @intFromBool(o.flags6 & bit != 0) };
            },
        },
        SOL_IP => switch (optname) {
            IP_ROUTER_ALERT => return .{ .val = @intFromBool(o.flags4 & F4_ROUTER_ALERT != 0) },
            IP_NODEFRAG => return .{ .val = @intFromBool(o.flags4 & F4_NODEFRAG != 0) },
            IP_UNICAST_IF, IP_PROTOCOL => return .{ .val = 0 },
            IP_TRANSPARENT => return .{ .val = @intFromBool(o.flags4 & F4_TRANSPARENT != 0 or o.flags6 & F6_TRANSPARENT != 0) },
            IP_MTU => return .{ .err = -107 },
            IP_MINTTL => return .{ .val = o.min_ttl4 },
            IP_RECVERR_RFC4884 => return .{ .val = @intFromBool(o.flags4 & F4_RFC4884 != 0) },
            IP_LOCAL_PORT_RANGE => return .{ .val = @bitCast(o.port_range4) },
            IP_MSFILTER, MCAST_MSFILTER => return .{ .err = -22 },
            else => {
                const bit = flag4Of(optname) orelse return null;
                return .{ .val = @intFromBool(o.flags4 & bit != 0) };
            },
        },
        else => return null,
    }
}

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
            IP_RECVOPTS => o.recvopts = v != 0,
            IP_RETOPTS => o.retopts = v != 0,
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
            IPV6_AUTOFLOWLABEL => o.autoflow6 = v != 0,
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
            IP_RECVOPTS => @intFromBool(o.recvopts),
            IP_RETOPTS => @intFromBool(o.retopts),
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
            IPV6_AUTOFLOWLABEL => @intFromBool(@import("flowlabel_policy.zig").socketWants(o.autoflow6, @import("flowlabel_policy.zig").mode())),
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
