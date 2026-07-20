const nic = @import("nic.zig");
const netif = @import("netif.zig");
const eth = @import("eth.zig");
const ipv4 = @import("ipv4.zig");
const arp = @import("arp.zig");
const bo = @import("../lib/byte_order.zig");

/// Build an ICMP echo reply frame into `out` from an echo `req` of `req_len`
/// bytes. Pure: no ARP/NIC side effects, so it is arch-clean and testable in
/// isolation. `reply_src_ip`/`reply_src_mac` are ours; `reply_dst_*` are the
/// requester's. Returns the total ethernet frame length.
pub fn buildEchoReply(
    out: [*]u8,
    req: [*]const u8,
    req_len: u32,
    reply_src_ip: [4]u8,
    reply_dst_ip: [4]u8,
    reply_src_mac: [6]u8,
    reply_dst_mac: [6]u8,
) u16 {
    // ICMP message: copy the request (type, code, checksum, id, seq, data).
    const icmp_total: u16 = @intCast(@min(req_len, @as(u32, 236)));
    @memcpy(out[34..][0..icmp_total], req[0..icmp_total]);

    // Type=0 (echo reply), code=0, clear + recompute checksum.
    out[34] = 0;
    out[35] = 0;
    out[36] = 0;
    out[37] = 0;
    const csum = ipv4.checksum(out + 34, icmp_total);
    bo.writeU16BeAt(out, 36, csum);

    // IPv4 header at offset 14, ethernet frame at offset 0.
    ipv4.buildHeader(out + 14, reply_src_ip, reply_dst_ip, ipv4.PROTO_ICMP, icmp_total);
    return eth.buildFrame(out, reply_dst_mac, reply_src_mac, eth.ETHERTYPE_IPV4, 20 + icmp_total);
}

pub fn handlePacket(src_ip: [4]u8, dst_ip: [4]u8, data: [*]const u8, len: u32) void {
    if (len < 8) return;

    const icmp_type = data[0];
    const icmp_code = data[1];

    if (icmp_type == 8 and icmp_code == 0) {
        // Echo request → send echo reply
        const our_mac = netif.getMac();

        // Resolve MAC for the sender
        const dst_mac = arp.resolve(src_ip) orelse {
            arp.sendArpRequest(src_ip);
            return;
        };

        var pkt: [256]u8 = undefined;
        const frame_len = buildEchoReply(&pkt, data, len, dst_ip, src_ip, our_mac, dst_mac);
        _ = nic.sendPacket(&pkt, frame_len);
    }
}
