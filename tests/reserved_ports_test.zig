const std = @import("std");
const kt = @import("kernel_shared");
const rp = kt.reserved_port_policy;
const tp = kt.tcp_port_policy;

test "reserved port lists are transactional and automatic allocation skips them (hello495)" {
    try std.testing.expectEqual(@as(i64, 18), rp.write("52000,52002-52004\n", true));
    rp.readLock();
    const bits = rp.bytes();
    try std.testing.expect(bits[6500] & 0x01 != 0);
    try std.testing.expect(bits[6500] & 0x02 == 0);
    try std.testing.expect(bits[6500] & 0x1c == 0x1c);
    const system: u32 = 52000 | (52010 << 16);
    try std.testing.expectEqual(@as(?u16, 52001), tp.pickEphemeralPortInRange(52000, &.{}, 0, system, bits));
    rp.readUnlock();
    var text: [128]u8 = undefined;
    const n = rp.format(&text);
    try std.testing.expectEqualStrings("52000,52002-52004\n", text[0..n]);
    try std.testing.expectEqual(@as(i64, -22), rp.write("52004-52002\n", true));
    try std.testing.expectEqual(@as(i64, -22), rp.write("65536\n", true));
    const after = rp.format(&text);
    try std.testing.expectEqualStrings("52000,52002-52004\n", text[0..after]);
    try std.testing.expectEqual(@as(i64, 1), rp.write("\n", true));
    const cleared = rp.format(&text);
    try std.testing.expectEqualStrings("\n", text[0..cleared]);
}
