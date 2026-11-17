/// Socket option constants and setsockopt/getsockopt implementation.
///
/// Supports SOL_SOCKET and SOL_TCP level options for TCP sockets.
/// Options are stored per-TCB in the SocketOptions struct.
const bo = @import("../lib/byte_order.zig");

// ─── Socket Level ─────────────────────────────────────────────────────────

pub const SOL_SOCKET: u64 = 1;
pub const SOL_TCP: u64 = 6; // IPPROTO_TCP

// ─── SOL_SOCKET Options ───────────────────────────────────────────────────

pub const SO_REUSEADDR: u64 = 2;
pub const SO_KEEPALIVE: u64 = 9;
pub const SO_RCVTIMEO: u64 = 20;
pub const SO_SNDTIMEO: u64 = 21;
pub const SO_RCVBUF: u64 = 8;
pub const SO_SNDBUF: u64 = 7;
pub const SO_ERROR: u64 = 4;
pub const SO_LINGER: u64 = 13;

// ─── SOL_TCP Options ──────────────────────────────────────────────────────

pub const TCP_NODELAY: u64 = 1;
pub const TCP_CORK: u64 = 3;
pub const TCP_QUICKACK: u64 = 12;
pub const TCP_KEEPIDLE: u64 = 4;
pub const TCP_KEEPINTVL: u64 = 5;
pub const TCP_KEEPCNT: u64 = 6;

// ─── Per-Socket Option Storage ────────────────────────────────────────────

pub const SocketOptions = struct {
    reuse_addr: bool = false,
    keep_alive: bool = false,
    tcp_nodelay: bool = false, // disable Nagle (default: off → Nagle enabled)
    tcp_cork: bool = false, // coalesce writes into full MSS segments
    tcp_quickack: bool = false, // disable delayed ACK
    rcv_timeout_ms: u32 = 0, // 0 = no timeout
    snd_timeout_ms: u32 = 0,
    rcv_buf_size: u32 = 16384,
    snd_buf_size: u32 = 16384,
    /// SO_PRIORITY / SO_MARK / SO_BINDTODEVICE (see sockopt_policy.Stored).
    priority: i32 = 0,
    mark: u32 = 0,
    bound_if: u8 = 0,
    /// IP_TTL / IP_TOS / IPV6_UNICAST_HOPS / IPV6_TCLASS (0 = default).
    ip: @import("ip_opt_policy.zig").IpOpts = .{},
    /// TCP_MAXSEG set by the user (0 = none): caps the segment size.
    user_mss: u32 = 0,
    /// SO_RCVBUF / SO_SNDBUF were set: the sizes above then bound the TCP buffering.
    rcv_buf_set: bool = false,
    snd_buf_set: bool = false,
    keep_idle: u32 = 7200, // seconds before first keepalive probe
    keep_intvl: u32 = 75, // seconds between keepalive probes
    keep_cnt: u32 = 9, // number of keepalive probes before dropping
    /// TCP_USER_TIMEOUT in ms (0: off): how long unacknowledged data or unanswered keepalives may go before the connection gives up.
    user_timeout_ms: u32 = 0,
    /// SO_REUSEPORT / SO_BROADCAST / SO_DEBUG bits (sockopt_policy.flagBit).
    extra_flags: u16 = 0,
    so_error: i32 = 0,
    linger_on: bool = false,
    linger_sec: u32 = 0,
};

fn timeoutMs(sec: i64, usec: i64) ?u32 {
    const max_ms: u64 = 0xFFFF_FFFF;
    if (sec < 0 or usec < 0 or usec >= 1_000_000) return null;

    const seconds: u64 = @intCast(sec);
    // Bound before scaling so a valid but huge timeval saturates safely.
    if (seconds > max_ms / 1000) return @intCast(max_ms);
    const total_ms = seconds * 1000 + @as(u64, @intCast(usec)) / 1000;
    return @intCast(@min(total_ms, max_ms));
}

// ─── Resolve fd → SocketOptions pointer ───────────────────────────────────

fn resolveTcpIdx(fd: u64) ?u32 {
    const fd_u32: u32 = @truncate(fd);
    const vfs_mod = @import("../fs/vfs.zig");
    if (fd_u32 >= vfs_mod.MAX_FDS) return null;
    const sched_mod = @import("../proc/sched.zig");
    const cur_idx = sched_mod.currentTaskIndex() orelse return null;
    const task_mod = @import("../proc/task.zig");
    const t = task_mod.getTask(cur_idx) orelse return null;
    if (t.fd_table.fds[fd_u32].fd_type != .tcp_socket) return null;
    return t.fd_table.fds[fd_u32].tcb_idx;
}

// v53.14: resolveTcpOpts removed — use resolveTcpIdx + tcpGetOptions/tcpSetOptions instead

// ─── Dispatch by socket kind ──────────────────────────────────────────────
//
// SOL_SOCKET options live in sockopt_policy.Stored for UDP and AF_UNIX
// sockets and in the TCB (SocketOptions) for TCP; the policy module defines
// the semantics for all of them. IPPROTO_TCP options exist only on TCP.

const std = @import("std");
const sp = @import("sockopt_policy.zig");
const tip = @import("tcp_info_policy.zig");

const SockRef = union(enum) {
    tcp: u32,
    udp: u32,
    unix: u32,
    raw: u32,
};

/// The socket behind `fd`: EBADF (-9) for a closed / out-of-range descriptor,
/// ENOTSOCK (-88) for anything that is not a socket.
fn resolveSocket(fd: u64) union(enum) { ok: SockRef, err: i64, v6: SockRef } {
    const vfs_mod = @import("../fs/vfs.zig");
    if (fd >= vfs_mod.MAX_FDS) return .{ .err = -9 };
    const sched_mod = @import("../proc/sched.zig");
    const task_mod = @import("../proc/task.zig");
    const cur_idx = sched_mod.currentTaskIndex() orelse return .{ .err = -9 };
    const t = task_mod.getTask(cur_idx) orelse return .{ .err = -9 };
    const d = &t.fd_table.fds[@intCast(fd)];
    return switch (d.fd_type) {
        .none => .{ .err = -9 },
        .tcp_socket => .{ .ok = .{ .tcp = d.tcb_idx } },
        .udp_socket => if (d.udp_is_v6) .{ .v6 = .{ .udp = d.udpKey() } } else .{ .ok = .{ .udp = d.udpKey() } },
        .unix_socket => .{ .ok = .{ .unix = d.unix_sock_idx } },
        .raw_socket => if (@import("raw_icmp.zig").isV6(d.raw_idx)) .{ .v6 = .{ .raw = d.raw_idx } } else .{ .ok = .{ .raw = d.raw_idx } },
        else => .{ .err = -88 },
    };
}

fn readOptval(optval_ptr: u64, optlen: u64, buf: *[16]u8) i64 {
    const copy_mod = @import("../mm/copy_from_user.zig");
    if (optval_ptr == 0 or optval_ptr >= 0x0000_8000_0000_0000) return -14; // EFAULT
    if (optlen == 0) return -22; // EINVAL
    const n: usize = @intCast(@min(optlen, buf.len));
    if (copy_mod.copyFromUser(buf[0..n], @ptrFromInt(optval_ptr), n) != n) return -14;
    return @intCast(n);
}

fn storedFromTcp(o: SocketOptions) sp.Stored {
    return .{
        .flags = (if (o.reuse_addr) @as(u16, 1) else 0) | (if (o.keep_alive) @as(u16, 2) else 0) | o.extra_flags,
        .rcv_ms = o.rcv_timeout_ms,
        .snd_ms = o.snd_timeout_ms,
        .rcvbuf = o.rcv_buf_size,
        .sndbuf = o.snd_buf_size,
        .linger_on = o.linger_on,
        .linger_sec = o.linger_sec,
        .ip = o.ip,
        .priority = o.priority,
        .mark = o.mark,
        .bound_if = o.bound_if,
    };
}

fn applyStoredToTcp(o: *SocketOptions, st: sp.Stored) void {
    o.reuse_addr = st.flags & 1 != 0;
    o.keep_alive = st.flags & 2 != 0;
    o.extra_flags = st.flags & ~@as(u16, 3);
    o.rcv_timeout_ms = st.rcv_ms;
    o.snd_timeout_ms = st.snd_ms;
    o.rcv_buf_size = st.rcvbuf;
    o.snd_buf_size = st.sndbuf;
    o.linger_on = st.linger_on;
    o.linger_sec = st.linger_sec;
    o.ip = st.ip;
    o.priority = st.priority;
    o.mark = st.mark;
    o.bound_if = st.bound_if;
}

fn ifaceCount() usize {
    return if (@import("nic.zig").isActive()) 2 else 1;
}

fn callerNetAdmin() bool {
    const sched_mod = @import("../proc/sched.zig");
    const cur_idx = sched_mod.currentTaskIndex() orelse return false;
    return @import("../ipc/capability.zig").hasSysCap(cur_idx, "cap_net_admin");
}

/// SOL_SOCKET set with the caller's privileges and this kernel's interface list.
/// AF_UNIX sockets have no devices to bind to.
fn applySol(st: *sp.Stored, optname: u64, val: []const u8, is_inet: bool) i64 {
    if (!is_inet and optname == sp.SO_BINDTODEVICE) return -92;
    return sp.applySetPriv(st, optname, val, callerNetAdmin(), ifaceCount());
}

fn currentCred() sp.Cred {
    const sched_mod = @import("../proc/sched.zig");
    const t = sched_mod.currentTask() orelse return .{};
    return .{ .pid = @intCast(if (t.is_thread and t.parent_tid != 0) t.parent_tid else t.tid), .uid = t.euid, .gid = t.egid };
}

// ─── setsockopt syscall ───────────────────────────────────────────────────

fn setTcpSockopt(tcb_idx: u32, level: u64, optname: u64, optval_ptr: u64, optlen: u64) i64 {
    const tcp_mod = @import("tcp.zig");
    // v53.14: Work on a copy, write back under lock at the end — no raw pointer escape
    var opts = tcp_mod.tcpGetOptions(tcb_idx) orelse return -88;
    var need_flush_cork = false;
    var need_flush_ack = false;

    // Validate optval pointer
    if (optval_ptr == 0 or optval_ptr >= 0x0000_8000_0000_0000) return -14; // EFAULT
    if (optlen == 0) return -22; // EINVAL

    const copy_mod = @import("../mm/copy_from_user.zig");

    if (level == SOL_SOCKET) {
        switch (optname) {
            SO_REUSEADDR => {
                if (optlen < 4) return -22;
                var buf: [4]u8 = undefined;
                if (copy_mod.copyFromUser(&buf, @ptrFromInt(optval_ptr), 4) != 4) return -14;
                opts.reuse_addr = bo.readU32Le(&buf) != 0;
            },
            SO_KEEPALIVE => {
                if (optlen < 4) return -22;
                var buf: [4]u8 = undefined;
                if (copy_mod.copyFromUser(&buf, @ptrFromInt(optval_ptr), 4) != 4) return -14;
                opts.keep_alive = bo.readU32Le(&buf) != 0;
            },
            SO_RCVTIMEO => {
                // struct timeval { tv_sec: i64, tv_usec: i64 } = 16 bytes
                if (optlen < 16) return -22;
                var tv: [16]u8 = undefined;
                if (copy_mod.copyFromUser(&tv, @ptrFromInt(optval_ptr), 16) != 16) return -14;
                const sec = bo.readI64Le(tv[0..8]);
                const usec = bo.readI64Le(tv[8..16]);
                opts.rcv_timeout_ms = timeoutMs(sec, usec) orelse return -22;
            },
            SO_SNDTIMEO => {
                if (optlen < 16) return -22;
                var tv: [16]u8 = undefined;
                if (copy_mod.copyFromUser(&tv, @ptrFromInt(optval_ptr), 16) != 16) return -14;
                const sec = bo.readI64Le(tv[0..8]);
                const usec = bo.readI64Le(tv[8..16]);
                opts.snd_timeout_ms = timeoutMs(sec, usec) orelse return -22;
            },
            SO_RCVBUF => {
                if (optlen < 4) return -22;
                var buf: [4]u8 = undefined;
                if (copy_mod.copyFromUser(&buf, @ptrFromInt(optval_ptr), 4) != 4) return -14;
                opts.rcv_buf_size = sp.bufferValue(bo.readU32Le(&buf), sp.SOCK_MIN_RCVBUF);
                opts.rcv_buf_set = true;
            },
            SO_SNDBUF => {
                if (optlen < 4) return -22;
                var buf: [4]u8 = undefined;
                if (copy_mod.copyFromUser(&buf, @ptrFromInt(optval_ptr), 4) != 4) return -14;
                opts.snd_buf_size = sp.bufferValue(bo.readU32Le(&buf), sp.SOCK_MIN_SNDBUF);
                opts.snd_buf_set = true;
            },
            SO_LINGER => {
                // struct linger { l_onoff: i32, l_linger: i32 } = 8 bytes
                if (optlen < 8) return -22;
                var buf: [8]u8 = undefined;
                if (copy_mod.copyFromUser(&buf, @ptrFromInt(optval_ptr), 8) != 8) return -14;
                opts.linger_on = bo.readU32Le(buf[0..4]) != 0;
                opts.linger_sec = bo.readU32Le(buf[4..8]);
            },
            else => return -92, // ENOPROTOOPT
        }
    } else if (level == SOL_TCP) {
        switch (optname) {
            TCP_NODELAY => {
                if (optlen < 4) return -22;
                var buf: [4]u8 = undefined;
                if (copy_mod.copyFromUser(&buf, @ptrFromInt(optval_ptr), 4) != 4) return -14;
                opts.tcp_nodelay = bo.readU32Le(&buf) != 0;
            },
            TCP_CORK => {
                if (optlen < 4) return -22;
                var buf: [4]u8 = undefined;
                if (copy_mod.copyFromUser(&buf, @ptrFromInt(optval_ptr), 4) != 4) return -14;
                const new_cork = bo.readU32Le(&buf) != 0;
                // Uncorking triggers flush of any pending data
                if (opts.tcp_cork and !new_cork) {
                    opts.tcp_cork = false;
                    need_flush_cork = true;
                } else {
                    opts.tcp_cork = new_cork;
                }
            },
            TCP_QUICKACK => {
                if (optlen < 4) return -22;
                var buf: [4]u8 = undefined;
                if (copy_mod.copyFromUser(&buf, @ptrFromInt(optval_ptr), 4) != 4) return -14;
                opts.tcp_quickack = bo.readU32Le(&buf) != 0;
                // Setting quickack immediately flushes any pending delayed ACK
                if (opts.tcp_quickack) {
                    need_flush_ack = true;
                }
            },
            TCP_KEEPIDLE => {
                if (optlen < 4) return -22;
                var buf: [4]u8 = undefined;
                if (copy_mod.copyFromUser(&buf, @ptrFromInt(optval_ptr), 4) != 4) return -14;
                // Clamp like Linux (MAX_TCP_KEEPIDLE = 32767) so the keepalive
                // millisecond arithmetic in tcp.zig cannot overflow u32.
                opts.keep_idle = @min(bo.readU32Le(&buf), 32767);
            },
            TCP_KEEPINTVL => {
                if (optlen < 4) return -22;
                var buf: [4]u8 = undefined;
                if (copy_mod.copyFromUser(&buf, @ptrFromInt(optval_ptr), 4) != 4) return -14;
                // Clamp like Linux (MAX_TCP_KEEPINTVL = 32767).
                opts.keep_intvl = @min(bo.readU32Le(&buf), 32767);
            },
            TCP_KEEPCNT => {
                if (optlen < 4) return -22;
                var buf: [4]u8 = undefined;
                if (copy_mod.copyFromUser(&buf, @ptrFromInt(optval_ptr), 4) != 4) return -14;
                // Clamp like Linux (MAX_TCP_KEEPCNT = 32767).
                opts.keep_cnt = @min(bo.readU32Le(&buf), 32767);
            },
            tip.TCP_MAXSEG => {
                if (optlen < 4) return -22;
                var buf: [4]u8 = undefined;
                if (copy_mod.copyFromUser(&buf, @ptrFromInt(optval_ptr), 4) != 4) return -14;
                const v = bo.readU32Le(&buf);
                if (!tip.maxsegValid(v)) return -22;
                // Linux: only before the connection is established.
                if (!tcp_mod.tcpMaxsegSettable(tcb_idx)) return -22;
                opts.user_mss = v;
            },
            tip.TCP_USER_TIMEOUT => {
                if (optlen < 4) return -22;
                var buf: [4]u8 = undefined;
                if (copy_mod.copyFromUser(&buf, @ptrFromInt(optval_ptr), 4) != 4) return -14;
                const v: i32 = @bitCast(bo.readU32Le(&buf));
                const e = @import("tcp_recv_policy.zig").userTimeoutErrno(v);
                if (e != 0) return e;
                opts.user_timeout_ms = @intCast(v);
            },
            tip.TCP_DEFER_ACCEPT, tip.TCP_SYNCNT, tip.TCP_LINGER2, tip.TCP_NOTSENT_LOWAT => {
                // Accepted and ignored: the behaviour they tune does not exist here.
                if (optlen < 4) return -22;
                var buf: [4]u8 = undefined;
                if (copy_mod.copyFromUser(&buf, @ptrFromInt(optval_ptr), 4) != 4) return -14;
                if (@as(i32, @bitCast(bo.readU32Le(&buf))) < 0 and optname != tip.TCP_LINGER2) return -22;
            },
            tip.TCP_CONGESTION => {
                // Only the algorithm this stack runs can be selected.
                var name: [16]u8 = @splat(0);
                const n: usize = @intCast(@min(optlen, name.len));
                if (copy_mod.copyFromUser(name[0..n], @ptrFromInt(optval_ptr), n) != n) return -14;
                const len = std.mem.indexOfScalar(u8, name[0..n], 0) orelse n;
                if (!std.mem.eql(u8, name[0..len], tip.CONGESTION_NAME)) return -2; // ENOENT
            },
            else => return -92, // ENOPROTOOPT
        }
    } else {
        return -92; // ENOPROTOOPT — unknown level
    }

    // v53.14: Write back options under tcp_lock, then flush outside the option lock
    _ = tcp_mod.tcpSetOptions(tcb_idx, opts);
    if (need_flush_cork) tcp_mod.tcpFlushCork(tcb_idx);
    if (need_flush_ack) tcp_mod.tcpFlushAck(tcb_idx);
    return 0;
}

// ─── getsockopt syscall ───────────────────────────────────────────────────

/// SOL_TCP options only: sysGetSockopt sends every SOL_SOCKET option (SO_ERROR included) through the common path below.
fn getTcpSockopt(tcb_idx: u32, level: u64, optname: u64, optval_ptr: u64, optlen_ptr: u64) i64 {
    const tcp_mod = @import("tcp.zig");
    // v53.14: Work on a locked copy — no raw pointer escape
    const opts = tcp_mod.tcpGetOptions(tcb_idx) orelse return -88;

    if (optval_ptr == 0 or optval_ptr >= 0x0000_8000_0000_0000) return -14; // EFAULT
    if (optlen_ptr == 0 or optlen_ptr >= 0x0000_8000_0000_0000) return -14;

    const copy_mod = @import("../mm/copy_from_user.zig");

    // optlen is both input and output, so verify both access modes before
    // reading any one-shot socket state.
    if (!copy_mod.validateUserBuffer(optlen_ptr, 4) or !copy_mod.validateUserBufferWritable(optlen_ptr, 4)) return -14;

    // Read current optlen from user space
    var user_optlen: u32 = 0;
    var len_buf: [4]u8 = undefined;
    if (copy_mod.copyFromUser(&len_buf, @ptrFromInt(optlen_ptr), 4) != 4) return -14;
    user_optlen = bo.readU32Le(&len_buf);

    var val_buf: [16]u8 = undefined;
    var val_len: u32 = 0;

    if (level == SOL_TCP) {
        switch (optname) {
            TCP_NODELAY => {
                val_len = 4;
                bo.writeU32Le(val_buf[0..4], if (opts.tcp_nodelay) 1 else 0);
            },
            TCP_CORK => {
                val_len = 4;
                bo.writeU32Le(val_buf[0..4], if (opts.tcp_cork) 1 else 0);
            },
            TCP_QUICKACK => {
                val_len = 4;
                bo.writeU32Le(val_buf[0..4], if (opts.tcp_quickack) 1 else 0);
            },
            TCP_KEEPIDLE => {
                val_len = 4;
                bo.writeU32Le(val_buf[0..4], opts.keep_idle);
            },
            TCP_KEEPINTVL => {
                val_len = 4;
                bo.writeU32Le(val_buf[0..4], opts.keep_intvl);
            },
            TCP_KEEPCNT => {
                val_len = 4;
                bo.writeU32Le(val_buf[0..4], opts.keep_cnt);
            },
            tip.TCP_MAXSEG => {
                val_len = 4;
                bo.writeU32Le(val_buf[0..4], tcp_mod.tcpEffectiveMss(tcb_idx));
            },
            tip.TCP_USER_TIMEOUT => {
                val_len = 4;
                bo.writeU32Le(val_buf[0..4], opts.user_timeout_ms);
            },
            tip.TCP_DEFER_ACCEPT, tip.TCP_SYNCNT, tip.TCP_LINGER2, tip.TCP_NOTSENT_LOWAT => {
                val_len = 4;
                bo.writeU32Le(val_buf[0..4], 0);
            },
            tip.TCP_CONGESTION => {
                val_len = tip.CONGESTION_NAME.len + 1;
                @memset(val_buf[0..16], 0);
                @memcpy(val_buf[0..tip.CONGESTION_NAME.len], tip.CONGESTION_NAME);
            },
            tip.TCP_INFO => {
                var info: [tip.TCP_INFO_LEN]u8 = undefined;
                tip.encode(tcp_mod.tcpInfoSnapshot(tcb_idx) orelse return -88, &info);
                const n: u32 = @intCast(@min(@as(usize, user_optlen), info.len));
                if (n > 0 and copy_mod.copyToUser(@ptrFromInt(optval_ptr), info[0..n], n) != n) return -14;
                var len_out_info: [4]u8 = undefined;
                bo.writeU32Le(&len_out_info, n);
                if (copy_mod.copyToUser(@ptrFromInt(optlen_ptr), &len_out_info, 4) != 4) return -14;
                return 0;
            },
            else => return -92, // ENOPROTOOPT
        }
    } else {
        return -92; // ENOPROTOOPT
    }

    // Write value to user space (truncated if user buffer too small)
    const to_copy = @min(val_len, user_optlen);
    if (to_copy > 0) {
        if (copy_mod.copyToUser(@ptrFromInt(optval_ptr), val_buf[0..to_copy], to_copy) != to_copy) return -14;
    }

    // Write actual length back to optlen_ptr
    var len_out: [4]u8 = undefined;
    bo.writeU32Le(&len_out, val_len);
    if (copy_mod.copyToUser(@ptrFromInt(optlen_ptr), &len_out, 4) != 4) return -14;

    return 0;
}

// ─── public entry points ──────────────────────────────────────────────────

const ipo = @import("ip_opt_policy.zig");

fn socketFamily(ref: SockRef, v6_hint: bool) ?ipo.Family {
    return switch (ref) {
        .tcp => |idx| if (@import("tcp.zig").tcpIsV6(idx)) .v6 else .v4,
        .udp => if (v6_hint) .v6 else .v4,
        .raw => |idx| if (@import("raw_icmp.zig").isV6(idx)) .v6 else .v4,
        else => null,
    };
}

/// SOL_UDP and SOL_UDPLITE: UDP's own levels (udp_lib_getsockopt / udp_lib_setsockopt), where an option this kernel lacks is
/// ENOPROTOOPT.
const SOL_UDP: u64 = 17;
const SOL_UDPLITE: u64 = 136;

/// The errno of a getsockopt (`get`) or setsockopt at a level the socket does not handle (ipo.unknownLevelErrno).
fn unknownLevel(ref: SockRef, v6: bool, get: bool) i64 {
    const kind: ipo.SockKind = switch (ref) {
        .unix => .unix,
        .tcp => |idx| if (@import("tcp.zig").tcpIsV6(idx)) .inet6 else .inet4,
        .udp, .raw => if (v6) .inet6 else .inet4,
    };
    return ipo.unknownLevelErrno(kind, get);
}

/// setsockopt at SOL_IP / SOL_IPV6: only IP sockets, and only the level that matches their family.
fn setIpOpt(ref: SockRef, v6_hint: bool, level: u64, optname: u64, optval_ptr: u64, optlen: u64) i64 {
    const fam = socketFamily(ref, v6_hint) orelse return unknownLevel(ref, v6_hint, false);
    if (!ipo.levelApplies(level, fam)) return -92;
    if (level == ipo.SOL_IPV6 and (optname == ipo.IPV6_ADD_MEMBERSHIP or optname == ipo.IPV6_DROP_MEMBERSHIP)) return setMembership(ref, optname, optval_ptr, optlen);
    if (level == ipo.SOL_IP and (optname == ipo.IP_ADD_MEMBERSHIP or optname == ipo.IP_DROP_MEMBERSHIP)) return setMembership4(ref, optname, optval_ptr, optlen);
    // do_ip_setsockopt: IP_HDRINCL is for SOCK_RAW only; any other socket still reads it as 0.
    if (level == ipo.SOL_IP and optname == ipo.IP_HDRINCL and ref != .raw) return -92;
    if (ref == .tcp and level == ipo.SOL_IPV6) {
        if (ipo.streamSetErrno(optname)) |e| return e;
    }
    if (ref == .tcp and level == ipo.SOL_IP) {
        if (ipo.streamSetErrno4(optname)) |e| return e;
    }
    var raw: [16]u8 = undefined;
    const n = readOptval(optval_ptr, optlen, &raw);
    if (n < 0) return n;
    if (level == ipo.SOL_IP and optname == ipo.IP_MULTICAST_IF and ref == .udp) {
        const udp_mod = @import("udp.zig");
        var st = udp_mod.getPortOpts(ref.udp) orelse return -9;
        switch (ipo.setMulticastIf4(st.ip, raw[0..@intCast(n)], @import("nic.zig").isActive(), @import("netif.zig").getOurIp())) {
            .err => |e| return e,
            .ok => |v| st.ip = v,
        }
        return if (udp_mod.setPortOpts(ref.udp, st)) 0 else -9;
    }
    if (level == ipo.SOL_IPV6 and optname == ipo.IPV6_MULTICAST_IF and n >= 4) {
        const e = ipo.mcastIfErrno(ipo.readInt(raw[0..4]).?, @import("nic.zig").isActive());
        if (e != 0) return e;
    }
    switch (ref) {
        .tcp => |idx| {
            const tcp_mod = @import("tcp.zig");
            var o = tcp_mod.tcpGetOptions(idx) orelse return -9;
            switch (ipo.applySet(o.ip, level, optname, raw[0..@intCast(n)])) {
                .err => |e| return e,
                .ok => |v| o.ip = v,
            }
            return if (tcp_mod.tcpSetOptions(idx, o)) 0 else -9;
        },
        .udp => |port| {
            const udp_mod = @import("udp.zig");
            var st = udp_mod.getPortOpts(port) orelse return -9;
            switch (ipo.applySet(st.ip, level, optname, raw[0..@intCast(n)])) {
                .err => |e| return e,
                .ok => |v| st.ip = v,
            }
            return if (udp_mod.setPortOpts(port, st)) 0 else -9;
        },
        .raw => |idx| {
            const raw_mod = @import("raw_icmp.zig");
            var st = raw_mod.getOpts(idx) orelse return -9;
            switch (ipo.applySet(st.ip, level, optname, raw[0..@intCast(n)])) {
                .err => |e| return e,
                .ok => |v| st.ip = v,
            }
            return if (raw_mod.setOpts(idx, st)) 0 else -9;
        },
        else => return -92,
    }
}

/// IPV6_ADD_MEMBERSHIP / IPV6_DROP_MEMBERSHIP with a struct ipv6_mreq (group, then a 32-bit interface index): shorter is EINVAL,
/// a TCP socket EPROTO (Linux checks the length first); a UDP socket joins or leaves through udp.mcJoin / udp.mcDrop.
fn setMembership(ref: SockRef, optname: u64, optval_ptr: u64, optlen: u64) i64 {
    if (optlen < 20) return -22;
    if (ref == .tcp) return -71;
    if (ref != .udp) return -92;
    const copy_mod = @import("../mm/copy_from_user.zig");
    if (optval_ptr == 0 or optval_ptr >= 0x0000_8000_0000_0000) return -14;
    var mreq: [20]u8 = undefined;
    if (copy_mod.copyFromUser(&mreq, @ptrFromInt(optval_ptr), 20) != 20) return -14;
    const group: [16]u8 = mreq[0..16].*;
    const ifindex = bo.readU32Le(mreq[16..20]);
    const udp_mod = @import("udp.zig");
    return if (optname == ipo.IPV6_ADD_MEMBERSHIP)
        udp_mod.mcJoin(ref.udp, group, ifindex, @import("nic.zig").isActive())
    else
        udp_mod.mcDrop(ref.udp, group, ifindex);
}

/// IP_ADD_MEMBERSHIP / IP_DROP_MEMBERSHIP: a TCP socket is EPROTO, then a value shorter than struct ip_mreq (8 bytes: group, interface
/// address) is EINVAL; 12 bytes and more are a struct ip_mreqn with an interface index too (Linux do_ip_setsockopt).
fn setMembership4(ref: SockRef, optname: u64, optval_ptr: u64, optlen: u64) i64 {
    if (ref == .tcp) return -71;
    if (ref != .udp) return -92;
    if (optlen < 8) return -22;
    const copy_mod = @import("../mm/copy_from_user.zig");
    if (optval_ptr == 0 or optval_ptr >= 0x0000_8000_0000_0000) return -14;
    var mreq: [12]u8 = @splat(0);
    const len: usize = if (optlen >= 12) 12 else 8;
    if (copy_mod.copyFromUser(mreq[0..len], @ptrFromInt(optval_ptr), len) != len) return -14;
    const group: [4]u8 = mreq[0..4].*;
    const addr: [4]u8 = mreq[4..8].*;
    const index = bo.readU32Le(mreq[8..12]);
    const udp_mod = @import("udp.zig");
    const nic_on = @import("nic.zig").isActive();
    const our = @import("netif.zig").getOurIp();
    return if (optname == ipo.IP_ADD_MEMBERSHIP)
        udp_mod.mcJoin4(ref.udp, group, addr, index, nic_on, our)
    else
        udp_mod.mcDrop4(ref.udp, group, addr, index, nic_on, our);
}

fn getIpOpt(ref: SockRef, v6_hint: bool, level: u64, optname: u64, optval_ptr: u64, optlen_ptr: u64) i64 {
    const fam = socketFamily(ref, v6_hint) orelse return unknownLevel(ref, v6_hint, true);
    // ip_getsockopt answers a level other than SOL_IP with EOPNOTSUPP; an IPv6 socket's ipv6_getsockopt with ENOPROTOOPT.
    if (!ipo.levelApplies(level, fam)) return if (fam == .v4) -95 else -92;
    const cur: ipo.IpOpts = switch (ref) {
        .tcp => |idx| (@import("tcp.zig").tcpGetOptions(idx) orelse return -9).ip,
        .udp => |port| (@import("udp.zig").getPortOpts(port) orelse return -9).ip,
        .raw => |idx| (@import("raw_icmp.zig").getOpts(idx) orelse return -9).ip,
        else => return -92,
    };
    const v = ipo.getValue(cur, level, optname) orelse return -92;
    const copy_mod = @import("../mm/copy_from_user.zig");
    if (optval_ptr == 0 or optval_ptr >= 0x0000_8000_0000_0000) return -14;
    if (optlen_ptr == 0 or optlen_ptr >= 0x0000_8000_0000_0000) return -14;
    if (!copy_mod.validateUserBuffer(optlen_ptr, 4) or !copy_mod.validateUserBufferWritable(optlen_ptr, 4)) return -14;
    var len_buf: [4]u8 = undefined;
    if (copy_mod.copyFromUser(&len_buf, @ptrFromInt(optlen_ptr), 4) != 4) return -14;
    const user_len = bo.readU32Le(&len_buf);
    var out: [4]u8 = undefined;
    bo.writeU32Le(&out, @bitCast(v));
    const n: u32 = @min(user_len, 4);
    if (n > 0 and copy_mod.copyToUser(@ptrFromInt(optval_ptr), out[0..n], n) != n) return -14;
    var len_out: [4]u8 = undefined;
    bo.writeU32Le(&len_out, n);
    if (copy_mod.copyToUser(@ptrFromInt(optlen_ptr), &len_out, 4) != 4) return -14;
    return 0;
}

const SOL_ICMPV6: u64 = 58;
/// SOL_RAW (255): ICMP_FILTER (option 1) on an IPv4 raw ICMP socket (raw_setsockopt), IPV6_CHECKSUM on an IPv6 one
/// (rawv6_setsockopt); every other SOL_RAW option is ENOPROTOOPT.
const SOL_RAW: u64 = 255;
const ICMP_FILTER: u64 = 1;
/// ICMP6_FILTER (SOL_ICMPV6 option 1): the per-socket type filter of an IPv6 raw ICMPv6 socket.
const ICMP6_FILTER: u64 = 1;
/// IPV6_CHECKSUM (SOL_IPV6 option 7): where the kernel puts a send's checksum and checks a received one (rawv6_setsockopt).
const IPV6_CHECKSUM: u64 = 7;
/// IPV6_HDRINCL (SOL_IPV6 option 36): an IPv6 raw socket's sends are whole packets, header first (the HDRINCL bit IP_HDRINCL sets).
const IPV6_HDRINCL: u64 = 36;

const RawV6Opt = enum { filter, checksum, checksum_raw, icmp_filter, noprotoopt, icmpv6_level, hdrincl6 };

/// Which raw-socket option a SOL_ICMPV6, SOL_IPV6 or SOL_RAW request names: ICMP6_FILTER and IPV6_CHECKSUM (at SOL_IPV6, or at
/// SOL_RAW) on an IPv6 socket; any other SOL_ICMPV6 or SOL_RAW option is ENOPROTOOPT. SOL_RAW ICMP_FILTER on an IPv4 socket. Null:
/// not one of these (SOL_ICMPV6 on an IPv4 raw socket is a level raw_getsockopt passes on to ip_getsockopt: unknownLevel).
fn rawV6Opt(v6: bool, level: u64, optname: u64) ?RawV6Opt {
    if (level == SOL_RAW) {
        if (!v6 and optname == ICMP_FILTER) return .icmp_filter;
        if (v6 and optname == IPV6_CHECKSUM) return .checksum_raw;
        return .noprotoopt;
    }
    if (level == SOL_ICMPV6) return if (!v6) null else if (optname == ICMP6_FILTER) .filter else .icmpv6_level;
    if (v6 and level == ipo.SOL_IPV6 and optname == IPV6_CHECKSUM) return .checksum;
    if (v6 and level == ipo.SOL_IPV6 and optname == IPV6_HDRINCL) return .hdrincl6;
    return null;
}

/// SOL_ICMPV6 on an IPv6 raw socket that is not ICMPv6 is EOPNOTSUPP, whatever the option (rawv6_setsockopt / rawv6_getsockopt);
/// ICMP_FILTER likewise on an IPv4 socket that is not ICMP.
fn rawV6OptErrno(idx: u32, which: RawV6Opt) i64 {
    const rp = @import("raw_icmp_policy.zig");
    const proto = @import("raw_icmp.zig").protocolOf(idx);
    return switch (which) {
        .icmp_filter => rp.icmpFilterErrno(proto),
        .filter, .icmpv6_level => rp.icmp6FilterErrno(proto),
        else => 0,
    };
}

fn setRawV6Opt(idx: u32, which: RawV6Opt, optval_ptr: u64, optlen: u64) i64 {
    const frc = rawV6OptErrno(idx, which);
    if (frc != 0) return frc;
    switch (which) {
        .noprotoopt, .icmpv6_level => return -92,
        .hdrincl6 => {
            // do_rawv6_setsockopt: an int, any nonzero value sets it.
            if (optlen < 4) return -22;
            if (optval_ptr == 0 or optval_ptr >= 0x0000_8000_0000_0000) return -14;
            var b: [4]u8 = undefined;
            if (@import("../mm/copy_from_user.zig").copyFromUser(&b, @ptrFromInt(optval_ptr), 4) != 4) return -14;
            const raw = @import("raw_icmp.zig");
            var st = raw.getOpts(idx) orelse return -9;
            st.ip.hdrincl = bo.readU32Le(&b) != 0;
            return if (raw.setOpts(idx, st)) 0 else -9;
        },
        .checksum, .checksum_raw => {
            // do_rawv6_setsockopt: an int; an ICMPv6 socket's offset cannot be moved at SOL_IPV6 (RFC 3542), an odd one is EINVAL.
            if (optlen < 4) return -22;
            if (optval_ptr == 0 or optval_ptr >= 0x0000_8000_0000_0000) return -14;
            var b: [4]u8 = undefined;
            if (@import("../mm/copy_from_user.zig").copyFromUser(&b, @ptrFromInt(optval_ptr), 4) != 4) return -14;
            const v: i32 = @bitCast(bo.readU32Le(&b));
            const rp = @import("raw_icmp_policy.zig");
            const raw = @import("raw_icmp.zig");
            const e = rp.checksumOptErrno(raw.protocolOf(idx), which == .checksum_raw, v);
            if (e != 0) return e;
            return if (raw.setChecksumOffset(idx, rp.checksumOptValue(v))) 0 else -9;
        },
        .icmp_filter => {
            const copy_mod = @import("../mm/copy_from_user.zig");
            const n: usize = @intCast(@min(optlen, 4));
            var val: [4]u8 = undefined;
            if (n != 0) {
                if (optval_ptr == 0 or optval_ptr >= 0x0000_8000_0000_0000) return -14;
                if (copy_mod.copyFromUser(val[0..n], @ptrFromInt(optval_ptr), n) != n) return -14;
            }
            return if (@import("raw_icmp.zig").setIcmpFilter(idx, val[0..n])) 0 else -9;
        },
        .filter => {
            const copy_mod = @import("../mm/copy_from_user.zig");
            const n: usize = @intCast(@min(optlen, @import("raw_icmp_policy.zig").FILTER_LEN));
            var val: [@import("raw_icmp_policy.zig").FILTER_LEN]u8 = undefined;
            if (n != 0) {
                if (optval_ptr == 0 or optval_ptr >= 0x0000_8000_0000_0000) return -14;
                if (copy_mod.copyFromUser(val[0..n], @ptrFromInt(optval_ptr), n) != n) return -14;
            }
            return if (@import("raw_icmp.zig").setFilter(idx, val[0..n])) 0 else -9;
        },
    }
}

fn getRawV6Opt(idx: u32, which: RawV6Opt, optval_ptr: u64, optlen_ptr: u64) i64 {
    const frc = rawV6OptErrno(idx, which);
    if (frc != 0) return frc;
    if (which == .noprotoopt or which == .icmpv6_level) return -92;
    const copy_mod = @import("../mm/copy_from_user.zig");
    if (optval_ptr == 0 or optval_ptr >= 0x0000_8000_0000_0000) return -14;
    if (optlen_ptr == 0 or optlen_ptr >= 0x0000_8000_0000_0000) return -14;
    if (!copy_mod.validateUserBuffer(optlen_ptr, 4) or !copy_mod.validateUserBufferWritable(optlen_ptr, 4)) return -14;
    var len_buf: [4]u8 = undefined;
    if (copy_mod.copyFromUser(&len_buf, @ptrFromInt(optlen_ptr), 4) != 4) return -14;
    const user_len = bo.readU32Le(&len_buf);
    // raw_geticmpfilter / rawv6_geticmpfilter: a negative length is EINVAL (do_rawv6_getsockopt takes it as unsigned for
    // IPV6_CHECKSUM, so 4 bytes).
    if (which != .checksum and which != .checksum_raw and which != .hdrincl6 and @as(i32, @bitCast(user_len)) < 0) return -22;
    var val: [@import("raw_icmp_policy.zig").FILTER_LEN]u8 = @splat(0);
    var full: u32 = 4;
    if (which == .filter) {
        val = @import("raw_icmp.zig").getFilter(idx);
        full = @import("raw_icmp_policy.zig").FILTER_LEN;
    } else if (which == .icmp_filter) {
        bo.writeU32Le(val[0..4], @import("raw_icmp.zig").getIcmpFilter(idx));
    } else if (which == .hdrincl6) {
        bo.writeU32Le(val[0..4], @intFromBool((@import("raw_icmp.zig").getOpts(idx) orelse return -9).ip.hdrincl));
    } else bo.writeU32Le(val[0..4], @bitCast(@import("raw_icmp_policy.zig").checksumOptRead(@import("raw_icmp.zig").checksumOffset(idx))));
    const n = @min(user_len, full);
    if (n > 0 and copy_mod.copyToUser(@ptrFromInt(optval_ptr), val[0..n], n) != n) return -14;
    bo.writeU32Le(&len_buf, n);
    if (copy_mod.copyToUser(@ptrFromInt(optlen_ptr), &len_buf, 4) != 4) return -14;
    return 0;
}

pub fn sysSetSockopt(fd: u64, level: u64, optname: u64, optval_ptr: u64, optlen: u64) i64 {
    const resolved = resolveSocket(fd);
    const ref: SockRef = switch (resolved) {
        .ok, .v6 => |r| r,
        .err => |e| return e,
    };
    const resolved_v6 = resolved == .v6;
    if (ref == .raw) {
        if (rawV6Opt(resolved_v6, level, optname)) |which| return setRawV6Opt(ref.raw, which, optval_ptr, optlen);
    }
    if (level == ipo.SOL_IP or level == ipo.SOL_IPV6) return setIpOpt(ref, resolved_v6, level, optname, optval_ptr, optlen);
    if (level != SOL_SOCKET and level != SOL_TCP) return unknownLevel(ref, resolved_v6, false);
    switch (ref) {
        .tcp => |idx| {
            if (level == SOL_SOCKET and (sp.storedOnly(optname) or (sp.flagBit(optname) != null and optname != SO_REUSEADDR and optname != SO_KEEPALIVE))) {
                // The bits TCP keeps in extra_flags (REUSEPORT / BROADCAST / DEBUG).
                var raw: [16]u8 = undefined;
                const n = readOptval(optval_ptr, optlen, &raw);
                if (n < 0) return n;
                const tcp_mod = @import("tcp.zig");
                var o = tcp_mod.tcpGetOptions(idx) orelse return -9;
                var st = storedFromTcp(o);
                const rc = applySol(&st, optname, raw[0..@intCast(n)], true);
                if (rc != 0) return rc;
                applyStoredToTcp(&o, st);
                return if (tcp_mod.tcpSetOptions(idx, o)) 0 else -9;
            }
            if (level == SOL_SOCKET and sp.readOnly(optname)) return -92;
            return setTcpSockopt(idx, level, optname, optval_ptr, optlen);
        },
        .udp => |port| {
            if (level != SOL_SOCKET) return unknownLevel(ref, resolved_v6, false);
            var raw: [16]u8 = undefined;
            const n = readOptval(optval_ptr, optlen, &raw);
            if (n < 0) return n;
            const udp_mod = @import("udp.zig");
            var st = udp_mod.getPortOpts(port) orelse return -9;
            const rc = applySol(&st, optname, raw[0..@intCast(n)], true);
            if (rc != 0) return rc;
            return if (udp_mod.setPortOpts(port, st)) 0 else -9;
        },
        .unix => |idx| {
            if (level != SOL_SOCKET) return unknownLevel(ref, resolved_v6, false);
            var raw: [16]u8 = undefined;
            const n = readOptval(optval_ptr, optlen, &raw);
            if (n < 0) return n;
            const um = @import("unix_socket.zig");
            const view = um.unixOptView(idx) orelse return -9;
            var st = view.opts;
            const rc = applySol(&st, optname, raw[0..@intCast(n)], false);
            if (rc != 0) return rc;
            return if (um.unixSetOpts(idx, st)) 0 else -9;
        },
        .raw => |idx| {
            if (level != SOL_SOCKET) return unknownLevel(ref, resolved_v6, false);
            var raw: [16]u8 = undefined;
            const n = readOptval(optval_ptr, optlen, &raw);
            if (n < 0) return n;
            const raw_mod = @import("raw_icmp.zig");
            var st = raw_mod.getOpts(idx) orelse return -9;
            const rc = applySol(&st, optname, raw[0..@intCast(n)], true);
            if (rc != 0) return rc;
            return if (raw_mod.setOpts(idx, st)) 0 else -9;
        },
    }
}

pub fn sysGetSockopt(fd: u64, level: u64, optname: u64, optval_ptr: u64, optlen_ptr: u64) i64 {
    const resolved = resolveSocket(fd);
    const ref: SockRef = switch (resolved) {
        .ok, .v6 => |r| r,
        .err => |e| return e,
    };
    const v6 = resolved == .v6;
    if (ref == .raw) {
        if (rawV6Opt(v6, level, optname)) |which| return getRawV6Opt(ref.raw, which, optval_ptr, optlen_ptr);
    }
    if (level == ipo.SOL_IP or level == ipo.SOL_IPV6) return getIpOpt(ref, v6, level, optname, optval_ptr, optlen_ptr);
    // A ping socket has no UDP level: ping_getsockopt is ip_getsockopt (udp.PING_KEY marks its key).
    if (ref == .udp and (ref.udp & @import("udp.zig").PING_KEY) == 0 and (level == SOL_UDP or level == SOL_UDPLITE)) return -92;
    if (level != SOL_SOCKET and level != SOL_TCP) return unknownLevel(ref, v6, true);
    // TCP keeps its own SOL_TCP set and its SO_ERROR clearing.
    if (ref == .tcp and level == SOL_TCP) return getTcpSockopt(ref.tcp, level, optname, optval_ptr, optlen_ptr);
    if (level != SOL_SOCKET) return unknownLevel(ref, v6, true);

    const copy_mod = @import("../mm/copy_from_user.zig");
    if (optval_ptr == 0 or optval_ptr >= 0x0000_8000_0000_0000) return -14;
    if (optlen_ptr == 0 or optlen_ptr >= 0x0000_8000_0000_0000) return -14;
    if (!copy_mod.validateUserBuffer(optlen_ptr, 4) or !copy_mod.validateUserBufferWritable(optlen_ptr, 4)) return -14;
    var len_buf: [4]u8 = undefined;
    if (copy_mod.copyFromUser(&len_buf, @ptrFromInt(optlen_ptr), 4) != 4) return -14;
    const user_optlen = bo.readU32Le(&len_buf);

    var stored: sp.Stored = .{};
    var facts: sp.Facts = .{ .id = sp.identity(.raw, v6) };
    var tcp_idx: ?u32 = null;
    var udp_clear: ?u32 = null;
    switch (ref) {
        .tcp => |idx| {
            const tcp_mod = @import("tcp.zig");
            const o = tcp_mod.tcpGetOptions(idx) orelse return -9;
            stored = storedFromTcp(o);
            facts = .{ .id = sp.identity(.tcp, tcp_mod.tcpIsV6(idx)), .accepting = tcp_mod.tcpIsListening(idx), .so_error = tcp_mod.tcpPendingSoError(idx) };
            tcp_idx = idx;
        },
        .udp => |port| {
            stored = @import("udp.zig").getPortOpts(port) orelse return -9;
            // A ping socket's key carries udp.PING_KEY: it reports IPPROTO_ICMP, or IPPROTO_ICMPV6 for an IPv6 one (sk_protocol).
            facts = .{ .id = if ((port & @import("udp.zig").PING_KEY) != 0) sp.identity(.ping, v6) else sp.identity(.udp, v6), .so_error = @import("udp.zig").peekPendingError(port) };
            udp_clear = port;
        },
        .unix => |idx| {
            const view = @import("unix_socket.zig").unixOptView(idx) orelse return -9;
            stored = view.opts;
            facts = .{ .id = sp.identity(if (view.sock_type == 5) .unix_seqpacket else if (view.stream) .unix_stream else .unix_dgram, false), .accepting = view.listening, .cred = view.peer_cred };
        },
        .raw => |idx| {
            stored = @import("raw_icmp.zig").getOpts(idx) orelse return -9;
            facts.id.protocol = @import("raw_icmp.zig").protocolOf(idx);
        },
    }

    var val: [16]u8 = undefined;
    const val_len = sp.encodeGet(stored, facts, optname, &val) orelse return -92;
    const to_copy = @min(val_len, user_optlen);
    if (to_copy > 0 and copy_mod.copyToUser(@ptrFromInt(optval_ptr), val[0..to_copy], to_copy) != to_copy) return -14;
    var len_out: [4]u8 = undefined;
    bo.writeU32Le(&len_out, @intCast(to_copy));
    if (copy_mod.copyToUser(@ptrFromInt(optlen_ptr), &len_out, 4) != 4) return -14;
    if (optname == SO_ERROR) {
        if (tcp_idx) |idx| @import("tcp.zig").tcpClearSoErrorIfEqual(idx, facts.so_error);
        if (udp_clear) |p| @import("udp.zig").clearPendingErrorIfEqual(p, facts.so_error);
    }
    return 0;
}
