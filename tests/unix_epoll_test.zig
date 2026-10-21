//! Host tests for AF_UNIX epoll readiness (kernel/net/unix_epoll_policy.zig).

const std = @import("std");
const p = @import("kernel_shared").unix_epoll_policy;

fn connectedStream(rx: u32, peer_free: u32) p.State {
    return .{
        .stream = true,
        .rx_bytes = rx,
        .listening = false,
        .pending_connections = 0,
        .disconnected = false,
        .peer_free = peer_free,
    };
}

test "epoll ABI bits match Linux" {
    try std.testing.expectEqual(@as(u32, 0x001), p.EPOLLIN);
    try std.testing.expectEqual(@as(u32, 0x004), p.EPOLLOUT);
    try std.testing.expectEqual(@as(u32, 0x010), p.EPOLLHUP);
}

test "empty connected stream is writable but not readable" {
    try std.testing.expectEqual(p.EPOLLOUT, p.events(connectedStream(0, 8192)));
}

test "queued bytes make a stream readable" {
    try std.testing.expectEqual(p.EPOLLIN | p.EPOLLOUT, p.events(connectedStream(1, 8192)));
}

test "full peer ring clears EPOLLOUT" {
    try std.testing.expectEqual(p.EPOLLIN, p.events(connectedStream(5, 0)));
}

test "peer close reports HUP and EOF-readable even with an empty ring" {
    var s = connectedStream(0, 0);
    s.disconnected = true;
    s.peer_free = null;
    // read() returns 0 and send() fails with EPIPE: neither blocks.
    try std.testing.expectEqual(p.EPOLLIN | p.EPOLLOUT | p.EPOLLHUP, p.events(s));
}

test "listener is readable only with a pending connection, never HUP or writable" {
    var s: p.State = .{
        .stream = true,
        .rx_bytes = 0,
        .listening = true,
        .pending_connections = 0,
        // A listener has no peer: connected is false for it too.
        .disconnected = true,
        .peer_free = null,
    };
    try std.testing.expectEqual(@as(u32, 0), p.events(s));
    s.pending_connections = 1;
    try std.testing.expectEqual(p.EPOLLIN, p.events(s));
}

test "connector waiting for accept is not hung up" {
    const s: p.State = .{
        .stream = true,
        .rx_bytes = 0,
        .listening = false,
        .pending_connections = 0,
        .disconnected = true,
        .connect_pending = true,
        .peer_free = null,
    };
    try std.testing.expectEqual(@as(u32, 0), p.events(s));
}

test "datagram writability needs room for the length prefix plus a byte" {
    var s: p.State = .{
        .stream = false,
        .rx_bytes = 0,
        .listening = false,
        .pending_connections = 0,
        .disconnected = false,
        .peer_free = 2,
    };
    try std.testing.expectEqual(@as(u32, 0), p.events(s));
    s.peer_free = 3;
    try std.testing.expectEqual(p.EPOLLOUT, p.events(s));
}

test "datagram never reports HUP" {
    const s: p.State = .{
        .stream = false,
        .rx_bytes = 4,
        .listening = false,
        .pending_connections = 0,
        .disconnected = true,
        .peer_free = null,
    };
    try std.testing.expectEqual(p.EPOLLIN | p.EPOLLOUT, p.events(s));
}
