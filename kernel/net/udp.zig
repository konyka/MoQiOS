const e1000 = @import("../drivers/e1000.zig");
const netif = @import("netif.zig");
const eth = @import("eth.zig");
const ipv4 = @import("ipv4.zig");
const arp = @import("arp.zig");

const MAX_PORTS = 16;
const QUEUE_DEPTH = 8;
const MAX_UDP_PAYLOAD = 1472;

const UdpEntry = struct {
    src_ip: [4]u8,
    src_port: u16,
    dst_port: u16,
    data_len: u16,
    data: [MAX_UDP_PAYLOAD]u8,
    valid: bool,
};

var ports: [MAX_PORTS]u16 = @splat(0);
var queues: [MAX_PORTS][QUEUE_DEPTH]UdpEntry = @splat(@splat(.{
    .src_ip = @splat(0),
    .src_port = 0,
    .dst_port = 0,
    .data_len = 0,
    .data = @splat(0),
    .valid = false,
}));
var num_ports: u16 = 0;

fn findPortIdx(port: u16) ?u16 {
    for (0..num_ports) |i| {
        if (ports[i] == port) return @intCast(i);
    }
    return null;
}

fn ensurePort(port: u16) u16 {
    if (findPortIdx(port)) |idx| return idx;
    if (num_ports >= MAX_PORTS) return 0xFFFF;
    const idx = num_ports;
    ports[idx] = port;
    num_ports += 1;
    return @intCast(idx);
}

pub fn handlePacket(src_ip: [4]u8, _: [4]u8, data: [*]const u8, len: u32) void {
    if (len < 8) return;

    const src_port = (@as(u16, data[0]) << 8) | @as(u16, data[1]);
    const dst_port = (@as(u16, data[2]) << 8) | @as(u16, data[3]);
    const udp_len = (@as(u16, data[4]) << 8) | @as(u16, data[5]);

    const payload_offset: u16 = 8;
    const payload_len = if (udp_len > 8) udp_len - 8 else 0;
    const actual_payload = @min(payload_len, @as(u16, MAX_UDP_PAYLOAD));

    const port_idx = ensurePort(dst_port);
    if (port_idx == 0xFFFF) return;

    for (0..QUEUE_DEPTH) |i| {
        if (!queues[port_idx][i].valid) {
            queues[port_idx][i].src_ip = src_ip;
            queues[port_idx][i].src_port = src_port;
            queues[port_idx][i].dst_port = dst_port;
            queues[port_idx][i].data_len = actual_payload;
            @memcpy(queues[port_idx][i].data[0..actual_payload], data[payload_offset..][0..actual_payload]);
            queues[port_idx][i].valid = true;
            return;
        }
    }
}

pub fn recvFrom(port: u16, out_buf: [*]u8, out_src_ip: *[4]u8, out_src_port: *u16) i64 {
    const port_idx = findPortIdx(port) orelse return 0;

    for (0..QUEUE_DEPTH) |i| {
        if (queues[port_idx][i].valid) {
            const entry = &queues[port_idx][i];
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
    send_pkt[34] = @intCast((src_port >> 8) & 0xFF);
    send_pkt[35] = @intCast(src_port & 0xFF);
    send_pkt[36] = @intCast((dst_port >> 8) & 0xFF);
    send_pkt[37] = @intCast(dst_port & 0xFF);
    send_pkt[38] = @intCast((udp_total >> 8) & 0xFF);
    send_pkt[39] = @intCast(udp_total & 0xFF);
    send_pkt[40] = 0x00;
    send_pkt[41] = 0x00;

    // Copy payload after UDP header
    @memcpy(send_pkt[42..42 + data_len], data[0..data_len]);

    // Build IPv4 header at offset 14 (after ethernet header)
    ipv4.buildHeader(send_pkt[14..].ptr, our_ip, dst_ip, ipv4.PROTO_UDP, udp_total);

    // Build ethernet frame
    const frame_len = eth.buildFrame(&send_pkt, dst_mac, our_mac, eth.ETHERTYPE_IPV4, 20 + udp_total);

    const ok = e1000.sendPacket(&send_pkt, frame_len);
    return ok;
}
