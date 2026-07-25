const nic = @import("nic.zig");
const udp_mod = @import("udp.zig");
const net_mod = @import("mod.zig");
const copy = @import("../mm/copy_from_user.zig");

/// Raw network send (MoQiOS-specific)
pub fn netSend(buf: u64, len: u64) i64 {
    if (buf == 0 or len == 0 or len > 2048 or buf >= 0x0000_8000_0000_0000) return -22;
    if (!nic.isActive()) return -1;
    var packet: [2048]u8 = undefined;
    if (copy.copyFromUser(packet[0..@intCast(len)], @ptrFromInt(buf), @intCast(len)) != len) return -14;
    if (nic.sendPacket(&packet, @intCast(len))) {
        return @intCast(len);
    }
    return 0;
}

/// Raw network receive (MoQiOS-specific)
pub fn netRecv(buf: u64, max_len: u64) i64 {
    if (buf == 0 or max_len == 0 or buf >= 0x0000_8000_0000_0000) return -22;
    if (!nic.isActive()) return -1;
    const capacity: u32 = @intCast(@min(max_len, 2048));
    var packet: [2048]u8 = undefined;
    const received = nic.receivePacket(&packet, capacity);
    if (received > 0 and copy.copyToUser(@ptrFromInt(buf), packet[0..received], received) != received) return -14;
    return @intCast(received);
}

/// UDP send
pub fn udpSend(dst_ip_be: u32, dst_port: u16, src_port: u16, buf: u64, len: u64) i64 {
    if (buf == 0 or len == 0 or len > 1472 or buf >= 0x0000_8000_0000_0000) return -22;
    if (!nic.isActive()) return -1;

    const dst_ip: [4]u8 = .{
        @truncate(dst_ip_be >> 24),
        @truncate(dst_ip_be >> 16),
        @truncate(dst_ip_be >> 8),
        @truncate(dst_ip_be),
    };

    var payload: [1472]u8 = undefined;
    if (copy.copyFromUser(payload[0..@intCast(len)], @ptrFromInt(buf), @intCast(len)) != len) return -14;
    if (udp_mod.sendTo(dst_ip, dst_port, src_port, &payload, @intCast(len))) {
        return @intCast(len);
    }
    return 0;
}

/// UDP receive
pub fn udpRecv(port: u16, buf: u64, max_len: u64, src_ip_out: u64, src_port_out: u64) i64 {
    if (buf == 0 or max_len == 0 or buf >= 0x0000_8000_0000_0000) return -22;

    var out_ip: [4]u8 = @splat(0);
    var out_port: u16 = 0;

    const capacity: u16 = @intCast(@min(max_len, 1472));
    if (!copy.validateUserBuffer(buf, capacity)) return -14;
    if (src_ip_out != 0 and !copy.validateUserBuffer(src_ip_out, 4)) return -14;
    if (src_port_out != 0 and !copy.validateUserBuffer(src_port_out, 2)) return -14;
    var payload: [1472]u8 = undefined;
    const n = udp_mod.recvFrom(port, &payload, capacity, &out_ip, &out_port);

    if (n > 0) {
        if (copy.copyToUser(@ptrFromInt(buf), payload[0..@intCast(n)], @intCast(n)) != @as(usize, @intCast(n))) return -14;
        if (src_ip_out != 0 and src_ip_out < 0x0000_8000_0000_0000) {
            const ip_be: u32 = (@as(u32, out_ip[0]) << 24) |
                (@as(u32, out_ip[1]) << 16) |
                (@as(u32, out_ip[2]) << 8) |
                @as(u32, out_ip[3]);
            if (copy.copyToUser(@ptrFromInt(src_ip_out), @ptrCast(&ip_be), 4) != 4) return -14;
        }
        if (src_port_out != 0 and src_port_out < 0x0000_8000_0000_0000) {
            if (copy.copyToUser(@ptrFromInt(src_port_out), @ptrCast(&out_port), 2) != 2) return -14;
        }
    }

    return @bitCast(n);
}

/// Network poll — drain the active NIC's RX ring into the network stack
pub fn netPoll() i64 {
    if (!nic.isActive()) return 0;

    var rx_tmp: [2048]u8 = undefined;
    var count: u64 = 0;
    var poll_limit: u32 = 0;
    while (poll_limit < 16) {
        const n = nic.receivePacket(&rx_tmp, 2048);
        if (n == 0) break;
        net_mod.handleRxPacket(&rx_tmp, n);
        count += 1;
        poll_limit += 1;
    }
    return @intCast(count);
}
