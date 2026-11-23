const std = @import("std");
const up = @import("kernel_shared").icmp_unreach_policy;

test "IPv4 TCP error quotes retain the invoking datagram TTL (hello496)" {
    var msg: [8 + 20 + 8]u8 = @splat(0);
    msg[8] = 0x45;
    msg[8 + 8] = 1;
    msg[8 + 9] = 6;
    msg[28..36].* = .{ 0x9e, 0x26, 0x00, 0x50, 0xde, 0xad, 0xbe, 0xef };
    const quote = up.parseTcpQuote(&msg).?;
    try std.testing.expectEqual(@as(u8, 1), quote.ttl);
    msg[8 + 8] = 2;
    try std.testing.expectEqual(@as(u8, 2), up.parseTcpQuote(&msg).?.ttl);
}
