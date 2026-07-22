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
const ndp = @import("ndp.zig");
const bo = @import("../lib/byte_order.zig");

// ── ICMPv6 message types (RFC 4443 + RFC 4861) ─────────────────────────────
pub const ECHO_REQUEST: u8 = 128;
pub const ECHO_REPLY: u8 = 129;
pub const ROUTER_SOLICITATION: u8 = 133;
pub const ROUTER_ADVERTISEMENT: u8 = 134;
pub const NEIGHBOR_SOLICITATION: u8 = 135;
pub const NEIGHBOR_ADVERTISEMENT: u8 = 136;

// NDP option types
const OPT_SOURCE_LL_ADDR: u8 = 1;
const OPT_TARGET_LL_ADDR: u8 = 2;

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
    sum +|= @as(u32, @truncate(acc >> 32));
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
        NEIGHBOR_SOLICITATION => handleNeighborSolicitation(src_ip, dst_ip, data, len),
        NEIGHBOR_ADVERTISEMENT => handleNeighborAdvertisement(src_ip, data, len),
        else => {},
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

    // Only respond if the target is one of our addresses.
    const our_mac = netif.getMac();
    const our_ll = ndp.generateLinkLocal(our_mac);
    if (!ipv6.addrEq(target, our_ll)) return;

    sendNeighborAdvertisement(src_ip, target, true); // v53.37: solicited NA — set S flag (W1 fix, RFC 4861 §7.2.4)
}

fn handleNeighborAdvertisement(src_ip: [16]u8, data: [*]const u8, len: u16) void {
    // NA layout: type(1)+code(1)+csum(2)+flags(4)+target(16)+options
    if (len < 24) return;
    _ = src_ip;

    var target: [16]u8 = undefined;
    inline for (0..16) |i| target[i] = data[8 + i];

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

/// Drive NDP NS retransmits / NUD probes (SK-79/81). Called from the
/// scheduler maintenance pass alongside `tcp.timerTick`.
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
}
