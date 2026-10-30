/// Unix domain socket (AF_UNIX) — local IPC with zero network stack overhead.
///
/// Provides:
///   - SOCK_STREAM (connected, reliable byte stream)
///   - SOCK_DGRAM (datagram, connectionless)
///   - bind/listen/accept/connect/send/recv operations
///   - Per-socket ring buffer for data transfer
///   - Wait queues for blocking I/O
///
/// Design:
///   - Global pool of 32 UnixSocket instances protected by IrqSpinlock
///   - Each socket has its own 8KB ring buffer
///   - STREAM sockets: connect establishes a peer pair; send writes to peer's buffer
///   - DGRAM sockets: send writes to peer's buffer directly (no connect required if bound)
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

pub const AF_UNIX: u32 = 1;
pub const SOCK_STREAM: u32 = 1;
pub const SOCK_DGRAM: u32 = 2;

pub const UNIX_SOCK_BUF_SIZE: u32 = 8192;
pub const MAX_UNIX_SOCKETS: u32 = 32;
pub const UNIX_PATH_MAX: u8 = 108;
pub const UNIX_BACKLOG_MAX: u8 = 4;
pub const UNIX_PENDING_MAX: u16 = 1024;
const EPOLLERR: u32 = 0x008;

/// Write `count` bytes from `src` into ring buffer at `write_pos`.
/// Uses @memcpy for contiguous chunks (handles wraparound at buffer boundary).
inline fn ringWrite(buffer: *[UNIX_SOCK_BUF_SIZE]u8, write_pos: u32, src: [*]const u8, count: usize) void {
    if (count == 0) return;
    const tail = UNIX_SOCK_BUF_SIZE - write_pos;
    if (tail >= count) {
        @memcpy(buffer[write_pos .. write_pos + @as(u32, @intCast(count))], src[0..count]);
    } else {
        @memcpy(buffer[write_pos..UNIX_SOCK_BUF_SIZE], src[0..tail]);
        @memcpy(buffer[0..@as(u32, @intCast(count - tail))], src[tail..count]);
    }
}

/// Read `count` bytes from ring buffer at `read_pos` into `dst`.
/// Uses @memcpy for contiguous chunks (handles wraparound at buffer boundary).
inline fn ringRead(buffer: *const [UNIX_SOCK_BUF_SIZE]u8, read_pos: u32, dst: [*]u8, count: usize) void {
    if (count == 0) return;
    const tail = UNIX_SOCK_BUF_SIZE - read_pos;
    if (tail >= count) {
        @memcpy(dst[0..count], buffer[read_pos .. read_pos + @as(u32, @intCast(count))]);
    } else {
        @memcpy(dst[0..tail], buffer[read_pos..UNIX_SOCK_BUF_SIZE]);
        @memcpy(dst[tail..count], buffer[0..@as(u32, @intCast(count - tail))]);
    }
}

/// WaitNode for blocking operations — stack-allocated on the waiter's kernel stack.
pub const WaitNode = struct {
    task_idx: u32,
    granted: bool = false,
    next: ?*WaitNode = null,
};

pub const UnixSocket = struct {
    active: bool = false,
    /// Cross-process references (fork/clone) — unixClose frees at 0 only.
    ref_count: u32 = 1,
    sock_type: u32 = 0,
    bound: bool = false,
    path: [UNIX_PATH_MAX]u8 = @splat(0),
    path_len: u8 = 0,
    connected: bool = false,
    peer_idx: u8 = 255, // 255 = no peer
    // Ring buffer
    buffer: [UNIX_SOCK_BUF_SIZE]u8 = @splat(0),
    buf_read: u32 = 0,
    buf_write: u32 = 0,
    buf_count: u32 = 0,
    // Bytes a stream client sent after connect() but before the listener accepted:
    // they wait here and move to the accepted socket's ring at accept().
    pending: [UNIX_PENDING_MAX]u8 = @splat(0),
    pending_len: u16 = 0,
    /// Set on connect/accept and kept after the peer closes, so a later send says
    /// EPIPE rather than ENOTCONN.
    was_connected: bool = false,
    // Wait queues
    read_waiters: ?*WaitNode = null,
    write_waiters: ?*WaitNode = null,
    // Listen state (STREAM only)
    listening: bool = false,
    backlog: [UNIX_BACKLOG_MAX]u8 = @splat(255),
    backlog_count: u8 = 0,
    accept_waiters: ?*WaitNode = null,
};

var unix_sockets: [MAX_UNIX_SOCKETS]UnixSocket = @splat(.{});
var unix_lock: IrqSpinlock = .{};

/// epoll notifications collected under unix_lock and fired after it is
/// released (epoll's pool_lock -> inst.spin never nests inside unix_lock).
/// They are wake-up hints only: epoll recomputes the real readiness with
/// unixEpollEvents, so over-notifying is harmless.
const EpollWake = struct {
    in: u32 = 0,
    out: u32 = 0,
    hup: u32 = 0,

    comptime {
        if (MAX_UNIX_SOCKETS > 32) @compileError("EpollWake masks hold 32 sockets");
    }

    fn bit(idx: u32) u32 {
        return if (idx < MAX_UNIX_SOCKETS) @as(u32, 1) << @intCast(idx) else 0;
    }

    fn fire(self: *const EpollWake) void {
        const epoll = @import("epoll.zig");
        var all = self.in | self.out | self.hup;
        while (all != 0) {
            const i: u32 = @ctz(all);
            all &= all - 1;
            const b = bit(i);
            var events: u32 = 0;
            if (self.in & b != 0) events |= epoll.EPOLLIN;
            if (self.out & b != 0) events |= epoll.EPOLLOUT;
            // epollNotify filters by interest and HUP is rarely requested;
            // a hang-up also makes read (EOF) and send (error) non-blocking.
            if (self.hup & b != 0) events |= epoll.EPOLLIN | epoll.EPOLLOUT | epoll.EPOLLHUP;
            epoll.epollNotify(.unix_socket, i, events);
        }
    }
};

/// Create a new Unix domain socket.
/// Returns socket index (>= 0) or negative errno on failure.
pub fn unixSocket(sock_type: u32) i32 {
    if (sock_type != SOCK_STREAM and sock_type != SOCK_DGRAM) return -22; // EINVAL

    const saved = unix_lock.acquire();
    defer unix_lock.release(saved);

    for (&unix_sockets, 0..) |*sock, i| {
        if (!sock.active) {
            sock.* = .{
                .active = true,
                .sock_type = sock_type,
            };
            return @intCast(i);
        }
    }
    return -24; // EMFILE
}

pub const UnixSocketPair = struct {
    first: u32,
    second: u32,
};

/// Allocate and connect both endpoints while holding the pool lock.
pub fn unixSocketPair() i32 {
    const saved = unix_lock.acquire();
    defer unix_lock.release(saved);

    var first: ?u32 = null;
    var second: ?u32 = null;
    for (&unix_sockets, 0..) |*sock, i| {
        if (!sock.active) {
            if (first == null) {
                first = @intCast(i);
            } else {
                second = @intCast(i);
                break;
            }
        }
    }
    const first_idx = first orelse return -24;
    const second_idx = second orelse return -24;
    unix_sockets[first_idx] = .{
        .active = true,
        .sock_type = SOCK_STREAM,
        .connected = true,
        .was_connected = true,
        .peer_idx = @intCast(second_idx),
    };
    unix_sockets[second_idx] = .{
        .active = true,
        .sock_type = SOCK_STREAM,
        .connected = true,
        .was_connected = true,
        .peer_idx = @intCast(first_idx),
    };
    return @as(i32, @intCast(first_idx)) | (@as(i32, @intCast(second_idx)) << 8);
}

/// Add a cross-process reference (fork/clone fd-table copy).
pub fn unixRetain(idx: u32) void {
    if (idx >= MAX_UNIX_SOCKETS) return;
    const saved = unix_lock.acquire();
    defer unix_lock.release(saved);
    if (!unix_sockets[idx].active) return;
    unix_sockets[idx].ref_count += 1;
}

/// Bind a Unix socket to a filesystem path.
/// Returns 0 on success, negative errno on failure.
pub fn unixBind(idx: u32, path: [*]const u8, path_len: usize) i32 {
    if (idx >= MAX_UNIX_SOCKETS) return -9; // EBADF
    if (path_len == 0 or path_len > UNIX_PATH_MAX) return -22; // EINVAL

    const saved = unix_lock.acquire();
    defer unix_lock.release(saved);

    const sock = &unix_sockets[idx];
    if (!sock.active) return -9; // EBADF
    if (sock.bound) return -22; // EINVAL — already bound

    // Check if path is already bound by another socket
    for (&unix_sockets) |*other| {
        if (other.active and other.bound and other.path_len == path_len) {
            var match = true;
            for (0..path_len) |j| {
                if (other.path[j] != path[j]) {
                    match = false;
                    break;
                }
            }
            if (match) return -98; // EADDRINUSE
        }
    }

    @memcpy(sock.path[0..path_len], path[0..path_len]);
    sock.path_len = @intCast(path_len);
    sock.bound = true;
    return 0;
}

/// Listen for connections on a STREAM socket.
/// Returns 0 on success, negative errno on failure.
pub fn unixListen(idx: u32, backlog: u32) i32 {
    _ = backlog;
    if (idx >= MAX_UNIX_SOCKETS) return -9; // EBADF

    const saved = unix_lock.acquire();
    defer unix_lock.release(saved);

    const sock = &unix_sockets[idx];
    if (!sock.active) return -9; // EBADF
    if (sock.sock_type != SOCK_STREAM) return -22; // EINVAL
    if (!sock.bound) return -22; // EINVAL — must be bound
    if (sock.listening) return 0; // already listening

    sock.listening = true;
    return 0;
}

/// Connect to a bound peer (STREAM) or set default peer (DGRAM).
/// For STREAM: finds the bound listener and establishes a connected pair.
/// Returns 0 on success, negative errno on failure.
pub fn unixConnect(idx: u32, path: [*]const u8, path_len: usize) i32 {
    if (idx >= MAX_UNIX_SOCKETS) return -9; // EBADF
    if (path_len == 0 or path_len > UNIX_PATH_MAX) return -22; // EINVAL

    var wake: EpollWake = .{};
    defer wake.fire();
    const saved = unix_lock.acquire();
    defer unix_lock.release(saved);

    const sock = &unix_sockets[idx];
    if (!sock.active) return -9; // EBADF
    if (sock.connected) return -22; // EISCONN

    // Find the bound peer
    var peer_found: ?u32 = null;
    for (&unix_sockets, 0..) |*other, i| {
        if (i == idx) continue;
        if (!other.active or !other.bound) continue;
        if (other.path_len != path_len) continue;
        var match = true;
        for (0..path_len) |j| {
            if (other.path[j] != path[j]) {
                match = false;
                break;
            }
        }
        if (match) {
            peer_found = @intCast(i);
            break;
        }
    }

    const peer_i = peer_found orelse return -111; // ECONNREFUSED
    const peer = &unix_sockets[peer_i];

    if (sock.sock_type == SOCK_STREAM) {
        if (!peer.listening) return -111; // ECONNREFUSED

        // Check backlog
        if (peer.backlog_count >= UNIX_BACKLOG_MAX) return -11; // EAGAIN

        // Add connector to listener's backlog
        peer.backlog[peer.backlog_count] = @intCast(idx);
        peer.backlog_count += 1;
        wake.in |= EpollWake.bit(peer_i);

        // Wake any accept waiter
        if (peer.accept_waiters) |node| {
            peer.accept_waiters = node.next;
            node.next = null;
            @atomicStore(bool, &node.granted, true, .release);
            const task_mod = @import("../proc/task.zig");
            task_mod.unblockTask(node.task_idx);
        }
    } else {
        // DGRAM: just set default peer
        sock.peer_idx = @intCast(peer_i);
        sock.connected = true;
    }

    return 0;
}

/// Accept a pending connection on a listening STREAM socket.
/// Returns new socket index (>= 0) or negative errno on failure.
/// Returns -11 (EAGAIN) if no pending connections.
pub fn unixAccept(idx: u32) i32 {
    if (idx >= MAX_UNIX_SOCKETS) return -9; // EBADF

    var wake: EpollWake = .{};
    defer wake.fire();
    const saved = unix_lock.acquire();
    defer unix_lock.release(saved);

    const sock = &unix_sockets[idx];
    if (!sock.active) return -9; // EBADF
    if (sock.sock_type != SOCK_STREAM) return -22; // EINVAL
    if (!sock.listening) return -22; // EINVAL

    if (sock.backlog_count == 0) return -11; // EAGAIN

    // Dequeue the first pending connection
    const conn_idx: u32 = sock.backlog[0];
    // Shift backlog
    for (1..UNIX_BACKLOG_MAX) |j| {
        sock.backlog[j - 1] = sock.backlog[j];
    }
    sock.backlog[UNIX_BACKLOG_MAX - 1] = 255;
    sock.backlog_count -= 1;

    // Backlog entries are raw indices — validate before use (the connector
    // may have been closed and its slot realloc'd while queued).
    // A queued connector that is no longer a pending stream client (closed and
    // its slot reused by something else, or already paired) must not be rewired.
    if (conn_idx >= MAX_UNIX_SOCKETS) return -103; // ECONNABORTED
    {
        const queued = &unix_sockets[conn_idx];
        if (!queued.active or queued.sock_type != SOCK_STREAM or queued.connected or queued.listening)
            return -103; // ECONNABORTED
    }

    // Create a new socket for the accepted connection
    var new_idx: u32 = MAX_UNIX_SOCKETS;
    for (&unix_sockets, 0..) |*s, i| {
        if (!s.active) {
            new_idx = @intCast(i);
            break;
        }
    }
    if (new_idx >= MAX_UNIX_SOCKETS) return -24; // EMFILE

    // Initialize the new accepted socket
    unix_sockets[new_idx] = .{
        .active = true,
        .sock_type = SOCK_STREAM,
        .connected = true,
        .was_connected = true,
        .peer_idx = @intCast(conn_idx),
    };

    // Mark the connector as connected to the new socket
    const conn_sock = &unix_sockets[conn_idx];
    conn_sock.connected = true;
    conn_sock.was_connected = true;
    conn_sock.peer_idx = @intCast(new_idx);
    wake.out |= EpollWake.bit(conn_idx);
    // A client that blocked in read() while queued can now be served.
    {
        var cur = conn_sock.read_waiters;
        while (cur) |node| {
            cur = node.next;
            @atomicStore(bool, &node.granted, true, .release);
            @import("../proc/task.zig").unblockTask(node.task_idx);
        }
        conn_sock.read_waiters = null;
    }
    // Bytes the client sent while it was still queued now reach the server's ring.
    if (conn_sock.pending_len > 0) {
        const nsock = &unix_sockets[new_idx];
        const n: usize = conn_sock.pending_len;
        ringWrite(&nsock.buffer, nsock.buf_write, &conn_sock.pending, n);
        nsock.buf_write = (nsock.buf_write + @as(u32, @intCast(n))) % UNIX_SOCK_BUF_SIZE;
        nsock.buf_count += @as(u32, @intCast(n));
        conn_sock.pending_len = 0;
        wake.in |= EpollWake.bit(new_idx);
    }

    return @intCast(new_idx);
}

/// Send data to a connected peer.
/// For STREAM: writes to peer's ring buffer.
/// For DGRAM: writes to peer's ring buffer (uses peer_idx).
/// Returns bytes sent, or negative errno on failure.
pub fn unixSend(idx: u32, data: [*]const u8, len: usize) i64 {
    if (idx >= MAX_UNIX_SOCKETS) return -9; // EBADF

    var wake: EpollWake = .{};
    defer wake.fire();
    const saved = unix_lock.acquire();
    defer unix_lock.release(saved);

    const sock = &unix_sockets[idx];
    if (!sock.active) return -9; // EBADF

    if (sock.sock_type == SOCK_STREAM) {
        if (!sock.connected) {
            // connect() succeeded but the listener has not accepted yet: keep the bytes.
            const queued = queuedOnBacklogLocked(idx);
            switch (np.streamSendState(.{ .connected = false, .queued = queued })) {
                .not_connected => return np.streamSendErrno(sock.was_connected, false),
                .deliver => unreachable,
                .queue_pending => {
                    const room: usize = UNIX_PENDING_MAX - sock.pending_len;
                    const n: usize = @min(len, room);
                    if (n == 0 and len > 0) return -11; // EAGAIN
                    @memcpy(sock.pending[sock.pending_len..][0..n], data[0..n]);
                    sock.pending_len += @intCast(n);
                    return @intCast(n);
                },
            }
        }
        const peer_i: u32 = sock.peer_idx;
        if (peer_i >= MAX_UNIX_SOCKETS or !unix_sockets[peer_i].active) return -32; // EPIPE

        const peer = &unix_sockets[peer_i];
        // Validate the back-reference: after a slot realloc, peer_idx could
        // name an unrelated socket — never deliver data to it.
        if (!peer.connected or peer.peer_idx != @as(u8, @intCast(idx))) return -32; // EPIPE
        const n: usize = @min(len, UNIX_SOCK_BUF_SIZE - peer.buf_count);
        ringWrite(&peer.buffer, peer.buf_write, data, n);
        peer.buf_write = (peer.buf_write + @as(u32, @intCast(n))) % UNIX_SOCK_BUF_SIZE;
        peer.buf_count += @as(u32, @intCast(n));

        // Wake any read waiter on peer
        if (n > 0) {
            wake.in |= EpollWake.bit(peer_i);
            if (peer.read_waiters) |node| {
                peer.read_waiters = node.next;
                node.next = null;
                @atomicStore(bool, &node.granted, true, .release);
                const task_mod = @import("../proc/task.zig");
                task_mod.unblockTask(node.task_idx);
            }
        }

        if (n == 0 and len > 0) return -11; // EAGAIN
        return @intCast(n);
    } else {
        // DGRAM
        const peer_i: u32 = sock.peer_idx;
        if (peer_i >= MAX_UNIX_SOCKETS or !unix_sockets[peer_i].active) return -107; // ENOTCONN

        const peer = &unix_sockets[peer_i];
        // For DGRAM, write the datagram length prefix (2 bytes LE) + data
        const total = 2 + len;
        if (peer.buf_count + total > UNIX_SOCK_BUF_SIZE) return -11; // EAGAIN

        // Write length prefix (2 bytes LE)
        const dgram_len: u16 = @intCast(len);
        peer.buffer[peer.buf_write] = @truncate(dgram_len);
        peer.buf_write = (peer.buf_write + 1) % UNIX_SOCK_BUF_SIZE;
        peer.buffer[peer.buf_write] = @truncate(dgram_len >> 8);
        peer.buf_write = (peer.buf_write + 1) % UNIX_SOCK_BUF_SIZE;
        peer.buf_count += 2;

        // Write data
        ringWrite(&peer.buffer, peer.buf_write, data, len);
        peer.buf_write = (peer.buf_write + @as(u32, @intCast(len))) % UNIX_SOCK_BUF_SIZE;
        peer.buf_count += @as(u32, @intCast(len));
        wake.in |= EpollWake.bit(peer_i);

        // Wake any read waiter on peer
        if (peer.read_waiters) |node| {
            peer.read_waiters = node.next;
            node.next = null;
            @atomicStore(bool, &node.granted, true, .release);
            const task_mod = @import("../proc/task.zig");
            task_mod.unblockTask(node.task_idx);
        }

        return @intCast(len);
    }
}

/// Receive data from own ring buffer.
/// For STREAM: reads bytes from buffer.
/// For DGRAM: reads one datagram (length-prefixed).
/// Returns bytes read, or negative errno on failure.
/// FIONREAD: bytes a read would return now — the queued bytes of a stream, the
/// length of the next datagram of a datagram socket.
pub fn unixReadable(idx: u32) u32 {
    if (idx >= MAX_UNIX_SOCKETS) return 0;
    const saved = unix_lock.acquire();
    defer unix_lock.release(saved);
    const sock = &unix_sockets[idx];
    if (!sock.active) return 0;
    if (sock.sock_type == SOCK_STREAM) return sock.buf_count;
    if (sock.buf_count < 2) return 0;
    const lo = sock.buffer[sock.buf_read];
    const hi = sock.buffer[(sock.buf_read + 1) % UNIX_SOCK_BUF_SIZE];
    return @min(@as(u32, lo) | (@as(u32, hi) << 8), sock.buf_count - 2);
}

pub fn unixRecv(idx: u32, buf: [*]u8, len: usize) i64 {
    if (idx >= MAX_UNIX_SOCKETS) return -9; // EBADF

    var wake: EpollWake = .{};
    defer wake.fire();
    const saved = unix_lock.acquire();
    defer unix_lock.release(saved);

    const sock = &unix_sockets[idx];
    if (!sock.active) return -9; // EBADF
    if (sock.buf_count == 0) {
        // STREAM with no peer (never connected, or peer closed): no data can
        // ever arrive — report EOF instead of EAGAIN.
        if (sock.sock_type == SOCK_STREAM and !sock.connected and !queuedOnBacklogLocked(idx)) return 0;
        return -11; // EAGAIN
    }

    if (sock.sock_type == SOCK_STREAM) {
        const n: usize = @min(len, sock.buf_count);
        ringRead(&sock.buffer, sock.buf_read, buf, n);
        sock.buf_read = (sock.buf_read + @as(u32, @intCast(n))) % UNIX_SOCK_BUF_SIZE;
        sock.buf_count -= @as(u32, @intCast(n));

        if (n > 0 and sock.peer_idx < MAX_UNIX_SOCKETS) {
            const peer = &unix_sockets[sock.peer_idx];
            // Validate the back-reference before touching the peer's waiters —
            // its slot may have been realloc'd to an unrelated socket.
            if (peer.active and peer.connected and peer.peer_idx == @as(u8, @intCast(idx))) {
                wake.out |= EpollWake.bit(sock.peer_idx);
                if (peer.write_waiters != null) {
                    const node = peer.write_waiters.?;
                    peer.write_waiters = node.next;
                    node.next = null;
                    @atomicStore(bool, &node.granted, true, .release);
                    const task_mod = @import("../proc/task.zig");
                    task_mod.unblockTask(node.task_idx);
                }
            }
        }

        return @intCast(n);
    } else {
        // DGRAM: read length prefix first
        if (sock.buf_count < 2) return -11; // EAGAIN

        const lo = sock.buffer[sock.buf_read];
        sock.buf_read = (sock.buf_read + 1) % UNIX_SOCK_BUF_SIZE;
        const hi = sock.buffer[sock.buf_read];
        sock.buf_read = (sock.buf_read + 1) % UNIX_SOCK_BUF_SIZE;
        sock.buf_count -= 2;
        // A length prefix larger than what is buffered can only come from
        // stray bytes in the ring; never trust it past buf_count.
        const dgram_len: usize = @min(@as(usize, lo) | (@as(usize, hi) << 8), @as(usize, sock.buf_count));

        const to_read = @min(len, dgram_len);
        ringRead(&sock.buffer, sock.buf_read, buf, to_read);
        sock.buf_read = (sock.buf_read + @as(u32, @intCast(to_read))) % UNIX_SOCK_BUF_SIZE;
        sock.buf_count -= @as(u32, @intCast(to_read));
        // Discard remaining bytes of this datagram if buf was too small
        const discard: usize = dgram_len - to_read;
        if (discard > 0) {
            const actual_discard = @min(discard, sock.buf_count);
            sock.buf_read = (sock.buf_read + @as(u32, @intCast(actual_discard))) % UNIX_SOCK_BUF_SIZE;
            sock.buf_count -= @as(u32, @intCast(actual_discard));
        }
        wake.out |= sendersIntoLocked(idx);

        // Wake any write waiter on peer
        if (sock.peer_idx < MAX_UNIX_SOCKETS) {
            const peer = &unix_sockets[sock.peer_idx];
            if (peer.active) {
                if (peer.write_waiters != null) {
                    const node = peer.write_waiters.?;
                    peer.write_waiters = node.next;
                    node.next = null;
                    @atomicStore(bool, &node.granted, true, .release);
                    const task_mod = @import("../proc/task.zig");
                    task_mod.unblockTask(node.task_idx);
                }
            }
        }

        return @intCast(to_read);
    }
}

/// Close a Unix socket.
/// Wakes any waiters and disconnects from peer.
pub fn unixClose(idx: u32) void {
    if (idx >= MAX_UNIX_SOCKETS) return;

    var wake: EpollWake = .{};
    defer wake.fire();
    const saved = unix_lock.acquire();
    defer unix_lock.release(saved);

    const sock = &unix_sockets[idx];
    if (!sock.active) return;

    // Shared across fork/clone: drop one reference, free only at zero.
    if (sock.ref_count > 1) {
        sock.ref_count -= 1;
        return;
    }
    sock.ref_count = 0;

    // Wake any waiters
    {
        var cur = sock.read_waiters;
        while (cur) |node| {
            cur = node.next;
            @atomicStore(bool, &node.granted, true, .release);
            const task_mod = @import("../proc/task.zig");
            task_mod.unblockTask(node.task_idx);
        }
        sock.read_waiters = null;
    }
    {
        var cur = sock.write_waiters;
        while (cur) |node| {
            cur = node.next;
            @atomicStore(bool, &node.granted, true, .release);
            const task_mod = @import("../proc/task.zig");
            task_mod.unblockTask(node.task_idx);
        }
        sock.write_waiters = null;
    }
    {
        var cur = sock.accept_waiters;
        while (cur) |node| {
            cur = node.next;
            @atomicStore(bool, &node.granted, true, .release);
            const task_mod = @import("../proc/task.zig");
            task_mod.unblockTask(node.task_idx);
        }
        sock.accept_waiters = null;
    }
    // Connectors still queued on this listener can never be accepted now.
    if (sock.listening) {
        for (sock.backlog[0..sock.backlog_count]) |queued| wake.hup |= EpollWake.bit(queued);
    }
    // DGRAM senders aimed at this socket now fail instead of blocking.
    wake.out |= sendersIntoLocked(idx);

    // Drop this socket from every listener's backlog: its slot is about to be
    // reusable, and a stale entry would let accept() rewire an unrelated socket.
    purgeFromBacklogsLocked(idx);

    // Notify peer that we closed
    if (sock.connected and sock.peer_idx < MAX_UNIX_SOCKETS) {
        const peer = &unix_sockets[sock.peer_idx];
        // Clear the reciprocal link only if the peer still points back at us —
        // after a slot realloc it may belong to an unrelated socket.
        if (peer.active and peer.peer_idx == @as(u8, @intCast(idx))) {
            // Mark peer disconnected: it sees EOF and can no longer send
            // into this (soon-to-be-reused) slot.
            peer.connected = false;
            peer.peer_idx = 255;
            wake.hup |= EpollWake.bit(sock.peer_idx);
            // Wake peer's read waiters so they can detect EOF
            var cur = peer.read_waiters;
            while (cur) |node| {
                cur = node.next;
                @atomicStore(bool, &node.granted, true, .release);
                const task_mod = @import("../proc/task.zig");
                task_mod.unblockTask(node.task_idx);
            }
            peer.read_waiters = null;
        }
    }

    sock.* = .{};
}


// ── blocking wrappers ──────────────────────────────────────────────────────
//
// unixRecv / unixAccept / unixSend answer EAGAIN when they cannot proceed.
// The wake side (send, connect, close) already pops waiters off the three
// wait stacks; these wrappers are the missing producers: a blocking socket
// parks on the stack and re-checks after every wake-up.

const np = @import("../fs/namespace_policy.zig");

fn unlinkWaiter(stack: *?*WaitNode, node: *WaitNode) void {
    var prev: ?*WaitNode = null;
    var cur = stack.*;
    while (cur) |n| {
        if (n == node) {
            if (prev) |p| p.next = n.next else stack.* = n.next;
            n.next = null;
            return;
        }
        prev = n;
        cur = n.next;
    }
}

const WaitKind = enum { read, write, accept };

/// Park the current task on `idx`'s `kind` wait stack if the socket is still
/// in the state the caller observed. Returns 0 after a wake-up (re-check),
/// -4 for an actionable signal, -9 if the socket vanished.
fn parkOn(idx: u32, kind: WaitKind, expect_empty: bool) i64 {
    const task_mod = @import("../proc/task.zig");
    const sched = @import("../proc/sched.zig");
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    var node: WaitNode = .{ .task_idx = cur_idx };
    {
        const saved = unix_lock.acquire();
        const sock = &unix_sockets[idx];
        if (!sock.active) {
            unix_lock.release(saved);
            return -9;
        }
        // The condition may have changed between the caller's check and now;
        // the wake side holds this same lock, so re-testing here loses no wake-up.
        const still = switch (kind) {
            .read => sock.buf_count == 0 and (sock.sock_type != SOCK_STREAM or sock.connected or queuedOnBacklogLocked(idx)),
            .accept => sock.backlog_count == 0 and sock.listening,
            .write => expect_empty,
        };
        if (!still) {
            unix_lock.release(saved);
            return 0;
        }
        const stack: *?*WaitNode = switch (kind) {
            .read => &sock.read_waiters,
            .write => &sock.write_waiters,
            .accept => &sock.accept_waiters,
        };
        node.next = stack.*;
        stack.* = &node;
        task_mod.blockTask(cur_idx);
        unix_lock.release(saved);
    }

    asm volatile ("int $240");
    sched.repairCurrentAfterBlock();

    {
        const saved = unix_lock.acquire();
        const sock = &unix_sockets[idx];
        const stack: *?*WaitNode = switch (kind) {
            .read => &sock.read_waiters,
            .write => &sock.write_waiters,
            .accept => &sock.accept_waiters,
        };
        unlinkWaiter(stack, &node);
        unix_lock.release(saved);
    }
    if (task_mod.getTask(cur_idx)) |ct| {
        const sig_mod = @import("../proc/signal.zig");
        if (sig_mod.pendingFatal(ct)) |sig| task_mod.exitTask(128 + @as(i32, @intCast(sig)));
        if (sig_mod.pendingActionable(ct)) return -4;
    }
    return 0;
}

/// read/recv that waits for data when `nonblock` is false.
pub fn unixRecvBlocking(idx: u32, buf: [*]u8, len: usize, nonblock: bool) i64 {
    while (true) {
        const r = unixRecv(idx, buf, len);
        if (r != -11 or nonblock) return r;
        const w = parkOn(idx, .read, true);
        if (w != 0) return w;
    }
}

/// accept that waits for a connection when `nonblock` is false.
pub fn unixAcceptBlocking(idx: u32, nonblock: bool) i32 {
    while (true) {
        const r = unixAccept(idx);
        if (r != -11 or nonblock) return r;
        const w = parkOn(idx, .accept, true);
        if (w != 0) return @intCast(w);
    }
}

/// shutdown(how): SHUT_RD(0) / SHUT_WR(1) / SHUT_RDWR(2). A stream's peer sees
/// EOF after SHUT_WR; an unconnected socket is ENOTCONN.
pub fn unixShutdown(idx: u32, how: u32) i64 {
    if (how > 2) return -22;
    if (idx >= MAX_UNIX_SOCKETS) return -9;
    var wake: EpollWake = .{};
    defer wake.fire();
    const saved = unix_lock.acquire();
    defer unix_lock.release(saved);
    const sock = &unix_sockets[idx];
    if (!sock.active) return -9;
    if (!sock.connected) return -107; // ENOTCONN
    if (how == 0) return 0;
    // SHUT_WR / SHUT_RDWR: the peer reads EOF from now on. Closing the sending
    // direction is modelled by disconnecting the peer's view of this socket.
    if (sock.peer_idx < MAX_UNIX_SOCKETS) {
        const peer = &unix_sockets[sock.peer_idx];
        if (peer.active and peer.peer_idx == @as(u8, @intCast(idx))) {
            wake.hup |= EpollWake.bit(sock.peer_idx);
            var cur = peer.read_waiters;
            while (cur) |node| {
                cur = node.next;
                @atomicStore(bool, &node.granted, true, .release);
                @import("../proc/task.zig").unblockTask(node.task_idx);
            }
            peer.read_waiters = null;
        }
    }
    return 0;
}

fn purgeFromBacklogsLocked(idx: u32) void {
    for (&unix_sockets) |*l| {
        if (!l.active or !l.listening or l.backlog_count == 0) continue;
        var w: u8 = 0;
        var r: u8 = 0;
        while (r < l.backlog_count) : (r += 1) {
            if (l.backlog[r] == idx) continue;
            l.backlog[w] = l.backlog[r];
            w += 1;
        }
        for (w..l.backlog_count) |j| l.backlog[j] = 255;
        l.backlog_count = w;
    }
}

/// Current epoll readiness of socket `idx`; EPOLLERR once the slot is free.
pub fn unixEpollEvents(idx: u32) u32 {
    const policy = @import("unix_epoll_policy.zig");
    if (idx >= MAX_UNIX_SOCKETS) return EPOLLERR;
    const saved = unix_lock.acquire();
    defer unix_lock.release(saved);
    const sock = &unix_sockets[idx];
    if (!sock.active) return EPOLLERR;
    return policy.events(.{
        .stream = sock.sock_type == SOCK_STREAM,
        .rx_bytes = sock.buf_count,
        .listening = sock.listening,
        .pending_connections = sock.backlog_count,
        .disconnected = !sock.connected,
        .connect_pending = sock.sock_type == SOCK_STREAM and !sock.connected and queuedOnBacklogLocked(idx),
        .peer_free = sendRoomLocked(idx),
    });
}

/// Free bytes in the ring this socket sends into, or null when there is no
/// valid peer (send fails instead of blocking). Mirrors unixSend's checks.
fn sendRoomLocked(idx: u32) ?u32 {
    const sock = &unix_sockets[idx];
    const peer_i: u32 = sock.peer_idx;
    if (peer_i >= MAX_UNIX_SOCKETS or !unix_sockets[peer_i].active) return null;
    const peer = &unix_sockets[peer_i];
    if (sock.sock_type == SOCK_STREAM) {
        if (!sock.connected or !peer.connected or peer.peer_idx != @as(u8, @intCast(idx))) return null;
    }
    return UNIX_SOCK_BUF_SIZE - peer.buf_count;
}

/// Sockets whose sends land in `idx`'s ring (they may become writable).
fn sendersIntoLocked(idx: u32) u32 {
    var mask: u32 = 0;
    for (&unix_sockets, 0..) |*other, i| {
        if (i != idx and other.active and other.peer_idx == idx) mask |= EpollWake.bit(@intCast(i));
    }
    return mask;
}

fn queuedOnBacklogLocked(idx: u32) bool {
    for (&unix_sockets) |*listener| {
        if (!listener.active or !listener.listening) continue;
        for (listener.backlog[0..listener.backlog_count]) |queued| {
            if (queued == idx) return true;
        }
    }
    return false;
}

/// Check if a socket has data available to read.
pub fn unixCanRead(idx: u32) bool {
    if (idx >= MAX_UNIX_SOCKETS) return false;
    const saved = unix_lock.acquire();
    defer unix_lock.release(saved);
    const sock = &unix_sockets[idx];
    if (!sock.active) return false;
    return sock.buf_count > 0 or (sock.listening and sock.backlog_count > 0);
}

/// Check if a socket can accept more data (peer's buffer not full).
pub fn unixCanWrite(idx: u32) bool {
    if (idx >= MAX_UNIX_SOCKETS) return false;
    const saved = unix_lock.acquire();
    defer unix_lock.release(saved);
    const sock = &unix_sockets[idx];
    if (!sock.active) return false;
    if (!sock.connected) return false;
    const peer_i = sock.peer_idx;
    if (peer_i >= MAX_UNIX_SOCKETS) return false;
    return unix_sockets[peer_i].buf_count < UNIX_SOCK_BUF_SIZE;
}
