//! Host tests for TCP local-port policy (kernel/net/tcp_port_policy.zig).

const std = @import("std");
const p = @import("kernel_shared").tcp_port_policy;

test "ephemeral successor wraps 65535 back to 49152" {
    try std.testing.expectEqual(@as(u16, 49153), p.nextEphemeralPort(49152));
    try std.testing.expectEqual(@as(u16, 49152), p.nextEphemeralPort(65535));
}

test "port held by any active TCB (TIME_WAIT included) is unavailable" {
    const in_use = [_]u16{ 49152, 50000 };
    try std.testing.expect(!p.portAvailable(49152, &in_use));
    try std.testing.expect(!p.portAvailable(50000, &in_use));
    try std.testing.expect(p.portAvailable(49153, &in_use));
}

test "port 0 is never available" {
    try std.testing.expect(!p.portAvailable(0, &.{}));
}

test "pick skips ports held by live connections" {
    const in_use = [_]u16{ 49152, 49153, 49154 };
    try std.testing.expectEqual(@as(?u16, 49155), p.pickEphemeralPort(49152, &in_use));
}

test "pick on wraparound skips a long-lived connection's port" {
    const in_use = [_]u16{ 65535, 49152 };
    try std.testing.expectEqual(@as(?u16, 49153), p.pickEphemeralPort(65535, &in_use));
}

test "pick returns the start port when it is free" {
    try std.testing.expectEqual(@as(?u16, 60000), p.pickEphemeralPort(60000, &.{1234}));
}

test "pick normalizes a start below the ephemeral range" {
    try std.testing.expectEqual(@as(?u16, 49152), p.pickEphemeralPort(80, &.{}));
}

test "pick returns null when every ephemeral port is taken" {
    var all: [p.EPHEMERAL_COUNT]u16 = undefined;
    for (&all, 0..) |*slot, i| slot.* = @intCast(p.EPHEMERAL_FIRST + i);
    try std.testing.expectEqual(@as(?u16, null), p.pickEphemeralPort(49152, &all));
}

test "connect reallocates a stale port left by a previous slot occupant" {
    try std.testing.expect(p.connectNeedsEphemeral(51234, false));
}

test "connect keeps an explicitly bound port" {
    try std.testing.expect(!p.connectNeedsEphemeral(8080, true));
}

test "connect allocates when no port is set" {
    try std.testing.expect(p.connectNeedsEphemeral(0, false));
    try std.testing.expect(p.connectNeedsEphemeral(0, true));
}
