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

/// WaitNode for blocking operations — stack-allocated on the waiter's kernel stack.
pub const WaitNode = struct {
    task_idx: u32,
    granted: bool = false,
    next: ?*WaitNode = null,
};

pub const UnixSocket = struct {
    active: bool = false,
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
        .peer_idx = @intCast(conn_idx),
    };

    // Mark the connector as connected to the new socket
    const conn_sock = &unix_sockets[conn_idx];
    conn_sock.connected = true;
    conn_sock.peer_idx = @intCast(new_idx);

    return @intCast(new_idx);
}

/// Send data to a connected peer.
/// For STREAM: writes to peer's ring buffer.
/// For DGRAM: writes to peer's ring buffer (uses peer_idx).
/// Returns bytes sent, or negative errno on failure.
pub fn unixSend(idx: u32, data: [*]const u8, len: usize) i64 {
    if (idx >= MAX_UNIX_SOCKETS) return -9; // EBADF

    const saved = unix_lock.acquire();
    defer unix_lock.release(saved);

    const sock = &unix_sockets[idx];
    if (!sock.active) return -9; // EBADF

    if (sock.sock_type == SOCK_STREAM) {
        if (!sock.connected) return -107; // ENOTCONN
        const peer_i: u32 = sock.peer_idx;
        if (peer_i >= MAX_UNIX_SOCKETS or !unix_sockets[peer_i].active) return -32; // EPIPE

        const peer = &unix_sockets[peer_i];
        var n: usize = 0;
        while (n < len and peer.buf_count < UNIX_SOCK_BUF_SIZE) {
            peer.buffer[peer.buf_write] = data[n];
            peer.buf_write = (peer.buf_write + 1) % UNIX_SOCK_BUF_SIZE;
            peer.buf_count += 1;
            n += 1;
        }

        // Wake any read waiter on peer
        if (n > 0 and peer.read_waiters) |node| {
            peer.read_waiters = node.next;
            node.next = null;
            @atomicStore(bool, &node.granted, true, .release);
            const task_mod = @import("../proc/task.zig");
            task_mod.unblockTask(node.task_idx);
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
        for (0..len) |j| {
            peer.buffer[peer.buf_write] = data[j];
            peer.buf_write = (peer.buf_write + 1) % UNIX_SOCK_BUF_SIZE;
            peer.buf_count += 1;
        }

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
pub fn unixRecv(idx: u32, buf: [*]u8, len: usize) i64 {
    if (idx >= MAX_UNIX_SOCKETS) return -9; // EBADF

    const saved = unix_lock.acquire();
    defer unix_lock.release(saved);

    const sock = &unix_sockets[idx];
    if (!sock.active) return -9; // EBADF
    if (sock.buf_count == 0) return -11; // EAGAIN

    if (sock.sock_type == SOCK_STREAM) {
        var n: usize = 0;
        while (n < len and sock.buf_count > 0) {
            buf[n] = sock.buffer[sock.buf_read];
            sock.buf_read = (sock.buf_read + 1) % UNIX_SOCK_BUF_SIZE;
            sock.buf_count -= 1;
            n += 1;
        }

        if (n > 0 and sock.peer_idx < MAX_UNIX_SOCKETS) {
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

        return @intCast(n);
    } else {
        // DGRAM: read length prefix first
        if (sock.buf_count < 2) return -11; // EAGAIN

        const lo = sock.buffer[sock.buf_read];
        sock.buf_read = (sock.buf_read + 1) % UNIX_SOCK_BUF_SIZE;
        const hi = sock.buffer[sock.buf_read];
        sock.buf_read = (sock.buf_read + 1) % UNIX_SOCK_BUF_SIZE;
        sock.buf_count -= 2;
        const dgram_len: usize = @as(usize, lo) | (@as(usize, hi) << 8);

        const to_read = @min(len, dgram_len);
        for (0..to_read) |j| {
            buf[j] = sock.buffer[sock.buf_read];
            sock.buf_read = (sock.buf_read + 1) % UNIX_SOCK_BUF_SIZE;
            sock.buf_count -= 1;
        }
        // Discard remaining bytes of this datagram if buf was too small
        var discard: usize = dgram_len - to_read;
        while (discard > 0 and sock.buf_count > 0) {
            sock.buf_read = (sock.buf_read + 1) % UNIX_SOCK_BUF_SIZE;
            sock.buf_count -= 1;
            discard -= 1;
        }

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

    const saved = unix_lock.acquire();
    defer unix_lock.release(saved);

    const sock = &unix_sockets[idx];
    if (!sock.active) return;

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

    // Notify peer that we closed
    if (sock.connected and sock.peer_idx < MAX_UNIX_SOCKETS) {
        const peer = &unix_sockets[sock.peer_idx];
        if (peer.active) {
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
