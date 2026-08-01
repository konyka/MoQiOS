// kernel/net/icmpv6.zig — ICMPv6 (RFC 4443) + minimal NDP message handling.
//
// Implements:
//   - Echo Request → Echo Reply
//   - Neighbor Solicitation → Neighbor Advertisement
//   - Cache learning from received NS/NA messages.
//
// All ICMPv6 messages must include the IPv6 pseudo-header in their checksum.

const nic = @import("nic.zig");
const netif = @import("netif.zig");
const eth = @import("eth.zig");
const ipv6 = @import("ipv6.zig");
const ipv4 = @import("ipv4.zig");
const ndp = @import("ndp.zig");
const bo = @import("../lib/byte_order.zig");

// ── ICMPv6 message types (RFC 4443 + RFC 4861) ─────────────────────────────
/// RFC 4443 Packet Too Big (SK-97).
pub const PACKET_TOO_BIG: u8 = 2;
pub const ECHO_REQUEST: u8 = 128;
pub const ECHO_REPLY: u8 = 129;
pub const ROUTER_SOLICITATION: u8 = 133;
pub const ROUTER_ADVERTISEMENT: u8 = 134;
pub const NEIGHBOR_SOLICITATION: u8 = 135;
pub const NEIGHBOR_ADVERTISEMENT: u8 = 136;
pub const REDIRECT: u8 = 137;

// NDP option types
const OPT_SOURCE_LL_ADDR: u8 = 1;
const OPT_TARGET_LL_ADDR: u8 = 2;
const OPT_PREFIX_INFORMATION: u8 = 3;
/// RFC 4861 §4.6.4 MTU option (SK-102).
const OPT_MTU: u8 = 5;
/// RFC 4191 Route Information Option (SK-94).
const OPT_ROUTE_INFORMATION: u8 = 24;

/// Max Prefix Information options retained from one RA (SK-83).
pub const MAX_RA_PREFIXES: usize = 4;
/// Max Route Information options retained from one RA (SK-94).
pub const MAX_RA_ROUTES: usize = 4;

/// RFC 4861 §4.6.2 Prefix Information option fields.
pub const PrefixInfo = struct {
    prefix: [16]u8 = @splat(0),
    prefix_len: u8 = 0,
    on_link: bool = false,
    autonomous: bool = false,
    valid_lifetime: u32 = 0,
    preferred_lifetime: u32 = 0,
};

/// RFC 4191 Route Information option fields (SK-94).
pub const RouteInfo = struct {
    prefix: [16]u8 = @splat(0),
    prefix_len: u8 = 0,
    /// -1 low, 0 medium, 1 high.
    preference: i8 = 0,
    lifetime_sec: u32 = 0,
};

/// Compute the ICMPv6 checksum over the pseudo-header + ICMPv6 message.
/// `data` points at the start of the ICMPv6 header (with checksum field zeroed).
pub fn checksum(
    src: [16]u8,
    dst: [16]u8,
    data: [*]const u8,
    len: u16,
) u16 {
    var acc: u64 = ipv6.pseudoHeaderChecksum(src, dst, ipv6.PROTO_ICMPV6, len);

    var i: usize = 0;
    while (i + 2 <= len) : (i += 2) {
        acc += (@as(u64, data[i]) << 8) | @as(u64, data[i + 1]);
    }
    if (i < len) {
        acc += @as(u64, data[i]) << 8;
    }

    var sum: u32 = @truncate(acc);
    sum +%= @as(u32, @truncate(acc >> 32));
    sum = (sum & 0xFFFF) + (sum >> 16);
    sum = (sum & 0xFFFF) + (sum >> 16);
    return @truncate(~sum);
}

/// Top-level dispatcher invoked by the IPv6 layer.
pub fn handlePacket(
    src_ip: [16]u8,
    dst_ip: [16]u8,
    data: [*]const u8,
    len: u16,
) void {
    if (len < 8) return;
    // v53.37: Verify ICMPv6 checksum (RFC 4443 §2.3). checksum() returns 0 for valid packets.
    if (checksum(src_ip, dst_ip, data, len) != 0) return;
    const icmp_type = data[0];

    switch (icmp_type) {
        ECHO_REQUEST => sendEchoReply(src_ip, dst_ip, data, len),
        ROUTER_ADVERTISEMENT => handleRouterAdvertisement(src_ip, data, len),
        NEIGHBOR_SOLICITATION => handleNeighborSolicitation(src_ip, dst_ip, data, len),
        NEIGHBOR_ADVERTISEMENT => handleNeighborAdvertisement(src_ip, data, len),
        REDIRECT => handleRedirect(src_ip, data, len),
        PACKET_TOO_BIG => handlePacketTooBig(data, len),
        else => {},
    }
}

/// Parsed Packet Too Big (RFC 4443 §3.2) (SK-97).
pub const PacketTooBigMsg = struct {
    mtu: u32 = 0,
    /// Destination of the invoking IPv6 packet (PMTU cache key).
    dst: [16]u8 = @splat(0),
};

/// Pure PTB parser: needs ICMP header + invoking IPv6 header.
pub fn parsePacketTooBig(data: [*]const u8, len: u16) ?PacketTooBigMsg {
    if (len < 8 + ipv6.HEADER_LEN) return null;
    if (data[0] != PACKET_TOO_BIG or data[1] != 0) return null;
    const inv = ipv6.parseHeader(data + 8) orelse return null;
    return .{
        .mtu = bo.readU32BeAt(data, 4),
        .dst = inv.dst_ip,
    };
}

fn handlePacketTooBig(data: [*]const u8, len: u16) void {
    const msg = parsePacketTooBig(data, len) orelse return;
    if (ipv6.isMulticast(msg.dst) or ipv6.isUnspecified(msg.dst)) return;
    ipv6.updatePathMtu(msg.dst, msg.mtu);
}

/// Parsed Redirect (RFC 4861 §4.5) (SK-95).
pub const RedirectMsg = struct {
    target: [16]u8 = @splat(0),
    destination: [16]u8 = @splat(0),
    target_ll: ?[6]u8 = null,
};

/// Pure Redirect parser. Requires the 40-byte Redirect body.
pub fn parseRedirect(data: [*]const u8, len: u16) ?RedirectMsg {
    if (len < 40) return null;
    if (data[0] != REDIRECT or data[1] != 0) return null;
    var msg: RedirectMsg = .{};
    @memcpy(&msg.target, data[8..24]);
    @memcpy(&msg.destination, data[24..40]);
    var off: u16 = 40;
    while (off + 2 <= len) {
        const opt_type = data[off];
        const opt_units = data[off + 1];
        if (opt_units == 0) break;
        const opt_len: u16 = @as(u16, opt_units) * 8;
        if (off + opt_len > len) break;
        if (opt_type == OPT_TARGET_LL_ADDR and opt_len >= 8) {
            msg.target_ll = .{
                data[off + 2], data[off + 3], data[off + 4],
                data[off + 5], data[off + 6], data[off + 7],
            };
        }
        off += opt_len;
    }
    return msg;
}

fn handleRedirect(src_ip: [16]u8, data: [*]const u8, len: u16) void {
    // RFC 4861 §8.1 host validation (subset).
    if (!ipv6.isLinkLocal(src_ip)) return;
    const msg = parseRedirect(data, len) orelse return;
    if (ipv6.isMulticast(msg.destination)) return;
    const on_link = ipv6.addrEq(msg.target, msg.destination);
    if (!on_link and !ipv6.isLinkLocal(msg.target)) return;
    if (!ndp.isCurrentFirstHop(msg.destination, src_ip)) return;
    ndp.applyRedirect(msg.destination, msg.target);
    if (msg.target_ll) |mac| {
        ndp.update(msg.target, mac);
    }
}

/// Parsed Router Advertisement fields (SK-82/83/94).
pub const RouterAdvert = struct {
    hop_limit: u8 = 0,
    router_lifetime_sec: u16 = 0,
    reachable_ms: u32 = 0,
    retrans_ms: u32 = 0,
    source_ll: ?[6]u8 = null,
    /// RA MTU option value when present (SK-102).
    mtu: ?u32 = null,
    prefixes: [MAX_RA_PREFIXES]PrefixInfo = @splat(.{}),
    prefix_count: u8 = 0,
    routes: [MAX_RA_ROUTES]RouteInfo = @splat(.{}),
    route_count: u8 = 0,
};

/// Pure RA parser (RFC 4861 §4.2). Requires at least the 16-byte RA header.
pub fn parseRouterAdvertisement(data: [*]const u8, len: u16) ?RouterAdvert {
    if (len < 16) return null;
    if (data[0] != ROUTER_ADVERTISEMENT or data[1] != 0) return null;
    var adv: RouterAdvert = .{
        .hop_limit = data[4],
        .router_lifetime_sec = bo.readU16BeAt(data, 6),
        .reachable_ms = bo.readU32BeAt(data, 8),
        .retrans_ms = bo.readU32BeAt(data, 12),
    };
    var off: u16 = 16;
    while (off + 2 <= len) {
        const opt_type = data[off];
        const opt_units = data[off + 1];
        if (opt_units == 0) break;
        const opt_len: u16 = @as(u16, opt_units) * 8;
        if (off + opt_len > len) break;
        if (opt_type == OPT_SOURCE_LL_ADDR and opt_len >= 8) {
            adv.source_ll = .{
                data[off + 2], data[off + 3], data[off + 4],
                data[off + 5], data[off + 6], data[off + 7],
            };
        } else if (opt_type == OPT_MTU and opt_len >= 8) {
            // type(1)+len(1)+reserved(2)+mtu(4)
            adv.mtu = bo.readU32BeAt(data, off + 4);
        } else if (opt_type == OPT_PREFIX_INFORMATION and opt_len >= 32) {
            // type(1)+len(1)+prefix_len(1)+flags(1)+valid(4)+pref(4)+reserved(4)+prefix(16)
            if (adv.prefix_count < MAX_RA_PREFIXES) {
                const flags = data[off + 3];
                var pfx: [16]u8 = undefined;
                @memcpy(&pfx, data[off + 16 .. off + 32]);
                adv.prefixes[adv.prefix_count] = .{
                    .prefix = pfx,
                    .prefix_len = data[off + 2],
                    .on_link = (flags & 0x80) != 0,
                    .autonomous = (flags & 0x40) != 0,
                    .valid_lifetime = bo.readU32BeAt(data, off + 4),
                    .preferred_lifetime = bo.readU32BeAt(data, off + 8),
                };
                adv.prefix_count += 1;
            }
        } else if (opt_type == OPT_ROUTE_INFORMATION and opt_units >= 1 and opt_units <= 3) {
            // type(1)+len(1)+prefix_len(1)+flags(1)+lifetime(4)+prefix(0/8/16)
            const prf_bits: u8 = (data[off + 3] >> 3) & 0x3;
            if (prf_bits != 0b10 and adv.route_count < MAX_RA_ROUTES) {
                const preference: i8 = switch (prf_bits) {
                    0b01 => 1,
                    0b11 => -1,
                    else => 0,
                };
                var pfx: [16]u8 = @splat(0);
                if (opt_units >= 2) @memcpy(pfx[0..8], data[off + 8 .. off + 16]);
                if (opt_units >= 3) @memcpy(pfx[8..16], data[off + 16 .. off + 24]);
                adv.routes[adv.route_count] = .{
                    .prefix = pfx,
                    .prefix_len = data[off + 2],
                    .preference = preference,
                    .lifetime_sec = bo.readU32BeAt(data, off + 4),
                };
                adv.route_count += 1;
            }
        }
        off += opt_len;
    }
    return adv;
}

fn handleRouterAdvertisement(src_ip: [16]u8, data: [*]const u8, len: u16) void {
    const adv = parseRouterAdvertisement(data, len) orelse return;
    if (adv.source_ll) |mac| {
        if (!ipv6.isUnspecified(src_ip)) ndp.update(src_ip, mac);
    }
    ndp.setDefaultRouter(src_ip, adv.router_lifetime_sec);
    // SK-88: a usable RA ends the solicitation burst.
    if (adv.router_lifetime_sec != 0) stopRouterSolicit();
    // SK-102: RA MTU option lowers/raises the interface MTU (≥ IPv6 minimum).
    if (adv.mtu) |m| {
        if (m >= ipv6.MIN_MTU) netif.setMtu(m);
    }
    const our_mac = netif.getMac();
    var i: u8 = 0;
    while (i < adv.prefix_count) : (i += 1) {
        const p = adv.prefixes[i];
        ndp.setPrefix(p.prefix, p.prefix_len, p.on_link, p.autonomous, p.valid_lifetime);
        // SK-84/85: A-flag /64 → tentative SLAAC + DAD NS.
        if (p.autonomous) {
            if (ndp.installSlaac(p.prefix, p.prefix_len, p.valid_lifetime, p.preferred_lifetime, our_mac)) |tentative| {
                sendDadNeighborSolicitation(tentative);
            }
        }
    }
    // SK-94: Route Information → more-specific off-link next hops.
    var ri: u8 = 0;
    while (ri < adv.route_count) : (ri += 1) {
        const r = adv.routes[ri];
        ndp.setRoute(r.prefix, r.prefix_len, r.lifetime_sec, r.preference, src_ip);
    }
}

/// Echo Reply: copy the request body, swap addresses, recompute checksum.
pub fn sendEchoReply(
    requester_ip: [16]u8,
    our_ip_in: [16]u8,
    data: [*]const u8,
    len: u16,
) void {
    if (len < 8 or len > 1280) return;

    const dst_mac = ndp.lookup(requester_ip) orelse return;
    const our_mac = netif.getMac();
    const our_ip = our_ip_in; // reply from the address we received it on

    var pkt: [1500]u8 = undefined;
    const eth_len: u16 = 14;
    const ip_off: u16 = eth_len;
    const icmp_off: u16 = eth_len + ipv6.HEADER_LEN;

    // Copy the entire ICMPv6 message (type/code/checksum/body) then patch.
    @memcpy(pkt[icmp_off .. icmp_off + len], data[0..len]);
    pkt[icmp_off + 0] = ECHO_REPLY;
    pkt[icmp_off + 1] = 0; // code
    pkt[icmp_off + 2] = 0; // checksum hi (cleared)
    pkt[icmp_off + 3] = 0; // checksum lo (cleared)

    ipv6.buildHeader(pkt[ip_off..].ptr, our_ip, requester_ip, ipv6.PROTO_ICMPV6, len);

    const csum = checksum(our_ip, requester_ip, pkt[icmp_off..].ptr, len);
    bo.writeU16BeAt(&pkt, icmp_off + 2, csum);

    const frame_len = eth.buildFrame(&pkt, dst_mac, our_mac, eth.ETHERTYPE_IPV6, ipv6.HEADER_LEN + len);
    _ = nic.sendPacket(&pkt, frame_len);
}

fn handleNeighborSolicitation(
    src_ip: [16]u8,
    dst_ip: [16]u8,
    data: [*]const u8,
    len: u16,
) void {
    // NS layout: type(1)+code(1)+csum(2)+reserved(4)+target(16)+options
    if (len < 24) return;
    _ = dst_ip;

    var target: [16]u8 = undefined;
    inline for (0..16) |i| target[i] = data[8 + i];

    // SK-85: NS for our tentative address ⇒ DAD conflict (RFC 4862 §5.4.3).
    if (ndp.isTentative(target)) {
        ndp.dadConflict(target);
        return;
    }

    // Learn sender MAC from Source Link-Layer Address option, if present.
    var off: u16 = 24;
    while (off + 2 <= len) {
        const opt_type = data[off];
        const opt_units = data[off + 1];
        if (opt_units == 0) break;
        const opt_len: u16 = @as(u16, opt_units) * 8;
        if (off + opt_len > len) break;
        if (opt_type == OPT_SOURCE_LL_ADDR and opt_len >= 8) {
            const sender_mac: [6]u8 = .{
                data[off + 2], data[off + 3], data[off + 4],
                data[off + 5], data[off + 6], data[off + 7],
            };
            if (!ipv6.isUnspecified(src_ip)) ndp.update(src_ip, sender_mac);
        }
        off += opt_len;
    }

    // Only respond if the target is one of our addresses (not tentative — handled above).
    const our_mac = netif.getMac();
    const our_ll = ndp.generateLinkLocal(our_mac);
    if (!ipv6.addrEq(target, our_ll) and !ndp.hasLocalAddress(target)) return;

    sendNeighborAdvertisement(src_ip, target, true); // v53.37: solicited NA — set S flag (W1 fix, RFC 4861 §7.2.4)
}

fn handleNeighborAdvertisement(src_ip: [16]u8, data: [*]const u8, len: u16) void {
    // NA layout: type(1)+code(1)+csum(2)+flags(4)+target(16)+options
    if (len < 24) return;
    _ = src_ip;

    var target: [16]u8 = undefined;
    inline for (0..16) |i| target[i] = data[8 + i];

    // SK-85: NA claiming our tentative target ⇒ DAD conflict.
    if (ndp.isTentative(target)) {
        ndp.dadConflict(target);
        return;
    }

    var off: u16 = 24;
    while (off + 2 <= len) {
        const opt_type = data[off];
        const opt_units = data[off + 1];
        if (opt_units == 0) break;
        const opt_len: u16 = @as(u16, opt_units) * 8;
        if (off + opt_len > len) break;
        if (opt_type == OPT_TARGET_LL_ADDR and opt_len >= 8) {
            const target_mac: [6]u8 = .{
                data[off + 2], data[off + 3], data[off + 4],
                data[off + 5], data[off + 6], data[off + 7],
            };
            ndp.update(target, target_mac);
            return;
        }
        off += opt_len;
    }
}

/// Build a Neighbor Advertisement frame into `out`, claiming `target` is at
/// `our_mac`, destined for `dst_mac`. Pure: caller supplies both MACs, no
/// ndp/netif/nic side effects — arch-clean and testable in isolation.
/// Returns the total ethernet frame length.
pub fn buildNeighborAdvertisement(
    out: [*]u8,
    requester_ip: [16]u8,
    target: [16]u8,
    our_mac: [6]u8,
    dst_mac: [6]u8,
    solicited: bool,
) u16 {
    // ICMPv6 NA = 24 bytes header + 8-byte Target LL Addr option = 32 bytes
    const icmp_len: u16 = 32;
    const total_payload: u16 = ipv6.HEADER_LEN + icmp_len;
    const eth_len: u16 = 14;
    const ip_off: u16 = eth_len;
    const icmp_off: u16 = eth_len + ipv6.HEADER_LEN;

    // ICMPv6 NA fields
    out[icmp_off + 0] = NEIGHBOR_ADVERTISEMENT;
    out[icmp_off + 1] = 0; // code
    out[icmp_off + 2] = 0; // checksum (filled below)
    out[icmp_off + 3] = 0;

    // Flags: R=0, S=solicited, O=1 (override).
    var flags: u8 = 0x20; // O bit
    if (solicited) flags |= 0x40; // S bit
    out[icmp_off + 4] = flags;
    out[icmp_off + 5] = 0;
    out[icmp_off + 6] = 0;
    out[icmp_off + 7] = 0;

    // Target address
    @memcpy(out[icmp_off + 8 .. icmp_off + 24], &target);

    // Target Link-Layer Address option (type=2, len=1 unit=8 bytes)
    out[icmp_off + 24] = OPT_TARGET_LL_ADDR;
    out[icmp_off + 25] = 1;
    @memcpy(out[icmp_off + 26 .. icmp_off + 32], &our_mac);

    ipv6.buildHeader(out + ip_off, target, requester_ip, ipv6.PROTO_ICMPV6, icmp_len);

    const csum = checksum(target, requester_ip, out + icmp_off, icmp_len);
    bo.writeU16BeAt(out, icmp_off + 2, csum);

    return eth.buildFrame(out, dst_mac, our_mac, eth.ETHERTYPE_IPV6, total_payload);
}

/// Send a Neighbor Advertisement to `requester_ip` claiming `target` is at our MAC.
/// `solicited` indicates whether this NA is in response to an NS (sets S flag).
pub fn sendNeighborAdvertisement(
    requester_ip: [16]u8,
    target: [16]u8,
    solicited: bool,
) void {
    const dst_mac = ndp.lookup(requester_ip) orelse return;
    const our_mac = netif.getMac();

    var pkt: [128]u8 = @splat(0);
    const frame_len = buildNeighborAdvertisement(&pkt, requester_ip, target, our_mac, dst_mac, solicited);
    _ = nic.sendPacket(&pkt, frame_len);
}

fn fillNeighborSolicitationBody(out: [*]u8, icmp_off: u16, target: [16]u8, our_mac: [6]u8) void {
    out[icmp_off + 0] = NEIGHBOR_SOLICITATION;
    out[icmp_off + 1] = 0; // code
    out[icmp_off + 2] = 0; // checksum
    out[icmp_off + 3] = 0;
    out[icmp_off + 4] = 0; // reserved
    out[icmp_off + 5] = 0;
    out[icmp_off + 6] = 0;
    out[icmp_off + 7] = 0;
    @memcpy(out[icmp_off + 8 .. icmp_off + 24], &target);
    // Source Link-Layer Address option (type=1, len=1 unit=8 bytes)
    out[icmp_off + 24] = OPT_SOURCE_LL_ADDR;
    out[icmp_off + 25] = 1;
    @memcpy(out[icmp_off + 26 .. icmp_off + 32], &our_mac);
}

fn buildNsFrame(
    out: [*]u8,
    our_ip: [16]u8,
    target: [16]u8,
    our_mac: [6]u8,
    dst_ip: [16]u8,
    dst_mac: [6]u8,
) u16 {
    const icmp_len: u16 = 32;
    const total_payload: u16 = ipv6.HEADER_LEN + icmp_len;
    const icmp_off: u16 = 14 + ipv6.HEADER_LEN;
    fillNeighborSolicitationBody(out, icmp_off, target, our_mac);
    ipv6.buildHeader(out + 14, our_ip, dst_ip, ipv6.PROTO_ICMPV6, icmp_len);
    const csum = checksum(our_ip, dst_ip, out + icmp_off, icmp_len);
    bo.writeU16BeAt(out, icmp_off + 2, csum);
    return eth.buildFrame(out, dst_mac, our_mac, eth.ETHERTYPE_IPV6, total_payload);
}

/// Build a Neighbor Solicitation for `target` into `out`.
/// Destined to the solicited-node multicast of `target` (L3 + L2).
/// Pure: no ndp/netif/nic side effects. Returns ethernet frame length.
pub fn buildNeighborSolicitation(
    out: [*]u8,
    our_ip: [16]u8,
    target: [16]u8,
    our_mac: [6]u8,
) u16 {
    const dst_ip = ipv6.solicitedNodeMulticast(target);
    return buildNsFrame(out, our_ip, target, our_mac, dst_ip, ipv6.multicastMac(dst_ip));
}

/// Build a unicast Neighbor Solicitation (SK-81 NUD PROBE).
/// L3/L2 destined to the cached neighbor address/MAC.
pub fn buildNeighborSolicitationUnicast(
    out: [*]u8,
    our_ip: [16]u8,
    target: [16]u8,
    our_mac: [6]u8,
    dst_mac: [6]u8,
) u16 {
    return buildNsFrame(out, our_ip, target, our_mac, target, dst_mac);
}

/// Transmit an NS for `target` (ARP-request analogue). Caller usually
/// `markIncomplete` first; this only builds and sends the frame.
pub fn sendNeighborSolicitation(target: [16]u8) void {
    const our_mac = netif.getMac();
    const our_ip = ndp.generateLinkLocal(our_mac);
    var pkt: [128]u8 = @splat(0);
    const frame_len = buildNeighborSolicitation(&pkt, our_ip, target, our_mac);
    _ = nic.sendPacket(&pkt, frame_len);
}

/// Transmit a unicast NS for NUD PROBE (SK-81).
pub fn sendNeighborSolicitationUnicast(target: [16]u8, dst_mac: [6]u8) void {
    const our_mac = netif.getMac();
    const our_ip = ndp.generateLinkLocal(our_mac);
    var pkt: [128]u8 = @splat(0);
    const frame_len = buildNeighborSolicitationUnicast(&pkt, our_ip, target, our_mac, dst_mac);
    _ = nic.sendPacket(&pkt, frame_len);
}

/// Build a Router Solicitation to all-routers (ff02::2) with Source LL (SK-82).
/// Pure: no ndp/netif/nic side effects. Returns ethernet frame length.
pub fn buildRouterSolicitation(
    out: [*]u8,
    our_ip: [16]u8,
    our_mac: [6]u8,
) u16 {
    // ICMPv6 RS = 8-byte header + 8-byte Source LL = 16 bytes
    const icmp_len: u16 = 16;
    const total_payload: u16 = ipv6.HEADER_LEN + icmp_len;
    const icmp_off: u16 = 14 + ipv6.HEADER_LEN;
    const dst_ip = ipv6.allRoutersLinkLocalMulticast();
    const dst_mac = ipv6.multicastMac(dst_ip);

    out[icmp_off + 0] = ROUTER_SOLICITATION;
    out[icmp_off + 1] = 0; // code
    out[icmp_off + 2] = 0; // checksum
    out[icmp_off + 3] = 0;
    out[icmp_off + 4] = 0; // reserved
    out[icmp_off + 5] = 0;
    out[icmp_off + 6] = 0;
    out[icmp_off + 7] = 0;
    out[icmp_off + 8] = OPT_SOURCE_LL_ADDR;
    out[icmp_off + 9] = 1;
    @memcpy(out[icmp_off + 10 .. icmp_off + 16], &our_mac);

    ipv6.buildHeader(out + 14, our_ip, dst_ip, ipv6.PROTO_ICMPV6, icmp_len);
    const csum = checksum(our_ip, dst_ip, out + icmp_off, icmp_len);
    bo.writeU16BeAt(out, icmp_off + 2, csum);
    return eth.buildFrame(out, dst_mac, our_mac, eth.ETHERTYPE_IPV6, total_payload);
}

/// Transmit a Router Solicitation (SK-82).
pub fn sendRouterSolicitation() void {
    const our_mac = netif.getMac();
    const our_ip = ndp.generateLinkLocal(our_mac);
    var pkt: [128]u8 = @splat(0);
    const frame_len = buildRouterSolicitation(&pkt, our_ip, our_mac);
    _ = nic.sendPacket(&pkt, frame_len);
}

// ── SK-88: automatic Router Solicitation (RFC 4861 §6.3.7) ───────────────
/// MAX_RTR_SOLICITATIONS
pub const MAX_RTR_SOLICITATIONS: u8 = 3;
/// RTR_SOLICITATION_INTERVAL (ms)
pub const RTR_SOLICITATION_INTERVAL_MS: u32 = 4_000;

var rs_active: bool = false;
var rs_sent: u8 = 0;
var rs_ms: u32 = 0;

/// Begin router discovery: send the first RS immediately (SK-88).
pub fn startRouterSolicit() void {
    rs_active = true;
    rs_sent = 0;
    rs_ms = 0;
    sendRouterSolicitation();
    rs_sent = 1;
}

/// Stop router discovery early (e.g. after a usable RA) (SK-88).
pub fn stopRouterSolicit() void {
    rs_active = false;
}

/// Probe helper (SK-88).
pub fn probeRsActive() bool {
    return rs_active;
}

/// Probe helper (SK-88): RS transmissions in the current discovery round.
pub fn probeRsSent() u8 {
    return rs_sent;
}

/// Advance RS retransmit timer (SK-88). Stops when a default router appears
/// or `MAX_RTR_SOLICITATIONS` have been sent.
pub fn routerSolicitTimerTick(ms_elapsed: u32) void {
    if (!rs_active) return;
    if (ndp.getDefaultRouter() != null) {
        rs_active = false;
        return;
    }
    if (rs_sent >= MAX_RTR_SOLICITATIONS) {
        rs_active = false;
        return;
    }
    if (ms_elapsed == 0) return;
    rs_ms +%= ms_elapsed;
    if (rs_ms < RTR_SOLICITATION_INTERVAL_MS) return;
    rs_ms = 0;
    sendRouterSolicitation();
    rs_sent +%= 1;
    if (rs_sent >= MAX_RTR_SOLICITATIONS) rs_active = false;
}

/// Build a DAD Neighbor Solicitation (RFC 4862 §5.4.2): src=::, no SLLA (SK-85).
pub fn buildDadNeighborSolicitation(out: [*]u8, target: [16]u8, our_mac: [6]u8) u16 {
    const icmp_len: u16 = 24; // header only — no Source LL option
    const total_payload: u16 = ipv6.HEADER_LEN + icmp_len;
    const icmp_off: u16 = 14 + ipv6.HEADER_LEN;
    const src_ip = [_]u8{0} ** 16;
    const dst_ip = ipv6.solicitedNodeMulticast(target);
    const dst_mac = ipv6.multicastMac(dst_ip);

    out[icmp_off + 0] = NEIGHBOR_SOLICITATION;
    out[icmp_off + 1] = 0;
    out[icmp_off + 2] = 0;
    out[icmp_off + 3] = 0;
    out[icmp_off + 4] = 0;
    out[icmp_off + 5] = 0;
    out[icmp_off + 6] = 0;
    out[icmp_off + 7] = 0;
    @memcpy(out[icmp_off + 8 .. icmp_off + 24], &target);

    ipv6.buildHeader(out + 14, src_ip, dst_ip, ipv6.PROTO_ICMPV6, icmp_len);
    const csum = checksum(src_ip, dst_ip, out + icmp_off, icmp_len);
    bo.writeU16BeAt(out, icmp_off + 2, csum);
    return eth.buildFrame(out, dst_mac, our_mac, eth.ETHERTYPE_IPV6, total_payload);
}

/// Transmit a DAD NS for a tentative address (SK-85).
pub fn sendDadNeighborSolicitation(target: [16]u8) void {
    const our_mac = netif.getMac();
    var pkt: [128]u8 = @splat(0);
    const frame_len = buildDadNeighborSolicitation(&pkt, target, our_mac);
    _ = nic.sendPacket(&pkt, frame_len);
}

/// Drive NDP NS retransmits / NUD probes / DAD / RS (SK-79/81/85/88).
pub fn neighborTimerTick(ms_elapsed: u32) void {
    var batch: [ndp.MAX_NEIGHBORS]ndp.Solicit = undefined;
    const n = ndp.timerTick(ms_elapsed, &batch);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (ndp.solicitIsMulticast(batch[i])) {
            sendNeighborSolicitation(batch[i].target);
        } else {
            sendNeighborSolicitationUnicast(batch[i].target, batch[i].dst_mac);
        }
    }
    var dad_batch: [ndp.MAX_LOCAL_ADDRS][16]u8 = undefined;
    const dn = ndp.dadTimerTick(ms_elapsed, &dad_batch);
    var di: u32 = 0;
    while (di < dn) : (di += 1) {
        sendDadNeighborSolicitation(dad_batch[di]);
    }
    routerSolicitTimerTick(ms_elapsed);
    // SK-89: expire default router; rediscover if lifetime hits zero.
    if (ndp.routerLifetimeTimerTick(ms_elapsed)) {
        startRouterSolicit();
    }
    // SK-90: expire on-link / SLAAC prefixes when Valid Lifetime hits zero.
    ndp.prefixLifetimeTimerTick(ms_elapsed);
    // SK-91: Preferred Lifetime → deprecate addresses for new TX.
    ndp.preferredLifetimeTimerTick(ms_elapsed);
    // SK-94: expire Route Information entries.
    ndp.routeLifetimeTimerTick(ms_elapsed);
    // SK-95: expire Destination Cache redirects.
    ndp.destCacheTimerTick(ms_elapsed);
    // SK-97: expire Path MTU entries.
    ipv6.pathMtuTimerTick(ms_elapsed);
    // SK-101: expire IPv4 Path MTU entries.
    ipv4.pathMtuTimerTick(ms_elapsed);
}
