//! Host tests for the TCP recv empty/EOF policy (kernel/net/tcp_recv_policy.zig).

const std = @import("std");
const p = @import("kernel_shared").tcp_recv_policy;

test "tcp recv delivers buffered bytes in every state that can hold data" {
    const states = [_]p.TcpState{ .established, .fin_wait_1, .fin_wait_2, .closing, .time_wait, .close_wait, .last_ack, .closed };
    for (states) |s| try std.testing.expectEqual(p.RecvDecision.read_data, p.decide(s, 1, false));
}

test "tcp recv on empty ring after peer FIN is EOF (0)" {
    const states = [_]p.TcpState{ .close_wait, .last_ack, .closing, .time_wait, .closed };
    for (states) |s| {
        try std.testing.expectEqual(p.RecvDecision.eof, p.decide(s, 0, false));
        try std.testing.expectEqual(@as(i64, 0), p.emptyResult(p.decide(s, 0, false)));
    }
}

test "tcp recv on empty ring while peer may still send is EAGAIN, not EOF" {
    const states = [_]p.TcpState{ .established, .fin_wait_1, .fin_wait_2, .syn_sent, .syn_received };
    for (states) |s| {
        try std.testing.expectEqual(p.RecvDecision.would_block, p.decide(s, 0, false));
        try std.testing.expectEqual(@as(i64, -11), p.emptyResult(p.decide(s, 0, false)));
    }
}

test "tcp recv on a listening socket is ENOTCONN" {
    try std.testing.expectEqual(p.RecvDecision.not_connected, p.decide(.listen, 0, false));
    try std.testing.expectEqual(p.RecvDecision.not_connected, p.decide(.listen, 5, false));
    try std.testing.expectEqual(@as(i64, -107), p.emptyResult(.not_connected));
}

test "tcp recv on a peer-reset connection with a drained ring is ECONNRESET, not EOF" {
    try std.testing.expectEqual(p.RecvDecision.reset, p.decide(.closed, 0, true));
    try std.testing.expectEqual(@as(i64, -104), p.emptyResult(p.decide(.closed, 0, true)));
}

test "tcp recv still delivers bytes buffered before the peer RST" {
    try std.testing.expectEqual(p.RecvDecision.read_data, p.decide(.closed, 7, true));
}

test "tcp recv orderly close (no RST) stays EOF on a closed TCB" {
    try std.testing.expectEqual(@as(i64, 0), p.emptyResult(p.decide(.closed, 0, false)));
}

test "tcp state enum order stays stable for raw tcpState() consumers" {
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(p.TcpState.established));
    try std.testing.expectEqual(@as(u8, 8), @intFromEnum(p.TcpState.close_wait));
    try std.testing.expectEqual(@as(u8, 10), @intFromEnum(p.TcpState.listen));
}
