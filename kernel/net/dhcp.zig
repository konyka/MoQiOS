/// DHCP Client — Dynamic Host Configuration Protocol.
///
/// Implements DHCP DISCOVER → OFFER → REQUEST → ACK four-way handshake
/// over UDP ports 67 (server) / 68 (client).
///
/// After successful handshake, configures:
///   - IP address (yiaddr)
///   - Subnet mask (Option 1)
///   - Default gateway / router (Option 3)
///   - DNS server (Option 6)
///   - Lease time (Option 51)
///
/// Updates netif.zig with the acquired configuration.
const serial = @import("../arch/arch.zig").serial;
const cpu = @import("../arch/arch.zig").cpu;
const udp = @import("udp.zig");
const netif = @import("netif.zig");
const idt = @import("../arch/arch.zig").interrupts;
const fmt = @import("../lib/fmt.zig");
const bo = @import("../lib/byte_order.zig");

// DHCP ports
const DHCP_SERVER_PORT: u16 = 67;
const DHCP_CLIENT_PORT: u16 = 68;

// DHCP message types (Option 53)
const DHCPDISCOVER: u8 = 1;
const DHCPOFFER: u8 = 2;
const DHCPREQUEST: u8 = 3;
const DHCPACK: u8 = 5;
const DHCPNACK: u8 = 6;

// DHCP options
const OPT_SUBNET_MASK: u8 = 1;
const OPT_ROUTER: u8 = 3;
const OPT_DNS_SERVER: u8 = 6;
const OPT_MSG_TYPE: u8 = 53;
const OPT_SERVER_ID: u8 = 54;
const OPT_REQ_IP: u8 = 50;
const OPT_LEASE_TIME: u8 = 51;
const OPT_END: u8 = 255;

// DHCP Magic Cookie
const DHCP_MAGIC: u32 = 0x63825363;

/// DHCP packet structure (576 bytes max, but typically ~300)
const DhcpPacket = extern struct {
    op: u8, // 1=BOOTREQUEST, 2=BOOTREPLY
    htype: u8, // Hardware type (1=Ethernet)
    hlen: u8, // Hardware address length (6 for Ethernet)
    hops: u8,
    xid: u32, // Transaction ID
    secs: u16,
    flags: u16,
    ciaddr: [4]u8, // Client IP
    yiaddr: [4]u8, // Your IP (offered)
    siaddr: [4]u8, // Server IP
    giaddr: [4]u8, // Gateway IP
    chaddr: [16]u8, // Client hardware address
    sname: [64]u8, // Server name
    file: [128]u8, // Boot filename
    magic: u32, // DHCP magic cookie
    options: [312]u8, // Options
};

var our_xid: u32 = 0;
var dhcp_configured: bool = false;

/// Backstop iteration bound for the OFFER/ACK poll loops. getTickCount only
/// advances once timer IRQs are enabled, which happens late in boot — so a
/// tick-only deadline never expires when discover() runs early (boot-time
/// DHCP, see kernel/main.zig). The cap keeps every wait bounded regardless;
/// with ticks live the 500-tick (~5s) deadline fires first.
const MAX_POLL_ITERS: u32 = 5_000_000;

// Acquired configuration
var dhcp_ip: [4]u8 = .{ 0, 0, 0, 0 };
var dhcp_netmask: [4]u8 = .{ 255, 255, 255, 0 };
var dhcp_gateway: [4]u8 = .{ 0, 0, 0, 0 };
var dhcp_dns: [4]u8 = .{ 0, 0, 0, 0 };
var dhcp_lease_time: u32 = 0;
var dhcp_server_id: [4]u8 = .{ 0, 0, 0, 0 };

pub fn isConfigured() bool {
    return dhcp_configured;
}

pub fn getDnsServer() [4]u8 {
    return dhcp_dns;
}

/// Drain pending NIC RX frames into the network stack so OFFER/ACK replies
/// reach the UDP queue (mirrors the netPoll loop in socket_syscall.zig).
fn pumpRx() void {
    const nic = @import("nic.zig");
    if (!nic.isActive()) return;
    const net_mod = @import("mod.zig");
    var rx_tmp: [2048]u8 = undefined;
    var poll_limit: u32 = 0;
    while (poll_limit < 16) {
        const n = nic.receivePacket(&rx_tmp, 2048);
        if (n == 0) break;
        net_mod.handleRxPacket(&rx_tmp, n);
        poll_limit += 1;
    }
}

/// Perform DHCP discover — sends DHCPDISCOVER and waits for DHCPOFFER.
/// Bounded: each wait exits on the 500-tick deadline or the MAX_POLL_ITERS
/// backstop, whichever comes first, so it is safe to call before timer IRQs
/// are enabled (boot-time DHCP). Returns true once the lease is applied.
pub fn discover() bool {
    serial.writeString("[dhcp] Starting DHCP discover...\n");

    // Register the client port first — without it the UDP demux drops
    // OFFER/ACK replies before recvFrom can ever see them.
    if (udp.ensurePort(DHCP_CLIENT_PORT) == 0xFFFF) {
        serial.writeString("[dhcp] Failed to register client port\n");
        return false;
    }
    defer udp.releasePort(DHCP_CLIENT_PORT);

    // Generate a transaction ID
    our_xid = @truncate(idt.getTickCount());

    // Send DHCPDISCOVER
    if (!sendDiscover()) {
        serial.writeString("[dhcp] Failed to send DISCOVER\n");
        return false;
    }

    // Wait for DHCPOFFER (poll for up to 5 seconds, or MAX_POLL_ITERS
    // iterations as a backstop when the tick counter is not advancing yet)
    const start = idt.getTickCount();
    var offer_iters: u32 = 0;
    while (idt.getTickCount() - start < 500 and offer_iters < MAX_POLL_ITERS) : (offer_iters += 1) {
        pumpRx();
        if (receiveOffer()) {
            serial.writeString("[dhcp] Received OFFER\n");
            // Send DHCPREQUEST
            if (!sendRequest()) {
                serial.writeString("[dhcp] Failed to send REQUEST\n");
                return false;
            }
            // Wait for DHCPACK (same bounded scheme as the OFFER wait)
            const req_start = idt.getTickCount();
            var ack_iters: u32 = 0;
            while (idt.getTickCount() - req_start < 500 and ack_iters < MAX_POLL_ITERS) : (ack_iters += 1) {
                pumpRx();
                if (receiveAck()) {
                    applyConfig();
                    return true;
                }
                cpu.pause();
            }
            serial.writeString("[dhcp] No ACK received\n");
            return false;
        }
        cpu.pause();
    }

    serial.writeString("[dhcp] No OFFER received\n");
    return false;
}

fn sendDiscover() bool {
    var pkt: DhcpPacket = undefined;
    const bytes: [*]u8 = @ptrCast(&pkt);
    @memset(bytes[0..@sizeOf(DhcpPacket)], 0);

    pkt.op = 1; // BOOTREQUEST
    pkt.htype = 1; // Ethernet
    pkt.hlen = 6;
    pkt.xid = bo.bswapU32(our_xid);
    pkt.flags = 0x0000; // No broadcast flag needed in QEMU
    pkt.magic = bo.bswapU32(DHCP_MAGIC);

    // Fill client hardware address
    const mac = netif.getMac();
    for (0..6) |i| {
        pkt.chaddr[i] = mac[i];
    }

    // Options: DHCP Message Type = DISCOVER
    var opt_idx: usize = 0;
    opt_idx += addOption(pkt.options[opt_idx..], OPT_MSG_TYPE, &.{DHCPDISCOVER});
    // Option: Parameter Request List
    opt_idx += addOption(pkt.options[opt_idx..], 55, &.{ 1, 3, 6, 51 }); // subnet, router, dns, lease
    pkt.options[opt_idx] = OPT_END;
    opt_idx += 1;

    const send_len: u16 = @intCast(@offsetOf(DhcpPacket, "options") + opt_idx);
    return sendDhcpPacket(&pkt, send_len);
}

fn sendRequest() bool {
    var pkt: DhcpPacket = undefined;
    const bytes: [*]u8 = @ptrCast(&pkt);
    @memset(bytes[0..@sizeOf(DhcpPacket)], 0);

    pkt.op = 1;
    pkt.htype = 1;
    pkt.hlen = 6;
    pkt.xid = bo.bswapU32(our_xid);
    pkt.magic = bo.bswapU32(DHCP_MAGIC);

    const mac = netif.getMac();
    for (0..6) |i| {
        pkt.chaddr[i] = mac[i];
    }

    var opt_idx: usize = 0;
    opt_idx += addOption(pkt.options[opt_idx..], OPT_MSG_TYPE, &.{DHCPREQUEST});
    // Request the offered IP
    opt_idx += addOption(pkt.options[opt_idx..], OPT_REQ_IP, &dhcp_ip);
    // Identify the server
    opt_idx += addOption(pkt.options[opt_idx..], OPT_SERVER_ID, &dhcp_server_id);
    pkt.options[opt_idx] = OPT_END;
    opt_idx += 1;

    const send_len: u16 = @intCast(@offsetOf(DhcpPacket, "options") + opt_idx);
    return sendDhcpPacket(&pkt, send_len);
}

fn receiveOffer() bool {
    var buf: [576]u8 align(@alignOf(DhcpPacket)) = @splat(0);
    var src_ip: [4]u8 = .{ 0, 0, 0, 0 };
    var src_port: u16 = 0;

    const n = udp.recvFrom(DHCP_CLIENT_PORT, &buf, @intCast(buf.len), &src_ip, &src_port);
    if (n <= 0) return false;
    if (src_port != DHCP_SERVER_PORT) return false;

    // Parse DHCP packet
    if (n < @as(i64, @sizeOf(DhcpPacket) - 312)) return false; // At least header + some options
    const pkt: *const DhcpPacket = @ptrCast(@as(*const DhcpPacket, @ptrFromInt(@intFromPtr(&buf))));

    if (bo.bswapU32(pkt.magic) != DHCP_MAGIC) return false;
    if (bo.bswapU32(pkt.xid) != our_xid) return false;

    // Check message type
    var msg_type: u8 = 0;
    parseOptions(pkt, &msg_type);

    if (msg_type != DHCPOFFER) return false;

    // Store offered IP
    dhcp_ip = pkt.yiaddr;
    dhcp_server_id = pkt.siaddr;

    serial.writeString("[dhcp] Offered IP: ");
    printIp(dhcp_ip);
    serial.writeString(" from server: ");
    printIp(dhcp_server_id);
    serial.writeString("\n");

    return true;
}

fn receiveAck() bool {
    var buf: [576]u8 align(@alignOf(DhcpPacket)) = @splat(0);
    var src_ip: [4]u8 = .{ 0, 0, 0, 0 };
    var src_port: u16 = 0;

    const n = udp.recvFrom(DHCP_CLIENT_PORT, &buf, @intCast(buf.len), &src_ip, &src_port);
    if (n <= 0) return false;
    if (src_port != DHCP_SERVER_PORT) return false;

    if (n < @as(i64, @sizeOf(DhcpPacket) - 312)) return false;
    const pkt: *const DhcpPacket = @ptrCast(@as(*const DhcpPacket, @ptrFromInt(@intFromPtr(&buf))));

    if (bo.bswapU32(pkt.magic) != DHCP_MAGIC) return false;
    if (bo.bswapU32(pkt.xid) != our_xid) return false;

    var msg_type: u8 = 0;
    parseOptions(pkt, &msg_type);

    if (msg_type == DHCPNACK) {
        serial.writeString("[dhcp] Received NACK\n");
        return false;
    }
    if (msg_type != DHCPACK) return false;

    // Update IP (may differ from offer)
    dhcp_ip = pkt.yiaddr;

    return true;
}

fn parseOptions(pkt: *const DhcpPacket, out_msg_type: *u8) void {
    var idx: usize = 0;
    const opts = pkt.options[0..312];

    while (idx < 312) {
        const opt_code = opts[idx];
        if (opt_code == OPT_END) break;
        if (opt_code == 0) { // Padding
            idx += 1;
            continue;
        }
        idx += 1;
        if (idx >= 312) break;
        const opt_len: usize = opts[idx];
        idx += 1;
        if (idx + opt_len > 312) break;

        switch (opt_code) {
            OPT_MSG_TYPE => {
                if (opt_len >= 1) out_msg_type.* = opts[idx];
            },
            OPT_SUBNET_MASK => {
                if (opt_len >= 4) {
                    dhcp_netmask[0] = opts[idx];
                    dhcp_netmask[1] = opts[idx + 1];
                    dhcp_netmask[2] = opts[idx + 2];
                    dhcp_netmask[3] = opts[idx + 3];
                }
            },
            OPT_ROUTER => {
                if (opt_len >= 4) {
                    dhcp_gateway[0] = opts[idx];
                    dhcp_gateway[1] = opts[idx + 1];
                    dhcp_gateway[2] = opts[idx + 2];
                    dhcp_gateway[3] = opts[idx + 3];
                }
            },
            OPT_DNS_SERVER => {
                if (opt_len >= 4) {
                    dhcp_dns[0] = opts[idx];
                    dhcp_dns[1] = opts[idx + 1];
                    dhcp_dns[2] = opts[idx + 2];
                    dhcp_dns[3] = opts[idx + 3];
                }
            },
            OPT_LEASE_TIME => {
                if (opt_len >= 4) {
                    dhcp_lease_time = bo.readU32BeAt(opts.ptr, idx);
                }
            },
            OPT_SERVER_ID => {
                if (opt_len >= 4) {
                    dhcp_server_id[0] = opts[idx];
                    dhcp_server_id[1] = opts[idx + 1];
                    dhcp_server_id[2] = opts[idx + 2];
                    dhcp_server_id[3] = opts[idx + 3];
                }
            },
            else => {},
        }
        idx += opt_len;
    }
}

fn applyConfig() void {
    // Update netif with acquired configuration
    // Note: We update the static values in netif.zig via functions below
    dhcp_configured = true;

    serial.writeString("[dhcp] Configured: IP=");
    printIp(dhcp_ip);
    serial.writeString(" netmask=");
    printIp(dhcp_netmask);
    serial.writeString(" gateway=");
    printIp(dhcp_gateway);
    serial.writeString(" dns=");
    printIp(dhcp_dns);
    serial.writeString(" lease=");
    fmt.writeDecimal(dhcp_lease_time);
    serial.writeString("s\n");
}

/// Get DHCP-acquired IP address.
pub fn getIp() [4]u8 {
    return dhcp_ip;
}

/// Get DHCP-acquired gateway.
pub fn getGateway() [4]u8 {
    return dhcp_gateway;
}

/// Get DHCP-acquired netmask.
pub fn getNetmask() [4]u8 {
    return dhcp_netmask;
}

/// Add a DHCP option to the options buffer. Returns bytes written.
fn addOption(buf: []u8, code: u8, data: []const u8) usize {
    if (data.len == 0) return 0;
    buf[0] = code;
    buf[1] = @intCast(data.len);
    for (0..data.len) |i| {
        buf[2 + i] = data[i];
    }
    return 2 + data.len;
}

fn sendDhcpPacket(pkt: *const DhcpPacket, len: u16) bool {
    const server_ip: [4]u8 = .{ 255, 255, 255, 255 }; // Broadcast
    const data: [*]const u8 = @ptrCast(pkt);
    return udp.sendTo(server_ip, DHCP_SERVER_PORT, DHCP_CLIENT_PORT, data, len);
}

fn printIp(ip: [4]u8) void {
    fmt.writeDecimal(ip[0]);
    serial.writeString(".");
    fmt.writeDecimal(ip[1]);
    serial.writeString(".");
    fmt.writeDecimal(ip[2]);
    serial.writeString(".");
    fmt.writeDecimal(ip[3]);
}
