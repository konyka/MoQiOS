const std = @import("std");
const kt = @import("kernel_shared");
const rp = kt.tcp_recv_policy;
const ns = kt.notsent_lowat_sysctl;

// net.ipv4.tcp_notsent_lowat (hello502): a socket whose TCP_NOTSENT_LOWAT is 0 uses the sysctl (default UINT_MAX = no limit);
// one that set a value keeps it. The sysctl is proc_douintvec: an unsigned int, a negative or oversized write is EINVAL.
test "a zero TCP_NOTSENT_LOWAT falls back to net.ipv4.tcp_notsent_lowat (hello502)" {
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), rp.notsentLimitWith(0, std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(u32, 4096), rp.notsentLimitWith(0, 4096));
    try std.testing.expectEqual(@as(u32, 1024), rp.notsentLimitWith(1024, 4096));
    try std.testing.expect(!rp.notsentAllowsQueueWith(4096, 0, 4096));
    try std.testing.expect(rp.notsentAllowsQueueWith(4095, 0, 4096));
    try std.testing.expect(!rp.notsentWritableWith(2048, 0, 4096));
    try std.testing.expect(rp.notsentWritableWith(2047, 0, 4096));
    // Draining below the sysctl limit wakes writers too; no limit at all never does.
    try std.testing.expect(rp.notsentWakeOnSendWith(3000, 1000, 0, 4096));
    try std.testing.expect(!rp.notsentWakeOnSendWith(3000, 1000, 0, std.math.maxInt(u32)));
    try std.testing.expect(rp.notsentWakeOnSendWith(1500, 400, 1024, std.math.maxInt(u32)));
}

test "net.ipv4.tcp_notsent_lowat parses like proc_douintvec and keeps the old value on error (hello502)" {
    defer _ = ns.write("4294967295\n");
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), ns.get());
    try std.testing.expectEqual(@as(i64, 5), ns.write("1024\n"));
    try std.testing.expectEqual(@as(u32, 1024), ns.get());
    try std.testing.expectEqual(@as(i64, -22), ns.write("-1\n"));
    try std.testing.expectEqual(@as(i64, -22), ns.write("4294967296\n"));
    try std.testing.expectEqual(@as(i64, -22), ns.write("abc\n"));
    try std.testing.expectEqual(@as(u32, 1024), ns.get());
    try std.testing.expectEqual(@as(i64, 4), ns.write(" 77 "));
    try std.testing.expectEqual(@as(u32, 77), ns.get());
    try std.testing.expectEqual(@as(i64, 10), ns.write("4294967295"));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), ns.get());
    var buf: [16]u8 = undefined;
    const n = ns.format(&buf);
    try std.testing.expectEqualStrings("4294967295\n", buf[0..n]);
}
