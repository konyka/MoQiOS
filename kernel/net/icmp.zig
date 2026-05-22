const e1000 = @import("../drivers/e1000.zig");
const netif = @import("netif.zig");
const eth = @import("eth.zig");
const ipv4 = @import("ipv4.zig");
const arp = @import("arp.zig");

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

        // ICMP payload: copy entire request (type, code, checksum, id, seq, data)
        const icmp_total = @min(len, @as(u16, 236));
        @memcpy(pkt[34..34 + icmp_total], data[0..icmp_total]);

        // Set type=0 (echo reply), code=0
        pkt[34] = 0;
        pkt[35] = 0;
        // Clear checksum
        pkt[36] = 0;
        pkt[37] = 0;
        // Recompute ICMP checksum
        const csum = ipv4.checksum(pkt[34..].ptr, icmp_total);
        pkt[36] = @intCast((csum >> 8) & 0xFF);
        pkt[37] = @intCast(csum & 0xFF);

        // IPv4 header at offset 14
        ipv4.buildHeader(pkt[14..].ptr, dst_ip, src_ip, ipv4.PROTO_ICMP, icmp_total);

        // Ethernet header at offset 0
        const frame_len = eth.buildFrame(&pkt, dst_mac, our_mac, eth.ETHERTYPE_IPV4, 20 + icmp_total);

        _ = e1000.sendPacket(&pkt, frame_len);
    }
}
