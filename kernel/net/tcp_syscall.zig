const net_mod = @import("mod.zig");

/// TCP connect — initiate a TCP connection
pub fn tcpConnect(ip_ptr: u64, port: u16) i64 {
    if (ip_ptr == 0 or ip_ptr >= 0x0000_8000_0000_0000) return -14;

    var ip: [4]u8 = undefined;
    const copy = @import("../mm/copy_from_user.zig");
    const n = copy.copyFromUser(&ip, @ptrFromInt(ip_ptr), 4);
    if (n < 4) return -14;

    const sched_mod = @import("../proc/sched.zig");
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;

    const result = net_mod.tcp.tcpConnect(ip, port, cur_idx);
    return @bitCast(result);
}

/// TCP send — send data on an established connection
pub fn tcpSend(tcb_idx: u32, buf: u64, len: u32) i64 {
    if (buf == 0 or buf >= 0x0000_8000_0000_0000 or len == 0) return -14;
    return net_mod.tcp.tcpSendFromUser(tcb_idx, buf, len);
}

/// TCP recv — receive data from an established connection
pub fn tcpRecv(tcb_idx: u32, buf: u64, len: u32) i64 {
    if (buf == 0 or buf >= 0x0000_8000_0000_0000 or len == 0) return -1;

    var tmp_buf: [4096]u8 = undefined;
    const to_read = @min(len, 4096);
    const copy = @import("../mm/copy_from_user.zig");
    if (!copy.validateUserBuffer(buf, to_read)) return -14; // EFAULT

    const result = net_mod.tcp.tcpRecv(tcb_idx, &tmp_buf, to_read);
    if (result > 0) {
        const copied = copy.copyToUser(@ptrFromInt(buf), &tmp_buf, @intCast(result));
        if (copied != @as(usize, @intCast(result))) return -14; // EFAULT
    }
    return @bitCast(result);
}

/// TCP close — close an established connection
pub fn tcpClose(tcb_idx: u32) i64 {
    const result = net_mod.tcp.tcpClose(tcb_idx);
    return @bitCast(result);
}

/// TCP poll — check connection state
pub fn tcpPoll(tcb_idx: u32) i64 {
    const result = net_mod.tcp.tcpPoll(tcb_idx);
    return @bitCast(result);
}
