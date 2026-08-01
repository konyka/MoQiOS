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
    keep_idle: u32 = 7200, // seconds before first keepalive probe
    keep_intvl: u32 = 75, // seconds between keepalive probes
    keep_cnt: u32 = 9, // number of keepalive probes before dropping
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
    if (fd_u32 >= 32) return null;
    const sched_mod = @import("../proc/sched.zig");
    const cur_idx = sched_mod.currentTaskIndex() orelse return null;
    const task_mod = @import("../proc/task.zig");
    const t = task_mod.getTask(cur_idx) orelse return null;
    if (t.fd_table.fds[fd_u32].fd_type != .tcp_socket) return null;
    return t.fd_table.fds[fd_u32].tcb_idx;
}

// v53.14: resolveTcpOpts removed — use resolveTcpIdx + tcpGetOptions/tcpSetOptions instead

// ─── setsockopt syscall ───────────────────────────────────────────────────

pub fn sysSetSockopt(fd: u64, level: u64, optname: u64, optval_ptr: u64, optlen: u64) i64 {
    const tcb_idx = resolveTcpIdx(fd) orelse return -88; // ENOTSOCK
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
                opts.rcv_buf_size = bo.readU32Le(&buf);
            },
            SO_SNDBUF => {
                if (optlen < 4) return -22;
                var buf: [4]u8 = undefined;
                if (copy_mod.copyFromUser(&buf, @ptrFromInt(optval_ptr), 4) != 4) return -14;
                opts.snd_buf_size = bo.readU32Le(&buf);
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

pub fn sysGetSockopt(fd: u64, level: u64, optname: u64, optval_ptr: u64, optlen_ptr: u64) i64 {
    const tcb_idx = resolveTcpIdx(fd) orelse return -88; // ENOTSOCK
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

    if (level == SOL_SOCKET) {
        switch (optname) {
            SO_REUSEADDR => {
                val_len = 4;
                bo.writeU32Le(val_buf[0..4], if (opts.reuse_addr) 1 else 0);
            },
            SO_KEEPALIVE => {
                val_len = 4;
                bo.writeU32Le(val_buf[0..4], if (opts.keep_alive) 1 else 0);
            },
            SO_RCVTIMEO => {
                // struct timeval: 16 bytes
                val_len = 16;
                const sec: i64 = @intCast(opts.rcv_timeout_ms / 1000);
                const usec: i64 = @intCast((opts.rcv_timeout_ms % 1000) * 1000);
                bo.writeI64Le(val_buf[0..8], sec);
                bo.writeI64Le(val_buf[8..16], usec);
            },
            SO_SNDTIMEO => {
                val_len = 16;
                const sec: i64 = @intCast(opts.snd_timeout_ms / 1000);
                const usec: i64 = @intCast((opts.snd_timeout_ms % 1000) * 1000);
                bo.writeI64Le(val_buf[0..8], sec);
                bo.writeI64Le(val_buf[8..16], usec);
            },
            SO_RCVBUF => {
                val_len = 4;
                bo.writeU32Le(val_buf[0..4], opts.rcv_buf_size);
            },
            SO_SNDBUF => {
                val_len = 4;
                bo.writeU32Le(val_buf[0..4], opts.snd_buf_size);
            },
            SO_ERROR => {
                val_len = 4;
                bo.writeI32Le(val_buf[0..4], opts.so_error);
            },
            SO_LINGER => {
                val_len = 8;
                bo.writeI32Le(val_buf[0..4], if (opts.linger_on) @as(i32, 1) else @as(i32, 0));
                bo.writeU32Le(val_buf[4..8], opts.linger_sec);
            },
            else => return -92, // ENOPROTOOPT
        }
    } else if (level == SOL_TCP) {
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

    if (level == SOL_SOCKET and optname == SO_ERROR) {
        tcp_mod.tcpClearSoErrorIfEqual(tcb_idx, opts.so_error);
    }

    return 0;
}
