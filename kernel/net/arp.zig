const e1000 = @import("../drivers/e1000.zig");
const netif = @import("netif.zig");
const eth = @import("eth.zig");

const MAX_ARP_ENTRIES: usize = 16;

const ArpEntry = struct {
    ip: [4]u8,
    mac: [6]u8,
    valid: bool,
};

var cache: [MAX_ARP_ENTRIES]ArpEntry = @splat(.{ .ip = @splat(0), .mac = @splat(0), .valid = false });

pub fn init() void {
    for (0..MAX_ARP_ENTRIES) |i| {
        cache[i].valid = false;
    }
}

pub fn handlePacket(data: [*]const u8, len: u32) void {
    if (len < 42) return;

    const htype = (@as(u16, data[14]) << 8) | @as(u16, data[15]);
    const ptype = (@as(u16, data[16]) << 8) | @as(u16, data[17]);
    const opcode = (@as(u16, data[20]) << 8) | @as(u16, data[21]);

    if (htype != 1 or ptype != 0x0800) return;

    const sender_mac: [6]u8 = .{ data[22], data[23], data[24], data[25], data[26], data[27] };
    const sender_ip: [4]u8 = .{ data[28], data[29], data[30], data[31] };
    const target_ip: [4]u8 = .{ data[38], data[39], data[40], data[41] };

    // Cache sender's MAC regardless
    addToCache(sender_ip, sender_mac);

    if (opcode == 1) {
        // ARP request — is it for our IP?
        const our_ip = netif.getOurIp();
        if (target_ip[0] == our_ip[0] and target_ip[1] == our_ip[1] and
            target_ip[2] == our_ip[2] and target_ip[3] == our_ip[3])
        {
            sendArpReply(sender_ip, sender_mac);
        }
    }
}

pub fn resolve(ip: [4]u8) ?[6]u8 {
    for (0..MAX_ARP_ENTRIES) |i| {
        if (cache[i].valid and
            cache[i].ip[0] == ip[0] and cache[i].ip[1] == ip[1] and
            cache[i].ip[2] == ip[2] and cache[i].ip[3] == ip[3])
        {
            return cache[i].mac;
        }
    }
    return null;
}

pub fn sendArpRequest(target_ip: [4]u8) void {
    var pkt: [64]u8 = @splat(0);
    const our_mac = netif.getMac();
    const our_ip = netif.getOurIp();

    // Ethernet header: broadcast
    for (0..6) |i| pkt[i] = 0xFF;
    @memcpy(pkt[6..12], &our_mac);
    pkt[12] = 0x08;
    pkt[13] = 0x06; // Ethertype ARP

    // ARP payload
    pkt[14] = 0x00; pkt[15] = 0x01; // HTYPE=Ethernet
    pkt[16] = 0x08; pkt[17] = 0x00; // PTYPE=IPv4
    pkt[18] = 6; // HLEN
    pkt[19] = 4; // PLEN
    pkt[20] = 0x00; pkt[21] = 0x01; // Opcode=request
    @memcpy(pkt[22..28], &our_mac);
    @memcpy(pkt[28..32], &our_ip);
    for (32..38) |i| pkt[i] = 0; // Target MAC = 0
    @memcpy(pkt[38..42], &target_ip);

    _ = e1000.sendPacket(&pkt, 42);
}

fn addToCache(ip: [4]u8, mac: [6]u8) void {
    // Update existing entry
    for (0..MAX_ARP_ENTRIES) |i| {
        if (cache[i].valid and
            cache[i].ip[0] == ip[0] and cache[i].ip[1] == ip[1] and
            cache[i].ip[2] == ip[2] and cache[i].ip[3] == ip[3])
        {
            cache[i].mac = mac;
            return;
        }
    }
    // Add new entry
    for (0..MAX_ARP_ENTRIES) |i| {
        if (!cache[i].valid) {
            cache[i] = .{ .ip = ip, .mac = mac, .valid = true };
            return;
        }
    }
}

fn sendArpReply(target_ip: [4]u8, target_mac: [6]u8) void {
    var pkt: [64]u8 = @splat(0);
    const our_mac = netif.getMac();
    const our_ip = netif.getOurIp();

    @memcpy(pkt[0..6], &target_mac);
    @memcpy(pkt[6..12], &our_mac);
    pkt[12] = 0x08;
    pkt[13] = 0x06;

    pkt[14] = 0x00; pkt[15] = 0x01;
    pkt[16] = 0x08; pkt[17] = 0x00;
    pkt[18] = 6;
    pkt[19] = 4;
    pkt[20] = 0x00; pkt[21] = 0x02; // Opcode=reply
    @memcpy(pkt[22..28], &our_mac);
    @memcpy(pkt[28..32], &our_ip);
    @memcpy(pkt[32..38], &target_mac);
    @memcpy(pkt[38..42], &target_ip);

    _ = e1000.sendPacket(&pkt, 42);
}
