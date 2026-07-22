const nic = @import("nic.zig");
const netif = @import("netif.zig");
const eth = @import("eth.zig");
const ipv4 = @import("ipv4.zig");
const ipv6 = @import("ipv6.zig");
const arp = @import("arp.zig");
const ndp = @import("ndp.zig");
const icmpv6 = @import("icmpv6.zig");
const udp_util = @import("udp_util.zig");
const bo = @import("../lib/byte_order.zig");

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

fn findPortIdx(port: u16) ?u16 {
    for (0..num_ports) |i| {
        if (ports[i] == port) return @intCast(i);
    }
    return null;
}

pub fn ensurePort(port: u16) u16 {
    if (findPortIdx(port)) |idx| return idx;
    if (num_ports >= MAX_PORTS) return 0xFFFF;
    const idx = num_ports;
    ports[idx] = port;
    num_ports += 1;
    return @intCast(idx);
}

fn enqueue(port_idx: u16, src_ip: [16]u8, src_port: u16, dst_port: u16, payload: []const u8, is_v6: bool) void {
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
}

pub fn handlePacket(src_ip: [4]u8, _: [4]u8, data: [*]const u8, len: u32) void {
    const hdr = udp_util.parseHeader(data, len) orelse return;
    const port_idx = findPortIdx(hdr.dst_port) orelse return;
    const actual_payload = @min(hdr.payload_len, @as(u16, MAX_UDP_PAYLOAD));
    if (8 + actual_payload > len) return;
    var ip16: [16]u8 = @splat(0);
    @memcpy(ip16[0..4], &src_ip);
    enqueue(port_idx, ip16, hdr.src_port, hdr.dst_port, data[8..][0..actual_payload], false);
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

    const port_idx = findPortIdx(hdr.dst_port) orelse return;
    const actual_payload = @min(hdr.payload_len, @as(u16, MAX_UDP_PAYLOAD_V6));
    if (8 + actual_payload > len) return;
    enqueue(port_idx, src_ip, hdr.src_port, hdr.dst_port, data[8..][0..actual_payload], true);
}

pub fn recvFrom(port: u16, out_buf: [*]u8, out_src_ip: *[4]u8, out_src_port: *u16) i64 {
    const port_idx = findPortIdx(port) orelse return 0;

    for (0..QUEUE_DEPTH) |i| {
        const entry = &queues[port_idx][i];
        if (entry.valid and !entry.is_v6) {
            const n = entry.data_len;
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
    const port_idx = findPortIdx(port) orelse return 0;

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

var send_pkt: [1518]u8 = @splat(0);

pub fn sendTo(dst_ip: [4]u8, dst_port: u16, src_port: u16, data: [*]const u8, data_len: u16) bool {
    if (data_len > MAX_UDP_PAYLOAD) return false;

    const dst_mac = arp.resolve(dst_ip) orelse {
        arp.sendArpRequest(dst_ip);
        return false;
    };

    const our_mac = netif.getMac();
    const our_ip = netif.getOurIp();
    const udp_total: u16 = 8 + data_len;

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

    const ok = nic.sendPacket(&send_pkt, frame_len);
    return ok;
}

/// Send a UDP datagram over IPv6 (SK-70). Requires a resolved NDP neighbor.
pub fn sendToV6(dst_ip: [16]u8, dst_port: u16, src_port: u16, data: [*]const u8, data_len: u16) bool {
    if (data_len > MAX_UDP_PAYLOAD_V6) return false;

    const dst_mac = ndp.lookup(dst_ip) orelse {
        ndp.markIncomplete(dst_ip);
        icmpv6.sendNeighborSolicitation(dst_ip);
        return false;
    };

    const our_mac = netif.getMac();
    const our_ip = ndp.generateLinkLocal(our_mac);
    const udp_total: u16 = 8 + data_len;

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
    return nic.sendPacket(&send_pkt, frame_len);
}
