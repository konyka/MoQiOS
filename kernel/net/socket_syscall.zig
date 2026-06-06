// kernel/net/socket_syscall.zig — Network socket syscall implementations
//
// Extracted from syscall_entry.zig: socket, bind, listen, accept, accept4,
// connect, shutdown, socketpair, sendto, recvfrom, sendmsg, recvmsg,
// setsockopt, getsockopt, getsockname, getpeername, net_poll,
// recvmmsg, sendmmsg.

const sched_mod = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const vfs_mod = @import("../fs/vfs.zig");
const net_mod = @import("mod.zig");
const udp = @import("udp.zig");
const copy = @import("../mm/copy_from_user.zig");
const bo = @import("../lib/byte_order.zig");

// ── FD allocation helpers ──────────────────────────────────────────

pub fn allocTcpFd(fd_table: *vfs_mod.FdTable, tcb_idx: u32) i64 {
    const slot = fd_table.allocFd() orelse return -1;
    fd_table.fds[slot] = .{
        .fd_type = .tcp_socket,
        .tcb_idx = tcb_idx,
        .writable = true,
    };
    return @intCast(slot);
}

pub fn allocUnixFd(fd_table: *vfs_mod.FdTable, unix_sock_idx: u32) i32 {
    const slot = fd_table.allocFd() orelse return -1;
    fd_table.fds[slot] = .{
        .fd_type = .unix_socket,
        .unix_sock_idx = unix_sock_idx,
    };
    return @intCast(slot);
}

// ── Syscall implementations ────────────────────────────────────────

/// socket(domain, type, protocol) → fd or -errno
pub fn socket(domain: u32, sock_type: u32, protocol: u32) i64 {
    _ = protocol;
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;

    if (domain == 1) {
        // AF_UNIX
        const sock_idx = net_mod.unix_socket.unixSocket(sock_type);
        if (sock_idx < 0) return @as(i64, sock_idx);
        const fd = allocUnixFd(&t.fd_table, @intCast(sock_idx));
        if (fd < 0) {
            net_mod.unix_socket.unixClose(@intCast(sock_idx));
            return -1;
        }
        return @as(i64, fd);
    }

    // AF_INET + UDP
    if (domain == 2 and sock_type == 2) {
        var port: u16 = 49152;
        while (port < 65535) : (port += 1) {
            const idx = udp.ensurePort(port);
            if (idx != 0xFFFF) {
                var fd_slot: u32 = undefined;
                var found = false;
                for (3..t.fd_table.fds.len) |i| {
                    if (t.fd_table.fds[i].fd_type == .none) {
                        fd_slot = @intCast(i);
                        found = true;
                        break;
                    }
                }
                if (!found) return -24; // EMFILE
                t.fd_table.fds[fd_slot] = .{
                    .fd_type = .udp_socket,
                    .udp_port = port,
                    .writable = true,
                };
                return @intCast(fd_slot);
            }
        }
        return -1;
    }

    if (domain != 2 or sock_type != 1) return -38; // ENOSYS

    // AF_INET + TCP
    const tcb_idx = net_mod.tcp.tcpSocket(cur_idx);
    if (tcb_idx < 0) return -1;
    const fd = allocTcpFd(&t.fd_table, @intCast(tcb_idx));
    if (fd < 0) {
        _ = net_mod.tcp.tcpClose(@intCast(tcb_idx));
        return -1;
    }
    return fd;
}

/// bind(fd, addr_ptr, addr_len) → 0 or -errno
pub fn bind(fd: u32, addr_ptr: u64, addr_len: u32) i64 {
    _ = addr_len;
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS) return -88; // ENOTSOCK

    // AF_UNIX bind
    if (t.fd_table.fds[fd].fd_type == .unix_socket) {
        const unix_idx = t.fd_table.fds[fd].unix_sock_idx;
        if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000) return -1;
        var sock_addr_buf: [110]u8 = undefined;
        const copied = copy.copyFromUser(&sock_addr_buf, @ptrFromInt(addr_ptr), 110);
        if (copied < 3) return -22; // EINVAL
        var path_len: usize = 0;
        for (2..110) |j| {
            if (sock_addr_buf[j] == 0) break;
            path_len += 1;
        }
        const result = net_mod.unix_socket.unixBind(unix_idx, @ptrCast(sock_addr_buf[2 .. 2 + path_len].ptr), path_len);
        return @as(i64, result);
    }

    if (t.fd_table.fds[fd].fd_type != .tcp_socket) return -88; // ENOTSOCK
    const tcb_idx = t.fd_table.fds[fd].tcb_idx;

    if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000) return -1;
    var sock_addr: [8]u8 = undefined;
    _ = copy.copyFromUser(&sock_addr, @ptrFromInt(addr_ptr), 8);
    const port = bo.readU16BeAt(&sock_addr, 2);
    const result = net_mod.tcp.tcpBind(tcb_idx, port);
    return result;
}

/// listen(fd, backlog) → 0 or -errno
pub fn listen(fd: u32, backlog: u32) i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS) return -88;

    if (t.fd_table.fds[fd].fd_type == .unix_socket) {
        const unix_idx = t.fd_table.fds[fd].unix_sock_idx;
        const result = net_mod.unix_socket.unixListen(unix_idx, backlog);
        return @as(i64, result);
    }

    if (t.fd_table.fds[fd].fd_type != .tcp_socket) return -88;
    const tcb_idx = t.fd_table.fds[fd].tcb_idx;
    const result = net_mod.tcp.tcpListen(tcb_idx);
    return result;
}

/// accept(fd, addr_ptr, addr_len_ptr) → new fd or -errno
pub fn accept(fd: u32, addr_ptr: u64, addr_len_ptr: u64) i64 {
    _ = addr_ptr;
    _ = addr_len_ptr;
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS) return -88;

    // AF_UNIX accept
    if (t.fd_table.fds[fd].fd_type == .unix_socket) {
        const unix_idx = t.fd_table.fds[fd].unix_sock_idx;
        const new_sock_idx = net_mod.unix_socket.unixAccept(unix_idx);
        if (new_sock_idx < 0) return @as(i64, new_sock_idx);
        const new_fd = allocUnixFd(&t.fd_table, @intCast(new_sock_idx));
        if (new_fd < 0) {
            net_mod.unix_socket.unixClose(@intCast(new_sock_idx));
            return -1;
        }
        return @as(i64, @as(i64, new_fd));
    }

    if (t.fd_table.fds[fd].fd_type != .tcp_socket) return -88;
    const listen_tcb_idx = t.fd_table.fds[fd].tcb_idx;
    const new_tcb_idx = net_mod.tcp.tcpAccept(listen_tcb_idx, cur_idx);
    if (new_tcb_idx <= 0) return new_tcb_idx;
    const new_fd = allocTcpFd(&t.fd_table, @intCast(new_tcb_idx));
    if (new_fd < 0) {
        _ = net_mod.tcp.tcpClose(@intCast(new_tcb_idx));
        return -1;
    }
    return new_fd;
}

/// accept4(fd, addr, addrlen, flags) → new fd or -errno
pub fn accept4(fd: u32, addr_ptr: u64, addr_len_ptr: u64, flags: u32) i64 {
    const result = accept(fd, addr_ptr, addr_len_ptr);
    if (result >= 0 and flags != 0) {
        const cur_idx = sched_mod.currentTaskIndex() orelse return result;
        const cur = task_mod.getTask(cur_idx) orelse return result;
        const newfd: u32 = @intCast(result);
        if (newfd < vfs_mod.MAX_FDS) {
            if ((flags & 0x80000) != 0) { // O_CLOEXEC
                cur.fd_table.fds[newfd].fd_flags = 1;
            }
            if ((flags & 0x800) != 0) { // O_NONBLOCK
                cur.fd_table.fds[newfd].status_flags |= 0x800;
            }
        }
    }
    return result;
}

/// sendto(fd, buf, len, flags, addr_ptr, addr_len) → bytes sent or -errno
pub fn sendto(fd: u32, buf: u64, len: u32, flags: u32, addr_ptr: u64, addr_len: u32) i64 {
    _ = flags;
    _ = addr_len;
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS) return -9; // EBADF

    if (t.fd_table.fds[fd].fd_type == .tcp_socket) {
        if (buf == 0 or buf >= 0x0000_8000_0000_0000 or len == 0) return -1;
        var tmp_buf: [1460]u8 = undefined;
        const to_copy = @min(len, 1460);
        const n = copy.copyFromUser(&tmp_buf, @ptrFromInt(buf), to_copy);
        if (n == 0) return -1;
        const tcb_idx = t.fd_table.fds[fd].tcb_idx;
        const result = net_mod.tcp.tcpSend(tcb_idx, &tmp_buf, @intCast(n));
        return result;
    } else if (t.fd_table.fds[fd].fd_type == .udp_socket) {
        if (buf == 0 or buf >= 0x0000_8000_0000_0000 or len == 0) return -1;
        var tmp_buf2: [1472]u8 = undefined;
        const to_copy2 = @min(len, 1472);
        const n2 = copy.copyFromUser(&tmp_buf2, @ptrFromInt(buf), to_copy2);
        if (n2 == 0) return -1;
        var dst_ip: [4]u8 = .{ 0, 0, 0, 0 };
        var dst_port: u16 = 0;
        if (addr_ptr != 0 and addr_ptr < 0x0000_8000_0000_0000) {
            var sa_buf: [16]u8 = undefined;
            if (copy.copyFromUser(&sa_buf, @ptrFromInt(addr_ptr), 16) >= 8) {
                dst_port = bo.readU16BeAt(&sa_buf, 2);
                dst_ip = .{ sa_buf[4], sa_buf[5], sa_buf[6], sa_buf[7] };
            }
        }
        const src_port = t.fd_table.fds[fd].udp_port;
        if (udp.sendTo(dst_ip, dst_port, src_port, &tmp_buf2, @intCast(n2))) {
            return @intCast(n2);
        } else {
            return -1;
        }
    } else {
        // Not a socket — use regular write
        var tmp_buf: [4096]u8 = undefined;
        const to_copy = @min(len, 4096);
        const n = copy.copyFromUser(&tmp_buf, @ptrFromInt(buf), to_copy);
        if (n == 0) return -1;
        const result = vfs_mod.FdTable.write(&t.fd_table, fd, &tmp_buf, n);
        return result;
    }
}

/// recvfrom(fd, buf, len, flags, addr_ptr, addr_len_ptr) → bytes received or -errno
pub fn recvfrom(fd: u32, buf: u64, len: u32, flags: u32, addr_ptr: u64, addr_len_ptr: u64) i64 {
    _ = flags;
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS) return -9;

    if (t.fd_table.fds[fd].fd_type == .unix_socket) {
        if (buf == 0 or buf >= 0x0000_8000_0000_0000 or len == 0) return -1;
        var tmp_buf: [8192]u8 = undefined;
        const to_read = @min(len, 8192);
        const unix_idx = t.fd_table.fds[fd].unix_sock_idx;
        const result = net_mod.unix_socket.unixRecv(unix_idx, &tmp_buf, to_read);
        if (result > 0) {
            _ = copy.copyToUser(@ptrFromInt(buf), @as([*]const u8, @ptrCast(&tmp_buf))[0..@intCast(result)], @intCast(result));
        }
        return result;
    } else if (t.fd_table.fds[fd].fd_type == .tcp_socket) {
        if (buf == 0 or buf >= 0x0000_8000_0000_0000 or len == 0) return -1;
        var tmp_buf: [4096]u8 = undefined;
        const to_read = @min(len, 4096);
        const tcb_idx = t.fd_table.fds[fd].tcb_idx;
        const result = net_mod.tcp.tcpRecv(tcb_idx, &tmp_buf, to_read);
        if (result > 0) {
            _ = copy.copyToUser(@ptrFromInt(buf), @as([*]const u8, @ptrCast(&tmp_buf))[0..@intCast(result)], @intCast(result));
        }
        return result;
    } else if (t.fd_table.fds[fd].fd_type == .udp_socket) {
        if (buf == 0 or buf >= 0x0000_8000_0000_0000 or len == 0) return -1;
        var tmp_buf2: [1472]u8 = undefined;
        const to_read2 = @min(len, 1472);
        const src_port = t.fd_table.fds[fd].udp_port;
        var src_ip: [4]u8 = .{ 0, 0, 0, 0 };
        var src_port_out: u16 = 0;
        const result2 = udp.recvFrom(src_port, &tmp_buf2, &src_ip, &src_port_out);
        if (result2 > 0) {
            const to_write = @min(@as(u32, @intCast(result2)), to_read2);
            _ = copy.copyToUser(@ptrFromInt(buf), @as([*]const u8, @ptrCast(&tmp_buf2))[0..to_write], to_write);
            if (addr_ptr != 0 and addr_ptr < 0x0000_8000_0000_0000) {
                var sa_out: [16]u8 = .{0} ** 16;
                sa_out[0] = 2; // AF_INET
                sa_out[1] = 0;
                bo.writeU16BeAt(&sa_out, 2, src_port_out);
                sa_out[4] = src_ip[0];
                sa_out[5] = src_ip[1];
                sa_out[6] = src_ip[2];
                sa_out[7] = src_ip[3];
                _ = copy.copyToUser(@ptrFromInt(addr_ptr), &sa_out, 8);
                if (addr_len_ptr != 0 and addr_len_ptr < 0x0000_8000_0000_0000) {
                    var al: [4]u8 = .{ 8, 0, 0, 0 };
                    _ = copy.copyToUser(@ptrFromInt(addr_len_ptr), &al, 4);
                }
            }
            return @intCast(to_write);
        } else {
            return 0;
        }
    } else {
        // Not a socket — use regular read
        var tmp_buf: [4096]u8 = undefined;
        const to_read = @min(len, 4096);
        const result = vfs_mod.FdTable.read(&t.fd_table, fd, &tmp_buf, to_read);
        if (result > 0) {
            _ = copy.copyToUser(@ptrFromInt(buf), @as([*]const u8, @ptrCast(&tmp_buf))[0..@intCast(result)], @intCast(result));
        }
        return result;
    }
}

/// setsockopt(fd, level, optname, optval, optlen) → 0 or -errno
pub fn setsockopt(fd: u64, level: u64, optname: u64, optval: u64, optlen: u64) i64 {
    const result = net_mod.socket_opt.sysSetSockopt(fd, level, optname, optval, optlen);
    return result;
}

/// getsockopt(fd, level, optname, optval, optlen_ptr) → 0 or -errno
pub fn getsockopt(fd: u64, level: u64, optname: u64, optval: u64, optlen_ptr: u64) i64 {
    const result = net_mod.socket_opt.sysGetSockopt(fd, level, optname, optval, optlen_ptr);
    return result;
}

/// connect(fd, addr_ptr, addr_len) → 0 or -errno
pub fn connect(fd: u32, addr_ptr: u64, addr_len: u32) i64 {
    _ = addr_len;
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS or t.fd_table.fds[fd].fd_type != .tcp_socket) return -88;
    const tcb_idx = t.fd_table.fds[fd].tcb_idx;

    if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000) return -1;
    var sock_addr: [8]u8 = undefined;
    _ = copy.copyFromUser(&sock_addr, @ptrFromInt(addr_ptr), 8);
    const port = bo.readU16BeAt(&sock_addr, 2);
    const ip = [4]u8{ sock_addr[4], sock_addr[5], sock_addr[6], sock_addr[7] };
    const result = net_mod.tcp.tcpConnectSocket(tcb_idx, ip, port);
    return result;
}

/// getsockname(fd, addr_ptr, addrlen_ptr) → 0 or -errno
pub fn getsockname(fd: u32, addr_ptr: u64, addrlen_ptr: u64) i64 {
    if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000 or
        addrlen_ptr == 0 or addrlen_ptr >= 0x0000_8000_0000_0000) return -22;

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= 16 or cur.fd_table.fds[fd].fd_type != .tcp_socket) return -88;
    const info = net_mod.tcp.tcpGetAddrInfo(cur.fd_table.fds[fd].tcb_idx) orelse return -1;

    var sockaddr: [16]u8 = @splat(0);
    sockaddr[0] = 2;
    sockaddr[1] = 0;
    bo.writeU16BeAt(&sockaddr, 2, info.local_port);
    @memcpy(sockaddr[4..8], &info.local_ip);
    _ = copy.copyToUser(@ptrFromInt(addr_ptr), &sockaddr, 16);
    var len_bytes: [4]u8 = @bitCast(@as(u32, 16));
    _ = copy.copyToUser(@ptrFromInt(addrlen_ptr), &len_bytes, 4);
    return 0;
}

/// getpeername(fd, addr_ptr, addrlen_ptr) → 0 or -errno
pub fn getpeername(fd: u32, addr_ptr: u64, addrlen_ptr: u64) i64 {
    if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000 or
        addrlen_ptr == 0 or addrlen_ptr >= 0x0000_8000_0000_0000) return -22;

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= 16 or cur.fd_table.fds[fd].fd_type != .tcp_socket) return -88;
    const info = net_mod.tcp.tcpGetAddrInfo(cur.fd_table.fds[fd].tcb_idx) orelse return -1;

    var sockaddr: [16]u8 = @splat(0);
    sockaddr[0] = 2;
    sockaddr[1] = 0;
    bo.writeU16BeAt(&sockaddr, 2, info.remote_port);
    @memcpy(sockaddr[4..8], &info.remote_ip);
    _ = copy.copyToUser(@ptrFromInt(addr_ptr), &sockaddr, 16);
    var len_bytes: [4]u8 = @bitCast(@as(u32, 16));
    _ = copy.copyToUser(@ptrFromInt(addrlen_ptr), &len_bytes, 4);
    return 0;
}

/// shutdown(fd, how) → 0 or -errno
pub fn shutdown(fd: u32, how: u32) i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= 16 or cur.fd_table.fds[fd].fd_type != .tcp_socket) return -88;
    const result = net_mod.tcp.tcpShutdown(cur.fd_table.fds[fd].tcb_idx, how);
    return result;
}

/// sendmsg(fd, msg_ptr, flags) → bytes sent or -errno
pub fn sendmsg(fd: u32, msg_ptr: u64, flags: u32) i64 {
    _ = flags;
    if (msg_ptr == 0 or msg_ptr >= 0x0000_8000_0000_0000) return -22;

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= 16 or cur.fd_table.fds[fd].fd_type != .tcp_socket) return -88;

    var msghdr_buf: [56]u8 = undefined;
    const hdr_copied = copy.copyFromUser(&msghdr_buf, @ptrFromInt(msg_ptr), 56);
    if (hdr_copied < 32) return -22;

    const iov_ptr: u64 = bo.readU64At(&msghdr_buf, 16);
    const iov_len: u64 = bo.readU64At(&msghdr_buf, 24);

    if (iov_ptr == 0 or iov_ptr >= 0x0000_8000_0000_0000 or iov_len == 0 or iov_len > 1024) return -22;

    const tcb_idx = cur.fd_table.fds[fd].tcb_idx;
    var total: usize = 0;

    for (0..@as(usize, @intCast(iov_len))) |i| {
        var iov_buf: [16]u8 = undefined;
        const src: [*]const u8 = @ptrFromInt(iov_ptr + @as(u64, @intCast(i)) * 16);
        const iov_copied = copy.copyFromUser(&iov_buf, src, 16);
        if (iov_copied < 16) break;

        const iov_base: u64 = bo.readU64At(&iov_buf, 0);
        const iov_sz: u64 = bo.readU64At(&iov_buf, 8);

        if (iov_base == 0 or iov_base >= 0x0000_8000_0000_0000 or iov_sz == 0) continue;

        var tmp: [1460]u8 = undefined;
        const to_copy: usize = @intCast(@min(iov_sz, 1460));
        const n = copy.copyFromUser(&tmp, @ptrFromInt(iov_base), to_copy);
        if (n == 0) break;
        const result = net_mod.tcp.tcpSend(tcb_idx, &tmp, @intCast(n));
        if (result <= 0) break;
        total += @intCast(result);
    }
    return @intCast(total);
}

/// recvmsg(fd, msg_ptr, flags) → bytes received or -errno
pub fn recvmsg(fd: u32, msg_ptr: u64, flags: u32) i64 {
    _ = flags;
    if (msg_ptr == 0 or msg_ptr >= 0x0000_8000_0000_0000) return -22;

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= 16 or cur.fd_table.fds[fd].fd_type != .tcp_socket) return -88;

    var msghdr_buf: [56]u8 = undefined;
    const hdr_copied = copy.copyFromUser(&msghdr_buf, @ptrFromInt(msg_ptr), 56);
    if (hdr_copied < 32) return -22;

    const iov_ptr: u64 = bo.readU64At(&msghdr_buf, 16);
    const iov_len: u64 = bo.readU64At(&msghdr_buf, 24);

    if (iov_ptr == 0 or iov_ptr >= 0x0000_8000_0000_0000 or iov_len == 0 or iov_len > 1024) return -22;

    const tcb_idx = cur.fd_table.fds[fd].tcb_idx;
    var total: usize = 0;

    for (0..@as(usize, @intCast(iov_len))) |i| {
        var iov_buf: [16]u8 = undefined;
        const src: [*]const u8 = @ptrFromInt(iov_ptr + @as(u64, @intCast(i)) * 16);
        const iov_copied = copy.copyFromUser(&iov_buf, src, 16);
        if (iov_copied < 16) break;

        const iov_base: u64 = bo.readU64At(&iov_buf, 0);
        const iov_sz: u64 = bo.readU64At(&iov_buf, 8);

        if (iov_base == 0 or iov_base >= 0x0000_8000_0000_0000 or iov_sz == 0) continue;

        var tmp: [4096]u8 = undefined;
        const to_read: u32 = @intCast(@min(iov_sz, 4096));
        const result = net_mod.tcp.tcpRecv(tcb_idx, &tmp, to_read);
        if (result > 0) {
            _ = copy.copyToUser(@ptrFromInt(iov_base), &tmp, @intCast(result));
            total += @intCast(result);
        }
        if (result <= 0) break;
    }
    return @intCast(total);
}

/// socketpair(domain, type, protocol, sv_ptr) → 0 or -errno
pub fn socketpair(domain: u32, sock_type: u32, protocol: u32, sv_ptr: u64) i64 {
    _ = domain;
    _ = sock_type;
    _ = protocol;
    if (sv_ptr == 0 or sv_ptr >= 0x0000_8000_0000_0000) return -14;

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    const result = cur.fd_table.createPipe();
    if (result < 0) return -12;
    const read_fd: u32 = @intCast(result & 0xFFFF);
    const write_fd: u32 = @intCast(@as(u64, @intCast(result)) >> 16);
    var fds: [8]u8 = undefined;
    bo.writeU32Le(fds[0..4], read_fd);
    bo.writeU32Le(fds[4..8], write_fd);
    _ = copy.copyToUser(@ptrFromInt(sv_ptr), &fds, 8);
    return 0;
}

/// net_poll() → count of packets processed
pub fn netPoll() i64 {
    const e1000_mod = @import("../drivers/e1000.zig");
    if (!e1000_mod.isActive()) return 0;

    var rx_tmp: [2048]u8 = undefined;
    var count: u64 = 0;
    var poll_limit: u32 = 0;
    while (poll_limit < 16) {
        const n = e1000_mod.receivePacket(&rx_tmp, 2048);
        if (n == 0) break;
        net_mod.handleRxPacket(&rx_tmp, n);
        count += 1;
        poll_limit += 1;
    }
    return @intCast(count);
}

/// recvmmsg(sockfd, msgvec, vlen, flags, timeout) → count or -errno
pub fn recvmmsg(sockfd: u32, msgvec_ptr: u64, vlen: u64, flags: u32, timeout: u64) i64 {
    _ = timeout;
    if (vlen == 0) return 0;
    const result = recvmsg(sockfd, msgvec_ptr, flags);
    if (result >= 0) {
        const msg_len_offset = msgvec_ptr + 56;
        var len_buf: [4]u8 = undefined;
        const recv_len: u32 = @intCast(result);
        bo.writeU32Le(&len_buf, recv_len);
        _ = copy.copyToUser(@ptrFromInt(msg_len_offset), &len_buf, 4);
        return 1;
    }
    return result;
}

/// sendmmsg(sockfd, msgvec, vlen, flags) → count or -errno
pub fn sendmmsg(sockfd: u32, msgvec_ptr: u64, vlen: u64, flags: u32) i64 {
    if (vlen == 0) return 0;
    const result = sendmsg(sockfd, msgvec_ptr, flags);
    if (result >= 0) return 1;
    return result;
}
