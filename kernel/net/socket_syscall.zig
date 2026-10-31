// kernel/net/socket_syscall.zig — Network socket syscall implementations
//
// Extracted from syscall_entry.zig: socket, bind, listen, accept, accept4,
// connect, shutdown, socketpair, sendto, recvfrom, sendmsg, recvmsg,
// setsockopt, getsockopt, getsockname, getpeername, net_poll,
// recvmmsg, sendmmsg.

const sched_mod = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const cap_mod = @import("../ipc/capability.zig");
const vfs_mod = @import("../fs/vfs.zig");
const net_mod = @import("mod.zig");
const udp = @import("udp.zig");
const udp_util = @import("udp_util.zig");
const sa = @import("sockaddr_util.zig");
const netif = @import("netif.zig");
const ndp = @import("ndp.zig");
const copy = @import("../mm/copy_from_user.zig");
const bo = @import("../lib/byte_order.zig");
const socketpair_policy = @import("socketpair_policy.zig");
const message_batch_policy = @import("message_batch_policy.zig");
const accept4_policy = @import("accept4_policy.zig");

const ENOTCONN: i64 = -107;
const SOCKADDR_UN_PATH_OFFSET: u32 = 2;
const SOCKADDR_IN_MIN_LEN: u32 = 8;

// ── FD allocation helpers ──────────────────────────────────────────

pub fn allocTcpFd(fd_table: *vfs_mod.FdTable, tcb_idx: u32) i64 {
    const slot = fd_table.allocFd() orelse return -24; // EMFILE
    fd_table.fds[slot] = .{
        .fd_type = .tcp_socket,
        .tcb_idx = tcb_idx,
        .writable = true,
    };
    fd_table.publishFd(slot);
    return @intCast(slot);
}

pub fn allocUnixFd(fd_table: *vfs_mod.FdTable, unix_sock_idx: u32) i32 {
    const slot = fd_table.allocFd() orelse return -24; // EMFILE
    fd_table.fds[slot] = .{
        .fd_type = .unix_socket,
        .unix_sock_idx = unix_sock_idx,
        .writable = true,
    };
    fd_table.publishFd(slot);
    return @intCast(slot);
}

// ── Syscall implementations ────────────────────────────────────────

/// socket(domain, type, protocol) → fd or -errno
pub fn socket(domain: u32, type_and_flags: u32, protocol: u32) i64 {
    const np = @import("../fs/namespace_policy.zig");
    const parsed = switch (np.socketArgs(domain, type_and_flags, protocol)) {
        .ok => |a| a,
        .err => |e| return e,
    };
    const fd = socketCreate(domain, parsed.sock_type);
    if (fd < 0) return fd;
    // SOCK_CLOEXEC / SOCK_NONBLOCK belong to the new descriptor, not to the socket type.
    const cur_idx = sched_mod.currentTaskIndex() orelse return fd;
    const t = task_mod.getTask(cur_idx) orelse return fd;
    if (fd < vfs_mod.MAX_FDS) {
        if (parsed.cloexec) t.fd_table.fds[@intCast(fd)].fd_flags = 1;
        if (parsed.nonblock) vfs_mod.setStatusFlags(&t.fd_table.fds[@intCast(fd)], t.fd_table.fds[@intCast(fd)].status_flags | 0x800);
    }
    return fd;
}

fn socketCreate(domain: u32, sock_type: u32) i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;

    if (domain == 1) {
        // AF_UNIX
        const sock_idx = net_mod.unix_socket.unixSocket(sock_type);
        if (sock_idx < 0) return @as(i64, sock_idx);
        net_mod.unix_socket.unixSetCred(@intCast(sock_idx), .{ .pid = @intCast(if (t.is_thread and t.parent_tid != 0) t.parent_tid else t.tid), .uid = t.euid, .gid = t.egid });
        const fd = allocUnixFd(t.fd_table, @intCast(sock_idx));
        if (fd < 0) {
            net_mod.unix_socket.unixClose(@intCast(sock_idx));
            return fd;
        }
        return @as(i64, fd);
    }

    // AF_INET + UDP
    if (domain == 2 and sock_type == 2) {
        var port: u16 = 49152;
        while (port < 65535) : (port += 1) {
            // ensurePortExclusive: an already-registered port (0xFFFE) must be
            // skipped — plain ensurePort would hand the new socket the EXISTING
            // slot, sharing the first socket's receive queue and refcount.
            const idx = udp.ensurePortExclusive(port);
            switch (udp_util.scanAction(idx)) {
                .skip_in_use => continue,
                .abort_full => return -1,
                .use => {
                    // v53.49: Use allocFd() O(1) bitmap instead of duplicated linear scan
                    const fd_slot = t.fd_table.allocFd() orelse {
                        udp.releasePort(port); // roll back the port registration
                        return -24; // EMFILE
                    };
                    t.fd_table.fds[fd_slot] = .{
                        .fd_type = .udp_socket,
                        .udp_port = port,
                        .writable = true,
                    };
                    t.fd_table.publishFd(fd_slot);
                    return @intCast(fd_slot);
                },
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
            const fd6 = allocTcpFd(t.fd_table, @intCast(tcb_idx6));
            if (fd6 < 0) {
                _ = net_mod.tcp.tcpClose(@intCast(tcb_idx6));
                return fd6;
            }
            return fd6;
        }
        if (sock_type == 2) {
            // SOCK_DGRAM → IPv6 UDP socket
            var port6: u16 = 49152;
            while (port6 < 65535) : (port6 += 1) {
                // Same exclusivity rule as the IPv4 scan above.
                const idx6 = udp.ensurePortExclusive(port6);
                switch (udp_util.scanAction(idx6)) {
                    .skip_in_use => continue,
                    .abort_full => return -1,
                    .use => {
                        const fd_slot6 = t.fd_table.allocFd() orelse {
                            udp.releasePort(port6); // roll back the port registration
                            return -24; // EMFILE
                        };
                        t.fd_table.fds[fd_slot6] = .{
                            .fd_type = .udp_socket,
                            .udp_port = port6,
                            .udp_is_v6 = true,
                            .writable = true,
                        };
                        t.fd_table.publishFd(fd_slot6);
                        return @intCast(fd_slot6);
                    },
                }
            }
            return -1;
        }
        return -38; // ENOSYS for unsupported AF_INET6 socket types
    }

    if (domain != 2 or sock_type != 1) {
        // AF_INET + SOCK_RAW (type=3): raw packet socket
        if (domain == 2 and sock_type == 3) {
            if (!cap_mod.hasSysCap(cur_idx, "cap_net_raw")) return -1; // EPERM
            // Allocate raw socket fd
            // v53.49: Use allocFd() O(1) bitmap instead of duplicated linear scan
            const fd_slot = t.fd_table.allocFd() orelse return -24; // EMFILE
            t.fd_table.fds[fd_slot] = .{
                .fd_type = .raw_socket,
                .writable = true,
            };
            t.fd_table.publishFd(fd_slot);
            return @intCast(fd_slot);
        }
        return -38; // ENOSYS
    }

    // AF_INET + TCP
    const tcb_idx = net_mod.tcp.tcpSocket(cur_idx);
    if (tcb_idx < 0) return -1;
    const fd = allocTcpFd(t.fd_table, @intCast(tcb_idx));
    if (fd < 0) {
        _ = net_mod.tcp.tcpClose(@intCast(tcb_idx));
        return fd;
    }
    return fd;
}

/// bind(fd, addr_ptr, addr_len) → 0 or -errno
pub fn bind(fd: u32, addr_ptr: u64, addr_len: u32) i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS) return -9; // EBADF
    if (t.fd_table.fds[fd].fd_type == .none) return -9;

    // AF_UNIX bind
    if (t.fd_table.fds[fd].fd_type == .unix_socket) {
        const unix_idx = t.fd_table.fds[fd].unix_sock_idx;
        if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000) return -14;
        if (!@import("socket_address_policy.zig").unixLengthValid(addr_len, SOCKADDR_UN_PATH_OFFSET)) return -22;
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
            if (parsed.port != 0 and parsed.port < 1024 and !cap_mod.hasSysCap(cur_idx, "cap_net_bind")) return -1;
            const cur_port = t.fd_table.fds[fd].udp_port;
            if (parsed.port != cur_port) {
                // EADDRINUSE when another socket owns the port (0xFFFE) or the
                // port table is full (0xFFFF).
                if (udp.ensurePortExclusive(parsed.port) >= 0xFFFE) return -98;
                udp.releasePort(cur_port); // drop the ephemeral port from socket()
                t.fd_table.fds[fd].udp_port = parsed.port;
            }
            return 0;
        }
        if (addr_len < SOCKADDR_IN_MIN_LEN) return -22;
        var sock_addr: [sa.SOCKADDR_IN_LEN]u8 = undefined;
        const n4 = copy.copyFromUser(&sock_addr, @ptrFromInt(addr_ptr), SOCKADDR_IN_MIN_LEN);
        if (n4 < SOCKADDR_IN_MIN_LEN) return -22;
        // Accept legacy callers that only filled port+addr; family may be unset.
        const new_port = bo.readU16BeAt(&sock_addr, 2);
        if (new_port != 0 and new_port < 1024 and !cap_mod.hasSysCap(cur_idx, "cap_net_bind")) return -1;
        const cur_port = t.fd_table.fds[fd].udp_port;
        if (new_port != cur_port) {
            // EADDRINUSE when another socket owns the port (0xFFFE) or the
            // port table is full (0xFFFF).
            if (udp.ensurePortExclusive(new_port) >= 0xFFFE) return -98;
            udp.releasePort(cur_port); // drop the ephemeral port from socket()
            t.fd_table.fds[fd].udp_port = new_port;
        }
        return 0;
    }

    if (t.fd_table.fds[fd].fd_type != .tcp_socket) return -88; // ENOTSOCK
    const tcb_idx = t.fd_table.fds[fd].tcb_idx;

    if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000) return -14;
    const info = net_mod.tcp.tcpGetAddrInfo(tcb_idx) orelse return -1;
    if (info.is_v6) {
        if (!@import("socket_address_policy.zig").inetLengthValid(addr_len, true)) return -22;
        if (addr_len < sa.SOCKADDR_IN6_LEN) return -22;
        var sa6: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
        if (copy.copyFromUser(&sa6, @ptrFromInt(addr_ptr), sa.SOCKADDR_IN6_LEN) < sa.SOCKADDR_IN6_LEN)
            return -22;
        const parsed = sa.parseInet6(&sa6) orelse return -97; // EAFNOSUPPORT
        if (parsed.port != 0 and parsed.port < 1024 and !cap_mod.hasSysCap(cur_idx, "cap_net_bind")) return -1;
        return net_mod.tcp.tcpBind(tcb_idx, parsed.port);
    }
    if (addr_len < SOCKADDR_IN_MIN_LEN) return -22;
    if (!@import("socket_address_policy.zig").inetLengthValid(addr_len, false)) return -22;
    var sock_addr: [8]u8 = undefined;
    if (copy.copyFromUser(&sock_addr, @ptrFromInt(addr_ptr), SOCKADDR_IN_MIN_LEN) != SOCKADDR_IN_MIN_LEN) return -14;
    const port = bo.readU16BeAt(&sock_addr, 2);
    if (port != 0 and port < 1024 and !cap_mod.hasSysCap(cur_idx, "cap_net_bind")) return -1;
    return net_mod.tcp.tcpBind(tcb_idx, port);
}

/// listen(fd, backlog) → 0 or -errno
pub fn listen(fd: u32, backlog: u32) i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS or t.fd_table.fds[fd].fd_type == .none) return -9; // EBADF

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
    if ((addr_ptr == 0) != (addr_len_ptr == 0)) return -14;
    if (addr_ptr != 0 and
        (!copy.validateUserRange(addr_ptr, 0) or
            !copy.validateUserBuffer(addr_len_ptr, 4) or
            !copy.validateUserBufferWritable(addr_len_ptr, 4))) return -14;

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS) return -9;
    if (t.fd_table.fds[fd].fd_type == .none) return -9;

    // AF_UNIX accept
    if (t.fd_table.fds[fd].fd_type == .unix_socket) {
        const unix_idx = t.fd_table.fds[fd].unix_sock_idx;
        const new_sock_idx = net_mod.unix_socket.unixAcceptBlocking(unix_idx, @import("../fs/namespace_policy.zig").nonblockRequested(t.fd_table.fds[fd].status_flags, 0));
        if (new_sock_idx < 0) return @as(i64, new_sock_idx);
        net_mod.unix_socket.unixSetCred(@intCast(new_sock_idx), .{ .pid = @intCast(if (t.is_thread and t.parent_tid != 0) t.parent_tid else t.tid), .uid = t.euid, .gid = t.egid });
        const new_fd = allocUnixFd(t.fd_table, @intCast(new_sock_idx));
        if (new_fd < 0) {
            net_mod.unix_socket.unixClose(@intCast(new_sock_idx));
            return new_fd;
        }
        return @as(i64, @as(i64, new_fd));
    }

    if (t.fd_table.fds[fd].fd_type != .tcp_socket) return -88;
    const listen_tcb_idx = t.fd_table.fds[fd].tcb_idx;
    const new_tcb_idx = net_mod.tcp.tcpAccept(listen_tcb_idx, cur_idx);
    // Negative only on error/empty backlog (-11 EAGAIN); TCB index 0 is valid.
    if (new_tcb_idx < 0) return new_tcb_idx;
    const new_fd = allocTcpFd(t.fd_table, @intCast(new_tcb_idx));
    if (new_fd < 0) {
        _ = net_mod.tcp.tcpClose(@intCast(new_tcb_idx));
        return new_fd;
    }
    // SK-78: optionally fill peer sockaddr (IPv4 or IPv6).
    if (addr_ptr != 0 or addr_len_ptr != 0) {
        if (net_mod.tcp.tcpGetAddrInfo(@intCast(new_tcb_idx))) |ainfo| {
            var sa_buf: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
            const alen = sa.encodeInetName(ainfo.is_v6, ainfo.remote_port, ainfo.remote_ip, ainfo.remote_ip6, &sa_buf);
            // Copy-out failure must not leak the accepted fd/TCB.
            if (alen != 0 and copySockaddrToUser(addr_ptr, addr_len_ptr, sa_buf[0..alen], alen) != 0) {
                _ = t.fd_table.close(@intCast(new_fd));
                return -14; // EFAULT
            }
        }
    }
    return new_fd;
}

/// accept4(fd, addr, addrlen, flags) → new fd or -errno
pub fn accept4(fd: u32, addr_ptr: u64, addr_len_ptr: u64, flags: u32) i64 {
    const policy_result = accept4_policy.validate(flags);
    if (policy_result != 0) return policy_result;
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
    if (!@import("socket_address_policy.zig").optionalUserAddressValid(addr_ptr, 0x0000_8000_0000_0000)) return -14;
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS) return -9; // EBADF

    if (t.fd_table.fds[fd].fd_type == .tcp_socket) {
        if (buf == 0 or buf >= 0x0000_8000_0000_0000 or len == 0) return -1;
        const tcb_idx = t.fd_table.fds[fd].tcb_idx;
        return @import("../fs/namespace_policy.zig").sendResult(net_mod.tcp.tcpSendBlocking(tcb_idx, buf, true, len, net_mod.tcp_recv_policy.nonblockRequested(t.fd_table.fds[fd].status_flags, flags)), flags);
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
        } else {
            return -89; // EDESTADDRREQ — unconnected UDP socket, no destination given
        }
        if (udp.sendTo(dst_ip, dst_port, src_port, &tmp_buf2, @intCast(n2))) {
            return @intCast(n2);
        } else {
            return -1;
        }
    } else if (t.fd_table.fds[fd].fd_type == .unix_socket) {
        // AF_UNIX: connected sockets only (STREAM pair, or DGRAM after
        // connect() set a default peer). An explicit destination address is
        // not supported — unixSend routes through the established peer_idx.
        if (buf == 0 or buf >= 0x0000_8000_0000_0000 or len == 0) return -1;
        var tmp_unix: [8192]u8 = undefined;
        const to_copy_unix = @min(len, 8192);
        const n_unix = copy.copyFromUser(&tmp_unix, @ptrFromInt(buf), to_copy_unix);
        if (n_unix == 0) return -1;
        const unix_idx = t.fd_table.fds[fd].unix_sock_idx;
        return @import("../fs/namespace_policy.zig").sendResult(net_mod.unix_socket.unixSendBlocking(unix_idx, &tmp_unix, n_unix, @import("../fs/namespace_policy.zig").nonblockRequested(t.fd_table.fds[fd].status_flags, flags)), flags);
    } else {
        // Not a socket — use regular write
        var tmp_buf: [4096]u8 = undefined;
        const to_copy = @min(len, 4096);
        const n = copy.copyFromUser(&tmp_buf, @ptrFromInt(buf), to_copy);
        if (n == 0) return -1;
        const result = vfs_mod.FdTable.write(t.fd_table, fd, &tmp_buf, n);
        return result;
    }
}

/// Wait until a datagram is queued for `port`. Returns 0 when one is there (or
/// may be: the caller re-checks), -EAGAIN for a non-blocking socket or an
/// expired SO_RCVTIMEO, -EINTR when a signal ended the wait. The wait is a
/// series of short sleeps that also pump the loopback device, so a datagram
/// sent from another process on 127/8 arrives without an explicit net_poll.
fn udpWaitForDatagram(port: u16, is_v6: bool, nonblock: bool) i64 {
    const urp = @import("udp_recv_policy.zig");
    const tsc = @import("../arch/arch.zig").tsc;
    const lo = @import("lo.zig");
    const se = @import("../arch/x86_64/syscall_entry.zig");
    var deadline: ?u64 = null;
    var armed = false;
    while (true) {
        if (!armed) {
            const ms = if (udp.getPortOpts(port)) |o| o.rcv_ms else 0;
            deadline = urp.deadlineNs(tsc.nanos(), ms);
            armed = true;
        }
        _ = lo.drain();
        const step = urp.step(udp.hasQueuedDatagramFor(port, is_v6), nonblock, urp.timedOut(deadline, tsc.nanos()));
        switch (step) {
            .deliver => return 0,
            .eagain => return -11,
            .wait => {},
        }
        const now = tsc.nanos();
        const slice = now +| 5 * 1_000_000;
        const rc = se.sleepUntil(if (deadline) |d| @min(slice, d) else slice, 0);
        if (rc < 0) return rc;
    }
}

/// recvfrom(fd, buf, len, flags, addr_ptr, addr_len_ptr) → bytes received or -errno
pub fn recvfrom(fd: u32, buf: u64, len: u32, flags: u32, addr_ptr: u64, addr_len_ptr: u64) i64 {
    // UDP honors MSG_PEEK (leave the datagram queued) and MSG_TRUNC (report
    // the full datagram length even when the buffer is smaller). Other flag
    // bits keep the historical ignore behavior.
    const msg_peek = (flags & 0x02) != 0;
    const msg_trunc = (flags & 0x20) != 0;
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS) return -9;

    if (t.fd_table.fds[fd].fd_type == .unix_socket) {
        if (buf == 0 or buf >= 0x0000_8000_0000_0000 or len == 0) return -1;
        var tmp_buf: [8192]u8 = undefined;
        const to_read = @min(len, 8192);
        if (!copy.validateUserBufferWritable(buf, to_read)) return -14; // EFAULT
        const unix_idx = t.fd_table.fds[fd].unix_sock_idx;
        const result = net_mod.unix_socket.unixRecvBlocking(unix_idx, &tmp_buf, to_read, @import("../fs/namespace_policy.zig").nonblockRequested(t.fd_table.fds[fd].status_flags, flags));
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
        const nonblock = net_mod.tcp_recv_policy.nonblockRequested(t.fd_table.fds[fd].status_flags, flags);
        const result = net_mod.tcp.tcpRecvBlocking(tcb_idx, &tmp_buf, to_read, nonblock);
        if (result > 0) {
            const copied = copy.copyToUser(@ptrFromInt(buf), @as([*]const u8, @ptrCast(&tmp_buf))[0..@intCast(result)], @intCast(result));
            if (copied != @as(usize, @intCast(result))) return -14; // EFAULT
        }
        return result;
    } else if (t.fd_table.fds[fd].fd_type == .udp_socket) {
        if (buf == 0 or buf >= 0x0000_8000_0000_0000 or len == 0) return -1;
        const is_v6 = t.fd_table.fds[fd].udp_is_v6;
        const src_port = t.fd_table.fds[fd].udp_port;
        const wait_rc = udpWaitForDatagram(src_port, is_v6, @import("../fs/namespace_policy.zig").nonblockRequested(t.fd_table.fds[fd].status_flags, flags));
        if (wait_rc != 0) return wait_rc;
        var user_addr_len: u32 = 0;
        if (addr_ptr != 0) {
            if (addr_len_ptr == 0 or !copy.validateUserBufferWritable(addr_len_ptr, 4)) return -14;
            var len_bytes: [4]u8 = undefined;
            if (copy.copyFromUser(&len_bytes, @ptrFromInt(addr_len_ptr), 4) != 4) return -14;
            user_addr_len = @bitCast(len_bytes);
        }
        if (is_v6) {
            var tmp6: [1232]u8 = undefined;
            const to_read6 = @min(len, 1232);
            if (!copy.validateUserBufferWritable(buf, to_read6)) return -14; // EFAULT
            if (addr_ptr != 0) {
                const addr_copy_len = @min(user_addr_len, sa.SOCKADDR_IN6_LEN);
                if (addr_copy_len != 0 and !copy.validateUserBufferWritable(addr_ptr, addr_copy_len)) return -14;
            }
            var src6: [16]u8 = @splat(0);
            var src_port_out6: u16 = 0;
            var full_len6: u16 = 0;
            const result6 = udp.recvFromV6Ex(src_port, &tmp6, @intCast(tmp6.len), &src6, &src_port_out6, &full_len6, msg_peek);
            if (result6 > 0) {
                const to_write6 = @min(@as(u32, @intCast(result6)), to_read6);
                if (copy.copyToUser(@ptrFromInt(buf), @as([*]const u8, @ptrCast(&tmp6))[0..to_write6], to_write6) != to_write6) return -14;
                if (addr_ptr != 0 and addr_ptr < 0x0000_8000_0000_0000) {
                    var sa_out6: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
                    const alen = sa.writeInet6(&sa_out6, src_port_out6, src6, 0);
                    const addr_copy_len = @min(user_addr_len, alen);
                    if (addr_copy_len != 0 and copy.copyToUser(@ptrFromInt(addr_ptr), sa_out6[0..addr_copy_len], addr_copy_len) != addr_copy_len) return -14;
                    var al6: [4]u8 = .{
                        @truncate(alen),
                        @truncate(alen >> 8),
                        @truncate(alen >> 16),
                        @truncate(alen >> 24),
                    };
                    if (copy.copyToUser(@ptrFromInt(addr_len_ptr), &al6, 4) != 4) return -14;
                }
                return if (msg_trunc) @as(i64, full_len6) else @intCast(to_write6);
            }
            return 0;
        }
        var tmp_buf2: [1472]u8 = undefined;
        const to_read2 = @min(len, 1472);
        if (!copy.validateUserBufferWritable(buf, to_read2)) return -14; // EFAULT
        if (addr_ptr != 0) {
            const addr_copy_len = @min(user_addr_len, SOCKADDR_IN_MIN_LEN);
            if (addr_copy_len != 0 and !copy.validateUserBufferWritable(addr_ptr, addr_copy_len)) return -14;
        }
        var src_ip: [4]u8 = .{ 0, 0, 0, 0 };
        var src_port_out: u16 = 0;
        var full_len: u16 = 0;
        const result2 = udp.recvFromEx(src_port, &tmp_buf2, @intCast(tmp_buf2.len), &src_ip, &src_port_out, &full_len, msg_peek);
        if (result2 > 0) {
            const to_write = @min(@as(u32, @intCast(result2)), to_read2);
            if (copy.copyToUser(@ptrFromInt(buf), @as([*]const u8, @ptrCast(&tmp_buf2))[0..to_write], to_write) != to_write) return -14;
            if (addr_ptr != 0 and addr_ptr < 0x0000_8000_0000_0000) {
                var sa_out: [sa.SOCKADDR_IN_LEN]u8 = undefined;
                _ = sa.writeInet4(&sa_out, src_port_out, src_ip);
                const addr_copy_len = @min(user_addr_len, SOCKADDR_IN_MIN_LEN);
                if (addr_copy_len != 0 and copy.copyToUser(@ptrFromInt(addr_ptr), sa_out[0..addr_copy_len], addr_copy_len) != addr_copy_len) return -14;
                var al: [4]u8 = .{ 8, 0, 0, 0 };
                if (copy.copyToUser(@ptrFromInt(addr_len_ptr), &al, 4) != 4) return -14;
            }
            return if (msg_trunc) @as(i64, full_len) else @intCast(to_write);
        } else {
            return 0;
        }
    } else {
        // Not a socket — use regular read
        var tmp_buf: [4096]u8 = undefined;
        const to_read = @min(len, 4096);
        if (!copy.validateUserBufferWritable(buf, to_read)) return -14; // EFAULT
        const result = vfs_mod.FdTable.read(t.fd_table, fd, &tmp_buf, to_read);
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
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS) return -88;

    // AF_UNIX connect: sockaddr_un (family + path), routed to unixConnect.
    if (t.fd_table.fds[fd].fd_type == .unix_socket) {
        const unix_idx = t.fd_table.fds[fd].unix_sock_idx;
        if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000) return -14;
        if (!@import("socket_address_policy.zig").unixLengthValid(addr_len, SOCKADDR_UN_PATH_OFFSET)) return -22;
        var sock_addr_buf: [110]u8 = undefined;
        const to_copy = @min(@as(usize, addr_len), sock_addr_buf.len);
        const copied = copy.copyFromUser(sock_addr_buf[0..to_copy], @ptrFromInt(addr_ptr), to_copy);
        if (copied <= SOCKADDR_UN_PATH_OFFSET) return -22; // EINVAL
        var path_len: usize = 0;
        for (2..copied) |j| {
            if (sock_addr_buf[j] == 0) break;
            path_len += 1;
        }
        const result = net_mod.unix_socket.unixConnect(unix_idx, @ptrCast(sock_addr_buf[2 .. 2 + path_len].ptr), path_len);
        return @as(i64, result);
    }

    // UDP connect: set default destination
    if (t.fd_table.fds[fd].fd_type == .udp_socket) {
        if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000) return -14;
        if (t.fd_table.fds[fd].udp_is_v6) {
            if (!@import("socket_address_policy.zig").inetLengthValid(addr_len, true)) return -22;
            var sa6: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
            if (copy.copyFromUser(&sa6, @ptrFromInt(addr_ptr), sa.SOCKADDR_IN6_LEN) < sa.SOCKADDR_IN6_LEN)
                return -22;
            const parsed = sa.parseInet6(&sa6) orelse return -97;
            t.fd_table.fds[fd].udp_connected = true;
            t.fd_table.fds[fd].udp_dst_ip6 = parsed.addr;
            t.fd_table.fds[fd].udp_dst_port = parsed.port;
            return 0;
        }
        if (!@import("socket_address_policy.zig").inetLengthValid(addr_len, false)) return -22;
        var sock_addr: [8]u8 = undefined;
        if (copy.copyFromUser(&sock_addr, @ptrFromInt(addr_ptr), 8) != 8) return -14;
        if (bo.readU16BeAt(&sock_addr, 0) != 2) return -97;
        const dst_port = bo.readU16BeAt(&sock_addr, 2);
        const dst_ip = [4]u8{ sock_addr[4], sock_addr[5], sock_addr[6], sock_addr[7] };
        t.fd_table.fds[fd].udp_connected = true;
        t.fd_table.fds[fd].udp_dst_ip = dst_ip;
        t.fd_table.fds[fd].udp_dst_port = dst_port;
        return 0;
    }

    if (t.fd_table.fds[fd].fd_type != .tcp_socket) return -88;
    const tcb_idx = t.fd_table.fds[fd].tcb_idx;

    if (addr_ptr == 0 or addr_ptr >= 0x0000_8000_0000_0000) return -14;
    const info = net_mod.tcp.tcpGetAddrInfo(tcb_idx) orelse return -1;
    if (info.is_v6) {
        if (!@import("socket_address_policy.zig").inetLengthValid(addr_len, true)) return -22;
        var sa6: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
        if (copy.copyFromUser(&sa6, @ptrFromInt(addr_ptr), sa.SOCKADDR_IN6_LEN) < sa.SOCKADDR_IN6_LEN)
            return -22;
        const parsed = sa.parseInet6(&sa6) orelse return -97;
        return finishTcpConnect(t, fd, net_mod.tcp.tcpConnectSocketV6(tcb_idx, parsed.addr, parsed.port));
    }
    if (!@import("socket_address_policy.zig").inetLengthValid(addr_len, false)) return -22;
    var sock_addr: [8]u8 = undefined;
    if (copy.copyFromUser(&sock_addr, @ptrFromInt(addr_ptr), 8) != 8) return -14;
    if (!@import("socket_address_policy.zig").inet4FamilyValid(bo.readU16BeAt(&sock_addr, 0))) return -97;
    const port = bo.readU16BeAt(&sock_addr, 2);
    const ip = [4]u8{ sock_addr[4], sock_addr[5], sock_addr[6], sock_addr[7] };
    return finishTcpConnect(t, fd, net_mod.tcp.tcpConnectSocket(tcb_idx, ip, port));
}

/// connect() returns once the handshake is started: EINPROGRESS for a
/// non-blocking socket (completion shows up as POLLOUT, or POLLERR with the
/// reason in SO_ERROR), otherwise it waits for the outcome.
fn finishTcpConnect(t: *task_mod.Task, fd: u32, started: i64) i64 {
    if (started != 0) return started;
    if (net_mod.tcp_recv_policy.nonblockRequested(t.fd_table.fds[fd].status_flags, 0)) return -115; // EINPROGRESS
    return net_mod.tcp.tcpWaitConnected(t.fd_table.fds[fd].tcb_idx);
}

fn copySockaddrToUser(addr_ptr: u64, addrlen_ptr: u64, sa_buf: []const u8, alen: u32) i64 {
    if (!copy.validateUserBuffer(addrlen_ptr, 4)) return -14;
    var len_bytes: [4]u8 = undefined;
    if (copy.copyFromUser(&len_bytes, @ptrFromInt(addrlen_ptr), 4) != 4) return -14;
    const user_len: u32 = @bitCast(len_bytes);
    const to_copy = @min(@min(user_len, alen), @as(u32, @intCast(sa_buf.len)));
    if (!copy.validateUserRange(addr_ptr, to_copy) or
        !copy.validateUserBufferWritable(addrlen_ptr, 4)) return -14;
    if (to_copy != 0) {
        if (!copy.validateUserBufferWritable(addr_ptr, to_copy)) return -14;
        if (copy.copyToUser(@ptrFromInt(addr_ptr), sa_buf[0..to_copy], to_copy) != to_copy) return -14;
    }
    len_bytes = @bitCast(alen);
    if (copy.copyToUser(@ptrFromInt(addrlen_ptr), &len_bytes, 4) != 4) return -14;
    return 0;
}

/// getsockname(fd, addr_ptr, addrlen_ptr) → 0 or -errno
pub fn getsockname(fd: u32, addr_ptr: u64, addrlen_ptr: u64) i64 {
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
    if (!@import("socket_policy.zig").shutdownHowValid(how)) return -22;
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS or cur.fd_table.fds[fd].fd_type == .none) return -9; // EBADF
    if (cur.fd_table.fds[fd].fd_type == .unix_socket) {
        return net_mod.unix_socket.unixShutdown(cur.fd_table.fds[fd].unix_sock_idx, how);
    }
    if (cur.fd_table.fds[fd].fd_type != .tcp_socket) return -88; // ENOTSOCK
    const result = net_mod.tcp.tcpShutdown(cur.fd_table.fds[fd].tcb_idx, how);
    return result;
}

/// Gather an iovec array into `dst`; returns the byte count or a negative errno.
fn gatherIov(iov_ptr: u64, iov_len: u64, dst: []u8) i64 {
    var total: usize = 0;
    var i: usize = 0;
    while (i < iov_len and total < dst.len) : (i += 1) {
        var iov_buf: [16]u8 = undefined;
        if (copy.copyFromUser(&iov_buf, @ptrFromInt(iov_ptr + @as(u64, @intCast(i)) * 16), 16) != 16) return -14;
        const base = bo.readU64At(&iov_buf, 0);
        const sz: usize = @intCast(@min(bo.readU64At(&iov_buf, 8), dst.len - total));
        if (sz == 0) continue;
        if (base == 0 or base >= 0x0000_8000_0000_0000) return -14;
        if (copy.copyFromUser(dst[total..][0..sz], @ptrFromInt(base), sz) != sz) return -14;
        total += sz;
    }
    return @intCast(total);
}

/// sendmsg on an AF_UNIX socket: the iovec bytes plus optional SCM_RIGHTS.
fn unixSendmsg(cur: *task_mod.Task, fd: u32, msghdr: *const [56]u8) i64 {
    const sp = @import("scm_policy.zig");
    const iov_ptr: u64 = bo.readU64At(msghdr, 16);
    const iov_len: u64 = bo.readU64At(msghdr, 24);
    const ctl_ptr: u64 = bo.readU64At(msghdr, 32);
    const ctl_len: u64 = bo.readU64At(msghdr, 40);
    if (iov_len > 1024) return -22;
    if (iov_len != 0 and (iov_ptr == 0 or iov_ptr >= 0x0000_8000_0000_0000)) return -14;

    var rights: net_mod.unix_socket.RightsIn = .{};
    if (ctl_ptr != 0 and ctl_len != 0) {
        if (ctl_len > 256 or ctl_ptr >= 0x0000_8000_0000_0000) return -22;
        var ctl: [256]u8 = undefined;
        const n: usize = @intCast(ctl_len);
        if (copy.copyFromUser(ctl[0..n], @ptrFromInt(ctl_ptr), n) != n) return -14;
        const parsed = switch (sp.parseRights(ctl[0..n])) {
            .ok => |p| p,
            .err => |e| return if (e == .too_many) @as(i64, -22) else @as(i64, -22),
        };
        for (parsed.fds[0..parsed.count]) |raw| {
            if (raw < 0 or @as(u32, @intCast(raw)) >= vfs_mod.MAX_FDS) {
                releaseRights(&rights);
                return -9; // EBADF
            }
            const snap = vfs_mod.snapshotForPassing(cur.fd_table, @intCast(raw)) orelse {
                releaseRights(&rights);
                return -9; // EBADF (closed, or a kind that cannot be passed)
            };
            rights.descs[rights.count] = snap;
            rights.count += 1;
        }
    }

    var data: [8192]u8 = undefined;
    const got = gatherIov(iov_ptr, iov_len, &data);
    if (got < 0) {
        releaseRights(&rights);
        return got;
    }
    const idx = cur.fd_table.fds[fd].unix_sock_idx;
    // A descriptor set rides on at least one data byte.
    if (rights.count > 0 and got == 0) {
        releaseRights(&rights);
        return -22;
    }
    const sent = net_mod.unix_socket.unixSendRights(idx, &data, @intCast(got), &rights);
    releaseRights(&rights); // still held only if the send did not take them
    return sent;
}

fn releaseRights(r: *net_mod.unix_socket.RightsIn) void {
    for (r.descs[0..r.count]) |*d| vfs_mod.releaseDescriptor(d);
    r.count = 0;
}

/// recvmsg on an AF_UNIX socket: scatter the bytes, install received
/// descriptors, and write the control message, msg_controllen and msg_flags.
fn unixRecvmsg(cur: *task_mod.Task, fd: u32, msg_ptr: u64, msghdr: *const [56]u8, flags: u32) i64 {
    const sp = @import("scm_policy.zig");
    const iov_ptr: u64 = bo.readU64At(msghdr, 16);
    const iov_len: u64 = bo.readU64At(msghdr, 24);
    const ctl_ptr: u64 = bo.readU64At(msghdr, 32);
    const ctl_len: u64 = bo.readU64At(msghdr, 40);
    if (iov_len > 1024) return -22;
    if (iov_len != 0 and (iov_ptr == 0 or iov_ptr >= 0x0000_8000_0000_0000)) return -14;
    const want_ctl = ctl_ptr != 0 and ctl_len >= sp.HDR;

    // Total room across the iovecs.
    var room: usize = 0;
    var i: usize = 0;
    while (i < iov_len) : (i += 1) {
        var iov_buf: [16]u8 = undefined;
        if (copy.copyFromUser(&iov_buf, @ptrFromInt(iov_ptr + @as(u64, @intCast(i)) * 16), 16) != 16) return -14;
        room += @intCast(@min(bo.readU64At(&iov_buf, 8), 8192));
        if (room >= 8192) {
            room = 8192;
            break;
        }
    }
    if (room == 0) return 0;

    var data: [8192]u8 = undefined;
    var out: net_mod.unix_socket.RightsOut = .{};
    const idx = cur.fd_table.fds[fd].unix_sock_idx;
    const nonblock = @import("../fs/namespace_policy.zig").nonblockRequested(cur.fd_table.fds[fd].status_flags, flags);
    // Always ask for the set: a receiver without a control buffer still must
    // learn (MSG_CTRUNC) that descriptors were dropped.
    const n = net_mod.unix_socket.unixRecvBlockingRights(idx, &data, room, nonblock, &out);
    if (n < 0) return n;

    // Scatter the bytes.
    var done: usize = 0;
    i = 0;
    while (i < iov_len and done < @as(usize, @intCast(n))) : (i += 1) {
        var iov_buf: [16]u8 = undefined;
        if (copy.copyFromUser(&iov_buf, @ptrFromInt(iov_ptr + @as(u64, @intCast(i)) * 16), 16) != 16) break;
        const base = bo.readU64At(&iov_buf, 0);
        const sz: usize = @intCast(@min(bo.readU64At(&iov_buf, 8), @as(u64, @intCast(n)) - done));
        if (sz == 0) continue;
        if (copy.copyToUser(@ptrFromInt(base), data[done..][0..sz], sz) != sz) break;
        done += sz;
    }

    // Install the descriptors and build the control message.
    var out_flags: u32 = 0;
    var written: usize = 0;
    if (out.count > 0 and !want_ctl) {
        for (out.descs[0..out.count]) |*d| vfs_mod.releaseDescriptor(d);
        out_flags |= sp.MSG_CTRUNC;
    } else if (out.count > 0) {
        const cloexec = (flags & sp.MSG_CMSG_CLOEXEC) != 0;
        var newfds: [sp.MAX_FDS]i32 = undefined;
        var installed: usize = 0;
        for (out.descs[0..out.count]) |d| {
            if (installed >= @as(usize, @intCast(@min(ctl_len -| sp.HDR, 4 * sp.MAX_FDS))) / 4) {
                vfs_mod.releaseDescriptor(&d);
                out_flags |= sp.MSG_CTRUNC;
                continue;
            }
            if (vfs_mod.installPassed(cur.fd_table, d, cloexec)) |slot| {
                newfds[installed] = @intCast(slot);
                installed += 1;
            } else {
                vfs_mod.releaseDescriptor(&d);
                out_flags |= sp.MSG_CTRUNC;
            }
        }
        if (installed > 0) {
            var ctl: [256]u8 = undefined;
            const b = sp.buildRights(newfds[0..installed], @intCast(@min(ctl_len, 256)), &ctl);
            written = b.written;
            if (written > 0 and copy.copyToUser(@ptrFromInt(ctl_ptr), ctl[0..written], written) != written) {
                for (newfds[0..installed]) |nf| _ = cur.fd_table.close(@intCast(nf));
                return -14;
            }
        }
    }
    // msg_controllen and msg_flags
    var tail: [8]u8 = undefined;
    bo.writeU64Le(&tail, written);
    _ = copy.copyToUser(@ptrFromInt(msg_ptr + 40), &tail, 8);
    var fl: [4]u8 = undefined;
    bo.writeU32Le(&fl, out_flags);
    _ = copy.copyToUser(@ptrFromInt(msg_ptr + 48), &fl, 4);
    return n;
}

/// sendmsg on a UDP socket: gather the iovecs into one datagram and send it
/// through sendto (destination from msg_name, or the connected peer).
fn udpSendmsg(fd: u32, msghdr: *const [56]u8) i64 {
    const name_ptr: u64 = bo.readU64At(msghdr, 0);
    const name_len: u32 = bo.readU32Le(msghdr[8..12]);
    const iov_ptr: u64 = bo.readU64At(msghdr, 16);
    const iov_len: u64 = bo.readU64At(msghdr, 24);
    if (iov_len > 1024) return -22;
    if (iov_len != 0 and (iov_ptr == 0 or iov_ptr >= 0x0000_8000_0000_0000)) return -14;
    var data: [1472]u8 = undefined;
    const got = gatherIov(iov_ptr, iov_len, &data);
    if (got < 0) return got;
    if (got == 0) return 0;
    return udpSendBytes(fd, data[0..@intCast(got)], name_ptr, name_len);
}

/// Send `payload` as one datagram on UDP socket `fd` (the sendto UDP path
/// without the user-buffer copy).
fn udpSendBytes(fd: u32, payload: []const u8, addr_ptr: u64, addr_len: u32) i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;
    const d = &t.fd_table.fds[fd];
    const src_port = d.udp_port;
    if (d.udp_is_v6) {
        var dst6: [16]u8 = @splat(0);
        var dst_port6: u16 = 0;
        if (addr_ptr != 0 and addr_ptr < 0x0000_8000_0000_0000) {
            if (addr_len < sa.SOCKADDR_IN6_LEN) return -22;
            var sa6: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
            if (copy.copyFromUser(&sa6, @ptrFromInt(addr_ptr), sa.SOCKADDR_IN6_LEN) < sa.SOCKADDR_IN6_LEN) return -22;
            const parsed = sa.parseInet6(&sa6) orelse return -97;
            dst6 = parsed.addr;
            dst_port6 = parsed.port;
        } else if (d.udp_connected) {
            dst6 = d.udp_dst_ip6;
            dst_port6 = d.udp_dst_port;
        } else return -89;
        const n6 = @min(payload.len, 1232);
        return if (udp.sendToV6(dst6, dst_port6, src_port, payload.ptr, @intCast(n6))) @intCast(n6) else -1;
    }
    var dst_ip: [4]u8 = .{ 0, 0, 0, 0 };
    var dst_port: u16 = 0;
    if (addr_ptr != 0 and addr_ptr < 0x0000_8000_0000_0000) {
        if (addr_len < SOCKADDR_IN_MIN_LEN) return -22;
        var sa_buf: [16]u8 = undefined;
        if (copy.copyFromUser(sa_buf[0..SOCKADDR_IN_MIN_LEN], @ptrFromInt(addr_ptr), SOCKADDR_IN_MIN_LEN) != SOCKADDR_IN_MIN_LEN) return -14;
        dst_port = bo.readU16BeAt(&sa_buf, 2);
        dst_ip = .{ sa_buf[4], sa_buf[5], sa_buf[6], sa_buf[7] };
    } else if (d.udp_connected) {
        dst_ip = d.udp_dst_ip;
        dst_port = d.udp_dst_port;
    } else return -89;
    const n = @min(payload.len, 1472);
    return if (udp.sendTo(dst_ip, dst_port, src_port, payload.ptr, @intCast(n))) @intCast(n) else -1;
}

/// recvmsg on a UDP socket: wait like recvfrom, scatter the datagram over the
/// iovecs, fill msg_name, and report MSG_TRUNC in msg_flags.
fn udpRecvmsg(cur: *task_mod.Task, fd: u32, msg_ptr: u64, msghdr: *const [56]u8, flags: u32) i64 {
    const name_ptr: u64 = bo.readU64At(msghdr, 0);
    const name_len: u32 = bo.readU32Le(msghdr[8..12]);
    const iov_ptr: u64 = bo.readU64At(msghdr, 16);
    const iov_len: u64 = bo.readU64At(msghdr, 24);
    if (iov_len > 1024) return -22;
    if (iov_len != 0 and (iov_ptr == 0 or iov_ptr >= 0x0000_8000_0000_0000)) return -14;
    const d = &cur.fd_table.fds[fd];
    const is_v6 = d.udp_is_v6;
    const port = d.udp_port;
    const wait_rc = udpWaitForDatagram(port, is_v6, @import("../fs/namespace_policy.zig").nonblockRequested(d.status_flags, flags));
    if (wait_rc != 0) return wait_rc;

    var data: [1472]u8 = undefined;
    var full: u16 = 0;
    var got: i64 = 0;
    var src4: [4]u8 = .{ 0, 0, 0, 0 };
    var src6: [16]u8 = @splat(0);
    var src_port: u16 = 0;
    const peek = (flags & 0x02) != 0;
    if (is_v6) {
        got = udp.recvFromV6Ex(port, &data, @intCast(data.len), &src6, &src_port, &full, peek);
    } else {
        got = udp.recvFromEx(port, &data, @intCast(data.len), &src4, &src_port, &full, peek);
    }
    if (got < 0) return got;

    // Scatter.
    var done: usize = 0;
    var i: usize = 0;
    while (i < iov_len and done < @as(usize, @intCast(got))) : (i += 1) {
        var iov_buf: [16]u8 = undefined;
        if (copy.copyFromUser(&iov_buf, @ptrFromInt(iov_ptr + @as(u64, @intCast(i)) * 16), 16) != 16) break;
        const base = bo.readU64At(&iov_buf, 0);
        const sz: usize = @intCast(@min(bo.readU64At(&iov_buf, 8), @as(u64, @intCast(got)) - done));
        if (sz == 0) continue;
        if (base == 0 or base >= 0x0000_8000_0000_0000) return -14;
        if (copy.copyToUser(@ptrFromInt(base), data[done..][0..sz], sz) != sz) return -14;
        done += sz;
    }

    // msg_name / msg_namelen
    if (name_ptr != 0 and name_ptr < 0x0000_8000_0000_0000) {
        var out: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
        const alen: u32 = if (is_v6) sa.writeInet6(&out, src_port, src6, 0) else sa.writeInet4(&out, src_port, src4);
        const n = @min(name_len, alen);
        if (n != 0 and copy.copyToUser(@ptrFromInt(name_ptr), out[0..n], n) != n) return -14;
        var al: [4]u8 = undefined;
        bo.writeU32Le(&al, alen);
        _ = copy.copyToUser(@ptrFromInt(msg_ptr + 8), &al, 4);
    }
    // msg_controllen and msg_flags
    var z8: [8]u8 = @splat(0);
    _ = copy.copyToUser(@ptrFromInt(msg_ptr + 40), &z8, 8);
    const truncated = @as(usize, full) > done;
    var fl: [4]u8 = undefined;
    bo.writeU32Le(&fl, if (truncated) @as(u32, 0x20) else 0);
    _ = copy.copyToUser(@ptrFromInt(msg_ptr + 48), &fl, 4);
    return if ((flags & 0x20) != 0) @as(i64, full) else @intCast(done);
}

/// sendmsg(fd, msg_ptr, flags) → bytes sent or -errno
pub fn sendmsg(fd: u32, msg_ptr: u64, flags: u32) i64 {
    if (msg_ptr == 0 or msg_ptr >= 0x0000_8000_0000_0000) return -22;

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (fd < vfs_mod.MAX_FDS and cur.fd_table.fds[fd].fd_type == .unix_socket) {
        var hdr: [56]u8 = undefined;
        if (copy.copyFromUser(&hdr, @ptrFromInt(msg_ptr), 56) != 56) return -14;
        return @import("../fs/namespace_policy.zig").sendResult(unixSendmsg(cur, fd, &hdr), flags);
    }
    if (fd < vfs_mod.MAX_FDS and cur.fd_table.fds[fd].fd_type == .udp_socket) {
        var hdr: [56]u8 = undefined;
        if (copy.copyFromUser(&hdr, @ptrFromInt(msg_ptr), 56) != 56) return -14;
        return udpSendmsg(fd, &hdr);
    }
    if (fd >= vfs_mod.MAX_FDS or cur.fd_table.fds[fd].fd_type != .tcp_socket) return -88;

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
        const result = net_mod.tcp.tcpSendBlocking(tcb_idx, iov_base, true, to_send, net_mod.tcp_recv_policy.nonblockRequested(cur.fd_table.fds[fd].status_flags, flags));
        if (result <= 0) {
            if (total == 0) return @import("../fs/namespace_policy.zig").sendResult(result, flags);
            break;
        }
        total += @intCast(result);
        if (result < to_send) break;
    }
    return @intCast(total);
}

/// recvmsg(fd, msg_ptr, flags) → bytes received or -errno
pub fn recvmsg(fd: u32, msg_ptr: u64, flags: u32) i64 {
    if (msg_ptr == 0 or msg_ptr >= 0x0000_8000_0000_0000) return -14;

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (fd < vfs_mod.MAX_FDS and cur.fd_table.fds[fd].fd_type == .unix_socket) {
        var hdr: [56]u8 = undefined;
        if (copy.copyFromUser(&hdr, @ptrFromInt(msg_ptr), 56) != 56) return -14;
        return unixRecvmsg(cur, fd, msg_ptr, &hdr, flags);
    }
    if (fd < vfs_mod.MAX_FDS and cur.fd_table.fds[fd].fd_type == .udp_socket) {
        var hdr: [56]u8 = undefined;
        if (copy.copyFromUser(&hdr, @ptrFromInt(msg_ptr), 56) != 56) return -14;
        return udpRecvmsg(cur, fd, msg_ptr, &hdr, flags);
    }
    if (flags != 0) return -22;
    if (fd >= vfs_mod.MAX_FDS or cur.fd_table.fds[fd].fd_type != .tcp_socket) return -88;

    var msghdr_buf: [56]u8 = undefined;
    const hdr_copied = copy.copyFromUser(&msghdr_buf, @ptrFromInt(msg_ptr), 56);
    if (hdr_copied != msghdr_buf.len) return -14;

    const iov_ptr: u64 = bo.readU64At(&msghdr_buf, 16);
    const iov_len: u64 = bo.readU64At(&msghdr_buf, 24);

    if (iov_ptr == 0 or iov_ptr >= 0x0000_8000_0000_0000) return -14;
    if (iov_len == 0 or iov_len > 1024) return -22;

    const tcb_idx = cur.fd_table.fds[fd].tcb_idx;
    var total: usize = 0;

    for (0..@as(usize, @intCast(iov_len))) |i| {
        var iov_buf: [16]u8 = undefined;
        const src: [*]const u8 = @ptrFromInt(iov_ptr + @as(u64, @intCast(i)) * 16);
        const iov_copied = copy.copyFromUser(&iov_buf, src, 16);
        if (iov_copied != iov_buf.len) return -14;

        const iov_base: u64 = bo.readU64At(&iov_buf, 0);
        const iov_sz: u64 = bo.readU64At(&iov_buf, 8);

        if (iov_base == 0 or iov_base >= 0x0000_8000_0000_0000) return -14;
        if (iov_sz == 0) return -22;

        var tmp: [4096]u8 = undefined;
        const to_read: u32 = @intCast(@min(iov_sz, 4096));
        if (!copy.validateUserBufferWritable(iov_base, to_read)) return if (total == 0) -14 else @intCast(total);
        // Only the first segment may wait: once bytes were delivered, a
        // further empty ring ends the call with the short count (stream
        // semantics), never a second sleep.
        const nonblock = total != 0 or net_mod.tcp_recv_policy.nonblockRequested(cur.fd_table.fds[fd].status_flags, 0);
        const result = net_mod.tcp.tcpRecvBlocking(tcb_idx, &tmp, to_read, nonblock);
        if (result > 0) {
            const copied = copy.copyToUser(@ptrFromInt(iov_base), &tmp, @intCast(result));
            if (copied != @as(usize, @intCast(result))) return if (total == 0) -14 else @intCast(total);
            total += @intCast(result);
        }
        // An empty-ring -EAGAIN must not collapse into a 0 (EOF) return.
        if (result < 0 and total == 0) return result;
        if (result <= 0) break;
    }
    return @intCast(total);
}

/// socketpair(domain, type, protocol, sv_ptr) → 0 or -errno
pub fn socketpair(domain: u32, sock_type: u32, protocol: u32, sv_ptr: u64) i64 {
    const policy_result = socketpair_policy.validate(domain, sock_type, protocol);
    if (policy_result != 0) return policy_result;
    if (!copy.validateUserBufferWritable(sv_ptr, 8)) return -14;

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    const pair_result = net_mod.unix_socket.unixSocketPair();
    if (pair_result < 0) return if (pair_result == -24) -24 else -12;
    const first_idx: u32 = @intCast(pair_result & 0xff);
    const second_idx: u32 = @intCast((@as(u32, @intCast(pair_result)) >> 8) & 0xff);
    const pair_cred: @import("sockopt_policy.zig").Cred = .{ .pid = @intCast(if (cur.is_thread and cur.parent_tid != 0) cur.parent_tid else cur.tid), .uid = cur.euid, .gid = cur.egid };
    net_mod.unix_socket.unixSetCred(first_idx, pair_cred);
    net_mod.unix_socket.unixSetCred(second_idx, pair_cred);
    const first_fd = cur.fd_table.allocFd() orelse {
        net_mod.unix_socket.unixClose(first_idx);
        net_mod.unix_socket.unixClose(second_idx);
        return -24;
    };
    cur.fd_table.fds[first_fd] = .{
        .fd_type = .unix_socket,
        .unix_sock_idx = first_idx,
        .writable = true,
        .fd_flags = if ((sock_type & socketpair_policy.SOCK_CLOEXEC) != 0) 1 else 0,
        .status_flags = sock_type & socketpair_policy.SOCK_NONBLOCK,
    };
    cur.fd_table.publishFd(first_fd);
    const second_fd = cur.fd_table.allocFd() orelse {
        _ = cur.fd_table.close(first_fd);
        net_mod.unix_socket.unixClose(second_idx);
        return -24;
    };
    cur.fd_table.fds[second_fd] = .{
        .fd_type = .unix_socket,
        .unix_sock_idx = second_idx,
        .writable = true,
        .fd_flags = if ((sock_type & socketpair_policy.SOCK_CLOEXEC) != 0) 1 else 0,
        .status_flags = sock_type & socketpair_policy.SOCK_NONBLOCK,
    };
    cur.fd_table.publishFd(second_fd);
    var fds: [8]u8 = undefined;
    bo.writeU32Le(fds[0..4], first_fd);
    bo.writeU32Le(fds[4..8], second_fd);
    if (copy.copyToUser(@ptrFromInt(sv_ptr), &fds, 8) != 8) {
        _ = cur.fd_table.close(first_fd);
        _ = cur.fd_table.close(second_fd);
        return -14;
    }
    return 0;
}

/// net_poll() → count of packets processed
pub fn netPoll() i64 {
    const nic = @import("nic.zig");
    const lo = @import("lo.zig");
    var count: u64 = 0;
    if (nic.isActive()) {
        var rx_tmp: [2048]u8 = undefined;
        var poll_limit: u32 = 0;
        while (poll_limit < 16) {
            const n = nic.receivePacket(&rx_tmp, 2048);
            if (n == 0) break;
            net_mod.handleRxPacket(&rx_tmp, n);
            count += 1;
            poll_limit += 1;
        }
    }
    // F2: deliver frames queued on the loopback device (runs even when no
    // hardware NIC is active — lo traffic must not depend on one).
    count += lo.drain();
    return @intCast(count);
}

/// Validate one mmsghdr of a batch: the header and its iovec array must be
/// readable; for receives the buffers must be writable, for sends readable.
fn batchEntryOk(entry_ptr: u64, receiving: bool) i64 {
    if (!copy.validateUserBuffer(entry_ptr, 56)) return -14;
    if (receiving and !copy.validateUserBufferWritable(entry_ptr + 56, 4)) return -14;
    if (!receiving and !copy.validateUserBuffer(entry_ptr + 56, 4)) return -14;
    var header: [56]u8 = undefined;
    if (copy.copyFromUser(&header, @ptrFromInt(entry_ptr), 56) < 32) return -14;
    const iov_ptr = bo.readU64At(&header, 16);
    const iov_len = bo.readU64At(&header, 24);
    if (iov_len == 0) return 0; // an empty message (no buffers) is legal
    if (iov_len > 1024 or iov_ptr == 0 or iov_ptr > 0x0000_8000_0000_0000 -| iov_len * 16) return -22;
    if (!copy.validateUserBuffer(iov_ptr, @intCast(iov_len * 16))) return -14;
    for (0..@as(usize, @intCast(iov_len))) |j| {
        var iov: [16]u8 = undefined;
        if (copy.copyFromUser(&iov, @ptrFromInt(iov_ptr + @as(u64, @intCast(j)) * 16), 16) != 16) return -14;
        const base = bo.readU64At(&iov, 0);
        const len = bo.readU64At(&iov, 8);
        if (len == 0) continue;
        if (base == 0 or base >= 0x0000_8000_0000_0000 or len > 0x0000_8000_0000_0000 - base) return if (receiving) -14 else -22;
        const n: usize = @intCast(@min(len, 0xFFFF_FFFF));
        if (receiving) {
            if (!copy.validateUserBufferWritable(base, n)) return -14;
        } else if (!copy.validateUserBuffer(base, n)) return -14;
    }
    return 0;
}

/// recvmmsg(sockfd, msgvec, vlen, flags, timeout) → count or -errno
pub fn recvmmsg(sockfd: u32, msgvec_ptr: u64, vlen_raw: u64, flags: u32, timeout: u64) i64 {
    const mp = message_batch_policy;
    const flag_rc = mp.validateRecvFlags(flags);
    if (flag_rc != 0) return flag_rc;
    const vlen = mp.clampVlen(vlen_raw);
    if (vlen == 0) return 0;
    if (msgvec_ptr == 0 or msgvec_ptr >= 0x0000_8000_0000_0000) return -14;

    // Optional struct timespec: the batch ends between messages once it passed.
    const tsc = @import("../arch/arch.zig").tsc;
    var deadline: ?u64 = null;
    if (timeout != 0) {
        var raw: [16]u8 = undefined;
        if (!copy.validateUserBuffer(timeout, 16) or copy.copyFromUser(&raw, @ptrFromInt(timeout), 16) != 16) return -14;
        switch (mp.timeoutDeadline(true, @bitCast(bo.readU64Le(raw[0..8])), @bitCast(bo.readU64Le(raw[8..16])), tsc.nanos())) {
            .none => {},
            .deadline => |d| deadline = d,
            .invalid => return -22,
        }
    }

    // Preflight every entry so a first-message failure cannot leave a partial
    // batch of user-visible writes behind.
    for (0..@as(usize, @intCast(vlen))) |i| {
        const rc = batchEntryOk(msgvec_ptr + @as(u64, @intCast(i)) * 64, true);
        if (rc != 0) return rc;
    }

    var count: u64 = 0;
    for (0..@as(usize, @intCast(vlen))) |i| {
        const entry_ptr = msgvec_ptr + @as(u64, @intCast(i)) * 64;
        const result = recvmsg(sockfd, entry_ptr, mp.messageFlags(flags, count));
        if (result < 0) return mp.batchResult(count, result);

        var len_buf: [4]u8 = undefined;
        bo.writeU32Le(&len_buf, @intCast(result));
        if (copy.copyToUser(@ptrFromInt(entry_ptr + 56), &len_buf, 4) != 4) return mp.batchResult(count, -14);
        count += 1;
        if (mp.expired(deadline, tsc.nanos())) break;
    }
    return @intCast(count);
}

/// sendmmsg(sockfd, msgvec, vlen, flags) → count or -errno
pub fn sendmmsg(sockfd: u32, msgvec_ptr: u64, vlen_raw: u64, flags: u32) i64 {
    const mp = message_batch_policy;
    const flag_rc = mp.validateSendFlags(flags);
    if (flag_rc != 0) return flag_rc;
    const vlen = mp.clampVlen(vlen_raw);
    if (vlen == 0) return 0;
    if (msgvec_ptr == 0 or msgvec_ptr >= 0x0000_8000_0000_0000) return -14;

    // Validate every header and its iovec descriptors before sending anything;
    // this preserves the no-mutation-on-first-failure contract.
    for (0..@as(usize, @intCast(vlen))) |i| {
        const rc = batchEntryOk(msgvec_ptr + @as(u64, @intCast(i)) * 64, false);
        if (rc != 0) return rc;
    }

    var count: u64 = 0;
    for (0..@as(usize, @intCast(vlen))) |i| {
        const entry_ptr = msgvec_ptr + @as(u64, @intCast(i)) * 64;
        const result = sendmsg(sockfd, entry_ptr, flags);
        if (result < 0) return mp.batchResult(count, result);
        var len_buf: [4]u8 = undefined;
        bo.writeU32Le(&len_buf, @intCast(result));
        if (copy.copyToUser(@ptrFromInt(entry_ptr + 56), &len_buf, 4) != 4) return mp.batchResult(count, -14);
        count += 1;
    }
    return @intCast(count);
}
