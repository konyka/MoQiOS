/// ioctl device control framework — terminal and generic device ioctls.
///
/// Provides the sysIoctl syscall handler that dispatches based on command.
/// Terminal ioctls (TCGETS, TIOCGWINSZ, etc.) operate on a default terminal
/// state. FIONREAD and FIONBIO operate on fd-level state.

const std = @import("std");
const copy = @import("../mm/copy_from_user.zig");
const task_mod = @import("../proc/task.zig");
const sched = @import("../proc/sched.zig");
const vfs = @import("vfs.zig");
const pgrp = @import("../proc/pgrp.zig");
const ip = @import("ioctl_policy.zig");

// ── Terminal ioctl command numbers (Linux x86_64 values) ──

pub const TCGETS = 0x5401; // Get terminal attributes
pub const TCSETS = 0x5402; // Set terminal attributes
pub const TIOCGWINSZ = 0x5413; // Get window size
pub const TIOCSWINSZ = 0x5414; // Set window size
pub const TIOCGPGRP = 0x540F; // Get foreground process group
pub const TIOCSPGRP = 0x5410; // Set foreground process group
pub const FIONREAD = 0x541B; // Get number of readable bytes
pub const SIOCOUTQNSD = 0x894B; // Bytes written to a TCP socket that have not been sent yet
pub const TIOCOUTQ = 0x5411; // Bytes sent on a socket that the peer has not consumed (SIOCOUTQ)
pub const FIONBIO = 0x5421; // Set/clear non-blocking mode

// ── Terminal data structures ──

pub const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

pub const Termios = extern struct {
    c_iflag: u32,
    c_oflag: u32,
    c_cflag: u32,
    c_lflag: u32,
    c_line: u8,
    c_cc: [19]u8,
};

// ── Default terminal state ──

var default_winsize: Winsize = .{
    .ws_row = 25,
    .ws_col = 80,
    .ws_xpixel = 0,
    .ws_ypixel = 0,
};

var default_termios: Termios = .{
    .c_iflag = 0x500, // ICRNL | IXON
    .c_oflag = 0x5, // OPOST | ONLCR
    .c_cflag = 0xBF, // CS8 | CREAD | HUPCL
    .c_lflag = 0x8A3B, // ECHO | ECHOE | ECHOK | ISIG | ICANON | IEXTEN | ECHOCTL | ECHOKE
    .c_line = 0,
    .c_cc = [_]u8{0} ** 19,
};

/// Foreground process group ID for the controlling terminal.
/// （作业控制 v1 起，真值统一由 kernel/proc/jobctl.zig 的 foreground_pgid 持有。）

/// Is this descriptor a terminal? The console (stdio specials) and /dev/tty.
fn targetOf(desc: *const vfs.FileDescriptor) ip.Target {
    return switch (desc.fd_type) {
        .special => .terminal,
        .devfs => if (desc.devfs_idx == @import("devfs_nodes.zig").ttyNodeIdx()) .terminal else .other,
        else => .other,
    };
}

const ifr = @import("../net/ifreq_policy.zig");

/// The interfaces this kernel has: the loopback device, plus eth0 once a NIC is up.
fn collectIfaces(out: *[ifr.MAX_IFACES]ifr.Iface) usize {
    const netif = @import("../net/netif.zig");
    const nic = @import("../net/nic.zig");
    var n: usize = 0;
    out[n] = .{
        .name = ifr.makeName("lo"),
        .index = 1,
        .flags = ifr.IFF_UP | ifr.IFF_LOOPBACK | ifr.IFF_RUNNING,
        .ip = .{ 127, 0, 0, 1 },
        .netmask = .{ 255, 0, 0, 0 },
        .mtu = 65536,
        .loopback = true,
    };
    n += 1;
    if (nic.isActive()) {
        out[n] = .{
            .name = ifr.makeName("eth0"),
            .index = 2,
            .flags = ifr.IFF_UP | ifr.IFF_BROADCAST | ifr.IFF_RUNNING | ifr.IFF_MULTICAST,
            .ip = netif.getOurIp(),
            .netmask = netif.getNetmask(),
            .mac = netif.getMac(),
            .mtu = netif.getMtu(),
        };
        n += 1;
    }
    return n;
}

fn netdeviceIoctl(cmd: u64, arg: u64) i64 {
    var ifs: [ifr.MAX_IFACES]ifr.Iface = undefined;
    const count = collectIfaces(&ifs);
    if (cmd == ifr.SIOCGIFCONF) return ifconf(ifs[0..count], arg);

    // The other requests take and return a struct ifreq.
    if (arg == 0 or arg >= 0x0000_8000_0000_0000) return -14;
    var req: [ifr.IFREQ_SIZE]u8 = undefined;
    if (copy.copyFromUser(&req, @ptrFromInt(arg), ifr.IFREQ_SIZE) != ifr.IFREQ_SIZE) return -14;
    const idx = if (cmd == ifr.SIOCGIFNAME)
        ifr.findByIndex(ifs[0..count], std.mem.readInt(u32, req[16..20], .little))
    else
        ifr.findByName(ifs[0..count], req[0..ifr.IFNAMSIZ]);
    const found = idx orelse return ifr.ENODEV;
    // The answer keeps the caller's name field; only SIOCGIFNAME rewrites it.
    const rc = ifr.answer(cmd, ifs[found], &req);
    if (rc != 0) return rc;
    if (copy.copyToUser(@ptrFromInt(arg), &req, ifr.IFREQ_SIZE) != ifr.IFREQ_SIZE) return -14;
    return 0;
}

/// SIOCGIFCONF: struct ifconf { int ifc_len; (pad) char *ifc_buf; }. Fills as
/// many ifreq records as ifc_buf holds and sets ifc_len to the bytes written;
/// a NULL ifc_buf asks only for the size needed.
fn ifconf(ifs: []const ifr.Iface, arg: u64) i64 {
    if (arg == 0 or arg >= 0x0000_8000_0000_0000) return -14;
    var hdr: [16]u8 = undefined;
    if (copy.copyFromUser(&hdr, @ptrFromInt(arg), 16) != 16) return -14;
    const len_in = std.mem.readInt(i32, hdr[0..4], .little);
    const buf_ptr = std.mem.readInt(u64, hdr[8..16], .little);
    if (len_in < 0) return -22;
    var written: usize = 0;
    if (buf_ptr == 0) {
        written = ifr.confSize(ifs.len);
    } else {
        if (buf_ptr >= 0x0000_8000_0000_0000) return -14;
        const fit = ifr.confFit(ifs.len, @intCast(len_in));
        var rec: [ifr.IFREQ_SIZE]u8 = undefined;
        for (ifs[0..fit], 0..) |i, k| {
            ifr.confRecord(i, &rec);
            if (copy.copyToUser(@ptrFromInt(buf_ptr + k * ifr.IFREQ_SIZE), &rec, ifr.IFREQ_SIZE) != ifr.IFREQ_SIZE) return -14;
        }
        written = fit * ifr.IFREQ_SIZE;
    }
    std.mem.writeInt(i32, hdr[0..4], @intCast(written), .little);
    if (copy.copyToUser(@ptrFromInt(arg), hdr[0..4], 4) != 4) return -14;
    return 0;
}

/// sysIoctl(fd, cmd, arg) → 0 on success, negative errno on failure
pub fn sysIoctl(fd: u64, cmd: u64, arg: u64) i64 {
    // Validate fd range
    if (fd >= vfs.MAX_FDS) return -9; // EBADF
    const cur_idx0 = sched.currentTaskIndex() orelse return -3;
    const cur0 = task_mod.getTask(cur_idx0) orelse return -3;
    const desc0 = &cur0.fd_table.fds[@intCast(fd)];
    if (desc0.fd_type == .none) return -9; // EBADF
    const rc_tty = ip.terminalCheck(cmd, targetOf(desc0));
    if (rc_tty != 0) return rc_tty;

    switch (cmd) {
        TIOCGWINSZ => {
            if (arg == 0 or arg >= 0x0000_8000_0000_0000) return -14; // EFAULT
            const ws_bytes: [*]const u8 = @ptrCast(&default_winsize);
            if (copy.copyToUser(@ptrFromInt(arg), ws_bytes[0..@sizeOf(Winsize)], @sizeOf(Winsize)) != @sizeOf(Winsize)) return -14;
            return 0;
        },
        TIOCSWINSZ => {
            if (arg == 0 or arg >= 0x0000_8000_0000_0000) return -14;
            var ws: Winsize = undefined;
            const ws_bytes: [*]u8 = @ptrCast(&ws);
            const copied = copy.copyFromUser(ws_bytes[0..@sizeOf(Winsize)], @ptrFromInt(arg), @sizeOf(Winsize));
            if (copied < @sizeOf(Winsize)) return -14;
            default_winsize = ws;
            return 0;
        },
        TCGETS => {
            if (arg == 0 or arg >= 0x0000_8000_0000_0000) return -14;
            const t_bytes: [*]const u8 = @ptrCast(&default_termios);
            if (copy.copyToUser(@ptrFromInt(arg), t_bytes[0..@sizeOf(Termios)], @sizeOf(Termios)) != @sizeOf(Termios)) return -14;
            return 0;
        },
        TCSETS => {
            if (arg == 0 or arg >= 0x0000_8000_0000_0000) return -14;
            var t: Termios = undefined;
            const t_bytes: [*]u8 = @ptrCast(&t);
            const copied = copy.copyFromUser(t_bytes[0..@sizeOf(Termios)], @ptrFromInt(arg), @sizeOf(Termios));
            if (copied < @sizeOf(Termios)) return -14;
            default_termios = t;
            return 0;
        },
        TIOCGPGRP => {
            if (arg == 0 or arg >= 0x0000_8000_0000_0000) return -14;
            const jc = @import("../proc/jobctl.zig");
            var pgid: u16 = jc.foreground_pgid;
            if (pgid == 0) {
                // If no fg group set, use current process's pgid
                const cur_idx = sched.currentTaskIndex() orelse return -3;
                const cur = task_mod.getTask(cur_idx) orelse return -3;
                pgid = cur.pgid;
            }
            const pid_t_val: u32 = pgid;
            const pgid_bytes: [*]const u8 = @ptrCast(&pid_t_val);
            if (copy.copyToUser(@ptrFromInt(arg), pgid_bytes[0..4], 4) != 4) return -14;
            return 0;
        },
        TIOCSPGRP => {
            if (arg == 0 or arg >= 0x0000_8000_0000_0000) return -14;
            var pid_t_val: i32 = undefined;
            const pgid_bytes: [*]u8 = @ptrCast(&pid_t_val);
            const copied = copy.copyFromUser(pgid_bytes[0..4], @ptrFromInt(arg), 4);
            if (copied < 4) return -14;
            if (pid_t_val < 0 or pid_t_val > 0xFFFF) return -22; // EINVAL
            const pgid: u16 = @intCast(pid_t_val);
            // 作业控制：只有控制终端的 owner 会话能设置前台组，且目标组必须
            // 属于该会话（kernel/proc/jobctl.zig 单一终端模型）。
            const jc = @import("../proc/jobctl.zig");
            const rc = jc.tcSetForegroundPgrp(pgid);
            if (rc != 0) return rc;
            return 0;
        },
        FIONREAD => {
            if (arg == 0 or arg >= 0x0000_8000_0000_0000) return -14;
            const cur_idx = sched.currentTaskIndex() orelse return -3;
            const cur = task_mod.getTask(cur_idx) orelse return -3;
            const fd_idx: u32 = if (fd > 0xFFFF_FFFF) 0xFFFF_FFFF else @intCast(fd);
            var nread: i32 = 0;

            if (fd_idx < vfs.MAX_FDS) {
                const desc = cur.fd_table.fds[fd_idx];
                if (desc.fd_type == .none) return -9; // EBADF

                switch (desc.fd_type) {
                    .pipe_read => {
                        if (vfs.pipeState(desc.pipe_idx)) |state| nread = @intCast(state.readable);
                    },
                    .tcp_socket => {
                        const tcp_mod = @import("../net/tcp.zig");
                        nread = @intCast(tcp_mod.tcpRecvAvailable(desc.tcb_idx));
                    },
                    .udp_socket => {
                        // Linux: size of the next pending datagram, not the queue total.
                        const udp_mod = @import("../net/udp.zig");
                        nread = @intCast(udp_mod.nextDatagramLen(desc.udp_port, desc.udp_is_v6));
                    },
                    .unix_socket => {
                        const unix_mod = @import("../net/unix_socket.zig");
                        nread = @intCast(unix_mod.unixReadable(desc.unix_sock_idx));
                    },
                    // Regular files: the bytes between the offset and the end.
                    .ramdisk_file, .fat32_file, .ext2_file, .tmpfs_file, .rofs_file => {
                        vfs.syncOffsetIn(&cur.fd_table.fds[fd_idx]);
                        nread = @intCast(ip.fileReadable(desc.file_size, cur.fd_table.fds[fd_idx].offset));
                    },
                    // Other fd types have no readable-byte count to report.
                    else => {},
                }
            }

            const nr_bytes: [*]const u8 = @ptrCast(&nread);
            if (copy.copyToUser(@ptrFromInt(arg), nr_bytes[0..4], 4) != 4) return -14;
            return 0;
        },
        TIOCOUTQ => {
            // SIOCOUTQ: sockets answer with the data still queued toward the
            // peer; every other descriptor is not a socket (ENOTTY).
            if (arg == 0 or arg >= 0x0000_8000_0000_0000) return -14;
            const desc = &cur0.fd_table.fds[@intCast(fd)];
            const queued: u32 = switch (desc.fd_type) {
                .tcp_socket => @import("../net/tcp.zig").tcpSendQueued(desc.tcb_idx),
                .unix_socket => @import("../net/unix_socket.zig").unixSendQueued(desc.unix_sock_idx),
                .udp_socket => 0,
                else => return -25, // ENOTTY
            };
            const v: i32 = @intCast(@min(queued, 0x7FFF_FFFF));
            const v_bytes: [*]const u8 = @ptrCast(&v);
            if (copy.copyToUser(@ptrFromInt(arg), v_bytes[0..4], 4) != 4) return -14;
            return 0;
        },
        SIOCOUTQNSD => {
            // Only TCP keeps a send cursor; Linux answers ENOTTY for every other descriptor, sockets of other families included.
            if (arg == 0 or arg >= 0x0000_8000_0000_0000) return -14;
            const desc = &cur0.fd_table.fds[@intCast(fd)];
            if (desc.fd_type != .tcp_socket) return -25; // ENOTTY
            const v: i32 = @intCast(@min(@import("../net/tcp.zig").tcpSendUnsent(desc.tcb_idx), 0x7FFF_FFFF));
            const v_bytes: [*]const u8 = @ptrCast(&v);
            if (copy.copyToUser(@ptrFromInt(arg), v_bytes[0..4], 4) != 4) return -14;
            return 0;
        },
        ifr.SIOCGIFNAME, ifr.SIOCGIFCONF, ifr.SIOCGIFFLAGS, ifr.SIOCGIFADDR, ifr.SIOCGIFBRDADDR, ifr.SIOCGIFNETMASK, ifr.SIOCGIFMTU, ifr.SIOCGIFHWADDR, ifr.SIOCGIFINDEX => {
            // netdevice(7): only meaningful on a socket.
            switch (desc0.fd_type) {
                .tcp_socket, .udp_socket, .unix_socket, .raw_socket => {},
                else => return -25, // ENOTTY
            }
            return netdeviceIoctl(cmd, arg);
        },
        FIONBIO => {
            if (arg == 0 or arg >= 0x0000_8000_0000_0000) return -14;
            const cur_idx = sched.currentTaskIndex() orelse return -3;
            const cur = task_mod.getTask(cur_idx) orelse return -3;
            const fd_idx: u32 = if (fd > 0xFFFF_FFFF) 0xFFFF_FFFF else @intCast(fd);

            if (fd_idx >= vfs.MAX_FDS) return -9;
            if (cur.fd_table.fds[fd_idx].fd_type == .none) return -9;

            // Read the int argument from user space
            var nonblock: i32 = undefined;
            const nb_bytes: [*]u8 = @ptrCast(&nonblock);
            const copied = copy.copyFromUser(nb_bytes[0..4], @ptrFromInt(arg), 4);
            if (copied < 4) return -14;

            if (nonblock != 0) {
                cur.fd_table.fds[fd_idx].status_flags |= 0x800; // O_NONBLOCK
            } else {
                cur.fd_table.fds[fd_idx].status_flags &= ~@as(u32, 0x800);
            }
            return 0;
        },
        ip.FIOCLEX, ip.FIONCLEX => {
            const fd_idx: u32 = @intCast(fd);
            if (cmd == ip.FIOCLEX) {
                cur0.fd_table.fds[fd_idx].fd_flags |= 1; // FD_CLOEXEC
            } else {
                cur0.fd_table.fds[fd_idx].fd_flags &= ~@as(u32, 1);
            }
            return 0;
        },
        else => return -25, // ENOTTY
    }
}
