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
const sa = @import("sockaddr_util.zig");
const netif = @import("netif.zig");
const ndp = @import("ndp.zig");
const copy = @import("../mm/copy_from_user.zig");
const bo = @import("../lib/byte_order.zig");

const ENOTCONN: i64 = -107;
const SOCKADDR_UN_PATH_OFFSET: u32 = 2;
const SOCKADDR_IN_MIN_LEN: u32 = 8;

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
                // v53.49: Use allocFd() O(1) bitmap instead of duplicated linear scan
                const fd_slot = t.fd_table.allocFd() orelse return -24; // EMFILE
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

    // AF_INET6 — UDP uses the IPv6 stack (SK-70/71); TCP marks TCB is_v6 (SK-75).
    if (domain == 10) {
        if (sock_type == 1) {
            // SOCK_STREAM → IPv6 TCP socket (TX SYN-ACK still SK-76)
            const tcb_idx6 = net_mod.tcp.tcpSocket(cur_idx);
            if (tcb_idx6 < 0) return -1;
            if (net_mod.tcp.tcpSetIpv6(@intCast(tcb_idx6)) < 0) {
                _ = net_mod.tcp.tcpClose(@intCast(tcb_idx6));
                return -1;
            }
            const fd6 = allocTcpFd(&t.fd_table, @intCast(tcb_idx6));
            if (fd6 < 0) {
                _ = net_mod.tcp.tcpClose(@intCast(tcb_idx6));
                return -1;
            }
            return fd6;
        }
        if (sock_type == 2) {
            // SOCK_DGRAM → IPv6 UDP socket
            var port6: u16 = 49152;
            while (port6 < 65535) : (port6 += 1) {
                const idx6 = udp.ensurePort(port6);
                if (idx6 != 0xFFFF) {
                    const fd_slot6 = t.fd_table.allocFd() orelse return -24; // EMFILE
                    t.fd_table.fds[fd_slot6] = .{
                        .fd_type = .udp_socket,
                        .udp_port = port6,
                        .udp_is_v6 = true,
                        .writable = true,
                    };
                    return @intCast(fd_slot6);
                }
            }
            return -1;
        }
        return -38; // ENOSYS for unsupported AF_INET6 socket types
    }

    if (domain != 2 or sock_type != 1) {
        // AF_INET + SOCK_RAW (type=3): raw packet socket
        if (domain == 2 and sock_type == 3) {
            // Allocate raw socket fd
            // v53.49: Use allocFd() O(1) bitmap instead of duplicated linear scan
            const fd_slot = t.fd_table.allocFd() orelse return -24; // EMFILE
            t.fd_table.fds[fd_slot] = .{
                .fd_type = .raw_socket,
                .writable = true,
            };
            return @intCast(fd_slot);
        }
        return -38; // ENOSYS
    }

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
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS) return -88; // ENOTSOCK

    // AF_UNIX bind
    if (t.fd_table.fds[fd].fd_type == .unix_socket) {
        const unix_idx = t.fd_table.fds[fd].unix_sock_idx;
        if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000) return -1;
        if (addr_len <= SOCKADDR_UN_PATH_OFFSET) return -22; // EINVAL: family plus at least one path byte
        var sock_addr_buf: [110]u8 = undefined;
        const to_copy = @min(@as(usize, addr_len), sock_addr_buf.len);
        const copied = copy.copyFromUser(sock_addr_buf[0..to_copy], @ptrFromInt(addr_ptr), to_copy);
        if (copied <= SOCKADDR_UN_PATH_OFFSET) return -22; // EINVAL
        var path_len: usize = 0;
        for (2..copied) |j| {
            if (sock_addr_buf[j] == 0) break;
            path_len += 1;
        }
        const result = net_mod.unix_socket.unixBind(unix_idx, @ptrCast(sock_addr_buf[2 .. 2 + path_len].ptr), path_len);
        return @as(i64, result);
    }

    // UDP bind
    if (t.fd_table.fds[fd].fd_type == .udp_socket) {
        if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000) return -1;
        const is_v6 = t.fd_table.fds[fd].udp_is_v6;
        if (is_v6) {
            if (addr_len < sa.SOCKADDR_IN6_LEN) return -22;
            var sa6: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
            const n = copy.copyFromUser(&sa6, @ptrFromInt(addr_ptr), sa.SOCKADDR_IN6_LEN);
            if (n < sa.SOCKADDR_IN6_LEN) return -22; // EINVAL
            const parsed = sa.parseInet6(&sa6) orelse return -97; // EAFNOSUPPORT
            const idx = udp.ensurePort(parsed.port);
            if (idx == 0xFFFF) return -98; // EADDRINUSE
            t.fd_table.fds[fd].udp_port = parsed.port;
            return 0;
        }
        if (addr_len < SOCKADDR_IN_MIN_LEN) return -22;
        var sock_addr: [sa.SOCKADDR_IN_LEN]u8 = undefined;
        const n4 = copy.copyFromUser(&sock_addr, @ptrFromInt(addr_ptr), SOCKADDR_IN_MIN_LEN);
        if (n4 < SOCKADDR_IN_MIN_LEN) return -22;
        // Accept legacy callers that only filled port+addr; family may be unset.
        const new_port = bo.readU16BeAt(&sock_addr, 2);
        const idx = udp.ensurePort(new_port);
        if (idx == 0xFFFF) return -98; // EADDRINUSE
        t.fd_table.fds[fd].udp_port = new_port;
        return 0;
    }

    if (t.fd_table.fds[fd].fd_type != .tcp_socket) return -88; // ENOTSOCK
    const tcb_idx = t.fd_table.fds[fd].tcb_idx;

    if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000) return -1;
    const info = net_mod.tcp.tcpGetAddrInfo(tcb_idx) orelse return -1;
    if (info.is_v6) {
        if (addr_len < sa.SOCKADDR_IN6_LEN) return -22;
        var sa6: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
        if (copy.copyFromUser(&sa6, @ptrFromInt(addr_ptr), sa.SOCKADDR_IN6_LEN) < sa.SOCKADDR_IN6_LEN)
            return -22;
        const parsed = sa.parseInet6(&sa6) orelse return -97; // EAFNOSUPPORT
        return net_mod.tcp.tcpBind(tcb_idx, parsed.port);
    }
    if (addr_len < SOCKADDR_IN_MIN_LEN) return -22;
    var sock_addr: [8]u8 = undefined;
    if (copy.copyFromUser(&sock_addr, @ptrFromInt(addr_ptr), SOCKADDR_IN_MIN_LEN) != SOCKADDR_IN_MIN_LEN) return -14;
    const port = bo.readU16BeAt(&sock_addr, 2);
    return net_mod.tcp.tcpBind(tcb_idx, port);
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
    // SK-78: optionally fill peer sockaddr (IPv4 or IPv6).
    if (addr_ptr != 0 and addr_ptr < 0x0000_8000_0000_0000 and
        addr_len_ptr != 0 and addr_len_ptr < 0x0000_8000_0000_0000)
    {
        if (net_mod.tcp.tcpGetAddrInfo(@intCast(new_tcb_idx))) |ainfo| {
            var sa_buf: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
            const alen = sa.encodeInetName(ainfo.is_v6, ainfo.remote_port, ainfo.remote_ip, ainfo.remote_ip6, &sa_buf);
            if (alen != 0) _ = copySockaddrToUser(addr_ptr, addr_len_ptr, sa_buf[0..alen], alen);
        }
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
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS) return -9; // EBADF

    if (t.fd_table.fds[fd].fd_type == .tcp_socket) {
        if (buf == 0 or buf >= 0x0000_8000_0000_0000 or len == 0) return -1;
        const tcb_idx = t.fd_table.fds[fd].tcb_idx;
        return net_mod.tcp.tcpSendFromUser(tcb_idx, buf, len);
    } else if (t.fd_table.fds[fd].fd_type == .udp_socket) {
        if (buf == 0 or buf >= 0x0000_8000_0000_0000 or len == 0) return -1;
        const is_v6 = t.fd_table.fds[fd].udp_is_v6;
        const src_port = t.fd_table.fds[fd].udp_port;
        if (is_v6) {
            var tmp6: [1232]u8 = undefined;
            const to_copy6 = @min(len, 1232);
            const n6 = copy.copyFromUser(&tmp6, @ptrFromInt(buf), to_copy6);
            if (n6 == 0) return -1;
            var dst6: [16]u8 = @splat(0);
            var dst_port6: u16 = 0;
            if (addr_ptr != 0 and addr_ptr < 0x0000_8000_0000_0000) {
                if (addr_len < sa.SOCKADDR_IN6_LEN) return -22;
                var sa6: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
                if (copy.copyFromUser(&sa6, @ptrFromInt(addr_ptr), sa.SOCKADDR_IN6_LEN) < sa.SOCKADDR_IN6_LEN)
                    return -22;
                const parsed = sa.parseInet6(&sa6) orelse return -97; // EAFNOSUPPORT
                dst6 = parsed.addr;
                dst_port6 = parsed.port;
            } else if (t.fd_table.fds[fd].udp_connected) {
                dst6 = t.fd_table.fds[fd].udp_dst_ip6;
                dst_port6 = t.fd_table.fds[fd].udp_dst_port;
            } else {
                return -89; // EDESTADDRREQ
            }
            if (udp.sendToV6(dst6, dst_port6, src_port, &tmp6, @intCast(n6))) {
                return @intCast(n6);
            } else {
                return -1;
            }
        }
        var tmp_buf2: [1472]u8 = undefined;
        const to_copy2 = @min(len, 1472);
        const n2 = copy.copyFromUser(&tmp_buf2, @ptrFromInt(buf), to_copy2);
        if (n2 == 0) return -1;
        var dst_ip: [4]u8 = .{ 0, 0, 0, 0 };
        var dst_port: u16 = 0;
        if (addr_ptr != 0 and addr_ptr < 0x0000_8000_0000_0000) {
            if (addr_len < SOCKADDR_IN_MIN_LEN) return -22;
            var sa_buf: [16]u8 = undefined;
            if (copy.copyFromUser(sa_buf[0..SOCKADDR_IN_MIN_LEN], @ptrFromInt(addr_ptr), SOCKADDR_IN_MIN_LEN) != SOCKADDR_IN_MIN_LEN) return -14;
            dst_port = bo.readU16BeAt(&sa_buf, 2);
            dst_ip = .{ sa_buf[4], sa_buf[5], sa_buf[6], sa_buf[7] };
        } else if (t.fd_table.fds[fd].udp_connected) {
            // Use connected destination when no address provided (send() on connected UDP)
            dst_ip = t.fd_table.fds[fd].udp_dst_ip;
            dst_port = t.fd_table.fds[fd].udp_dst_port;
        }
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
        if (!copy.validateUserBufferWritable(buf, to_read)) return -14; // EFAULT
        const unix_idx = t.fd_table.fds[fd].unix_sock_idx;
        const result = net_mod.unix_socket.unixRecv(unix_idx, &tmp_buf, to_read);
        if (result > 0) {
            const copied = copy.copyToUser(@ptrFromInt(buf), @as([*]const u8, @ptrCast(&tmp_buf))[0..@intCast(result)], @intCast(result));
            if (copied != @as(usize, @intCast(result))) return -14; // EFAULT
        }
        return result;
    } else if (t.fd_table.fds[fd].fd_type == .tcp_socket) {
        if (buf == 0 or buf >= 0x0000_8000_0000_0000 or len == 0) return -1;
        var tmp_buf: [4096]u8 = undefined;
        const to_read = @min(len, 4096);
        if (!copy.validateUserBufferWritable(buf, to_read)) return -14; // EFAULT
        const tcb_idx = t.fd_table.fds[fd].tcb_idx;
        const result = net_mod.tcp.tcpRecv(tcb_idx, &tmp_buf, to_read);
        if (result > 0) {
            const copied = copy.copyToUser(@ptrFromInt(buf), @as([*]const u8, @ptrCast(&tmp_buf))[0..@intCast(result)], @intCast(result));
            if (copied != @as(usize, @intCast(result))) return -14; // EFAULT
        }
        return result;
    } else if (t.fd_table.fds[fd].fd_type == .udp_socket) {
        if (buf == 0 or buf >= 0x0000_8000_0000_0000 or len == 0) return -1;
        const is_v6 = t.fd_table.fds[fd].udp_is_v6;
        const src_port = t.fd_table.fds[fd].udp_port;
        if (is_v6) {
            var tmp6: [1232]u8 = undefined;
            const to_read6 = @min(len, 1232);
            if (!copy.validateUserBufferWritable(buf, to_read6)) return -14; // EFAULT
            if (addr_ptr != 0) {
                if (!copy.validateUserBufferWritable(addr_ptr, sa.SOCKADDR_IN6_LEN)) return -14;
                if (addr_len_ptr != 0 and !copy.validateUserBufferWritable(addr_len_ptr, 4)) return -14;
            }
            var src6: [16]u8 = @splat(0);
            var src_port_out6: u16 = 0;
            const result6 = udp.recvFromV6(src_port, &tmp6, &src6, &src_port_out6);
            if (result6 > 0) {
                const to_write6 = @min(@as(u32, @intCast(result6)), to_read6);
                if (copy.copyToUser(@ptrFromInt(buf), @as([*]const u8, @ptrCast(&tmp6))[0..to_write6], to_write6) != to_write6) return -14;
                if (addr_ptr != 0 and addr_ptr < 0x0000_8000_0000_0000) {
                    var sa_out6: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
                    const alen = sa.writeInet6(&sa_out6, src_port_out6, src6, 0);
                    if (copy.copyToUser(@ptrFromInt(addr_ptr), &sa_out6, alen) != alen) return -14;
                    if (addr_len_ptr != 0 and addr_len_ptr < 0x0000_8000_0000_0000) {
                        var al6: [4]u8 = .{
                            @truncate(alen),
                            @truncate(alen >> 8),
                            @truncate(alen >> 16),
                            @truncate(alen >> 24),
                        };
                        if (copy.copyToUser(@ptrFromInt(addr_len_ptr), &al6, 4) != 4) return -14;
                    }
                }
                return @intCast(to_write6);
            }
            return 0;
        }
        var tmp_buf2: [1472]u8 = undefined;
        const to_read2 = @min(len, 1472);
        if (!copy.validateUserBufferWritable(buf, to_read2)) return -14; // EFAULT
        if (addr_ptr != 0) {
            if (!copy.validateUserBufferWritable(addr_ptr, 8)) return -14;
            if (addr_len_ptr != 0 and !copy.validateUserBufferWritable(addr_len_ptr, 4)) return -14;
        }
        var src_ip: [4]u8 = .{ 0, 0, 0, 0 };
        var src_port_out: u16 = 0;
        const result2 = udp.recvFrom(src_port, &tmp_buf2, @intCast(tmp_buf2.len), &src_ip, &src_port_out);
        if (result2 > 0) {
            const to_write = @min(@as(u32, @intCast(result2)), to_read2);
            if (copy.copyToUser(@ptrFromInt(buf), @as([*]const u8, @ptrCast(&tmp_buf2))[0..to_write], to_write) != to_write) return -14;
            if (addr_ptr != 0 and addr_ptr < 0x0000_8000_0000_0000) {
                var sa_out: [sa.SOCKADDR_IN_LEN]u8 = undefined;
                _ = sa.writeInet4(&sa_out, src_port_out, src_ip);
                // Preserve historical 8-byte write for short user buffers.
                if (copy.copyToUser(@ptrFromInt(addr_ptr), &sa_out, 8) != 8) return -14;
                if (addr_len_ptr != 0 and addr_len_ptr < 0x0000_8000_0000_0000) {
                    var al: [4]u8 = .{ 8, 0, 0, 0 };
                    if (copy.copyToUser(@ptrFromInt(addr_len_ptr), &al, 4) != 4) return -14;
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
        if (!copy.validateUserBufferWritable(buf, to_read)) return -14; // EFAULT
        const result = vfs_mod.FdTable.read(&t.fd_table, fd, &tmp_buf, to_read);
        if (result > 0) {
            const copied = copy.copyToUser(@ptrFromInt(buf), @as([*]const u8, @ptrCast(&tmp_buf))[0..@intCast(result)], @intCast(result));
            if (copied != @as(usize, @intCast(result))) return -14; // EFAULT
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

    if (fd >= vfs_mod.MAX_FDS) return -88;

    // UDP connect: set default destination
    if (t.fd_table.fds[fd].fd_type == .udp_socket) {
        if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000) return -1;
        if (t.fd_table.fds[fd].udp_is_v6) {
            var sa6: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
            if (copy.copyFromUser(&sa6, @ptrFromInt(addr_ptr), sa.SOCKADDR_IN6_LEN) < sa.SOCKADDR_IN6_LEN)
                return -22;
            const parsed = sa.parseInet6(&sa6) orelse return -97;
            t.fd_table.fds[fd].udp_connected = true;
            t.fd_table.fds[fd].udp_dst_ip6 = parsed.addr;
            t.fd_table.fds[fd].udp_dst_port = parsed.port;
            return 0;
        }
        var sock_addr: [8]u8 = undefined;
        if (copy.copyFromUser(&sock_addr, @ptrFromInt(addr_ptr), 8) != 8) return -14;
        const dst_port = bo.readU16BeAt(&sock_addr, 2);
        const dst_ip = [4]u8{ sock_addr[4], sock_addr[5], sock_addr[6], sock_addr[7] };
        t.fd_table.fds[fd].udp_connected = true;
        t.fd_table.fds[fd].udp_dst_ip = dst_ip;
        t.fd_table.fds[fd].udp_dst_port = dst_port;
        return 0;
    }

    if (t.fd_table.fds[fd].fd_type != .tcp_socket) return -88;
    const tcb_idx = t.fd_table.fds[fd].tcb_idx;

    if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000) return -1;
    const info = net_mod.tcp.tcpGetAddrInfo(tcb_idx) orelse return -1;
    if (info.is_v6) {
        var sa6: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
        if (copy.copyFromUser(&sa6, @ptrFromInt(addr_ptr), sa.SOCKADDR_IN6_LEN) < sa.SOCKADDR_IN6_LEN)
            return -22;
        const parsed = sa.parseInet6(&sa6) orelse return -97;
        return net_mod.tcp.tcpConnectSocketV6(tcb_idx, parsed.addr, parsed.port);
    }
    var sock_addr: [8]u8 = undefined;
    if (copy.copyFromUser(&sock_addr, @ptrFromInt(addr_ptr), 8) != 8) return -14;
    const port = bo.readU16BeAt(&sock_addr, 2);
    const ip = [4]u8{ sock_addr[4], sock_addr[5], sock_addr[6], sock_addr[7] };
    return net_mod.tcp.tcpConnectSocket(tcb_idx, ip, port);
}

fn copySockaddrToUser(addr_ptr: u64, addrlen_ptr: u64, sa_buf: []const u8, alen: u32) i64 {
    const to_copy = @min(alen, @as(u32, @intCast(sa_buf.len)));
    if (copy.copyToUser(@ptrFromInt(addr_ptr), sa_buf[0..to_copy], to_copy) != to_copy) return -14;
    var len_bytes: [4]u8 = @bitCast(alen);
    if (copy.copyToUser(@ptrFromInt(addrlen_ptr), &len_bytes, 4) != 4) return -14;
    return 0;
}

/// getsockname(fd, addr_ptr, addrlen_ptr) → 0 or -errno
pub fn getsockname(fd: u32, addr_ptr: u64, addrlen_ptr: u64) i64 {
    if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000 or
        addrlen_ptr == 0 or addrlen_ptr >= 0x0000_8000_0000_0000) return -22;

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS) return -88;
    const desc = cur.fd_table.fds[fd];

    if (desc.fd_type == .udp_socket) {
        var sa_buf: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
        const our4 = netif.getOurIp();
        // SK-86: prefer preferred global when reporting the local UDP name.
        const our6 = ndp.getGlobalAddress() orelse ndp.generateLinkLocal(netif.getMac());
        const alen = sa.encodeUdpName(desc.udp_is_v6, desc.udp_port, our4, our6, &sa_buf);
        if (alen == 0) return -1;
        return copySockaddrToUser(addr_ptr, addrlen_ptr, sa_buf[0..alen], alen);
    }

    if (desc.fd_type != .tcp_socket) return -88;
    const info = net_mod.tcp.tcpGetAddrInfo(desc.tcb_idx) orelse return -1;

    var sa_buf: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
    const alen = sa.encodeInetName(info.is_v6, info.local_port, info.local_ip, info.local_ip6, &sa_buf);
    if (alen == 0) return -1;
    return copySockaddrToUser(addr_ptr, addrlen_ptr, sa_buf[0..alen], alen);
}

/// getpeername(fd, addr_ptr, addrlen_ptr) → 0 or -errno
pub fn getpeername(fd: u32, addr_ptr: u64, addrlen_ptr: u64) i64 {
    if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000 or
        addrlen_ptr == 0 or addrlen_ptr >= 0x0000_8000_0000_0000) return -22;

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS) return -88;
    const desc = cur.fd_table.fds[fd];

    if (desc.fd_type == .udp_socket) {
        if (!desc.udp_connected) return ENOTCONN;
        var sa_buf: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
        const alen = sa.encodeUdpName(desc.udp_is_v6, desc.udp_dst_port, desc.udp_dst_ip, desc.udp_dst_ip6, &sa_buf);
        if (alen == 0) return -1;
        return copySockaddrToUser(addr_ptr, addrlen_ptr, sa_buf[0..alen], alen);
    }

    if (desc.fd_type != .tcp_socket) return -88;
    const info = net_mod.tcp.tcpGetAddrInfo(desc.tcb_idx) orelse return -1;

    var sa_buf: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
    const alen = sa.encodeInetName(info.is_v6, info.remote_port, info.remote_ip, info.remote_ip6, &sa_buf);
    if (alen == 0) return -1;
    return copySockaddrToUser(addr_ptr, addrlen_ptr, sa_buf[0..alen], alen);
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

        const to_send: u32 = @intCast(@min(iov_sz, @as(u64, 0xffff_ffff)));
        const result = net_mod.tcp.tcpSendFromUser(tcb_idx, iov_base, to_send);
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
        if (!copy.validateUserBufferWritable(iov_base, to_read)) return if (total == 0) -14 else @intCast(total);
        const result = net_mod.tcp.tcpRecv(tcb_idx, &tmp, to_read);
        if (result > 0) {
            const copied = copy.copyToUser(@ptrFromInt(iov_base), &tmp, @intCast(result));
            if (copied != @as(usize, @intCast(result))) return if (total == 0) -14 else @intCast(total);
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
    if (copy.copyToUser(@ptrFromInt(sv_ptr), &fds, 8) != 8) {
        _ = cur.fd_table.close(read_fd);
        _ = cur.fd_table.close(write_fd);
        return -14;
    }
    return 0;
}

/// net_poll() → count of packets processed
pub fn netPoll() i64 {
    const nic = @import("nic.zig");
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
        if (copy.copyToUser(@ptrFromInt(msg_len_offset), &len_buf, 4) != 4) return -14;
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
