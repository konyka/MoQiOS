const std = @import("std");
const p = @import("kernel_shared").rofs_map_policy;

test "admission follows the Linux order of errors" {
    try std.testing.expectEqual(p.Verdict.ok, p.admit(false, 0, 300000, 1, false));
    try std.testing.expectEqual(p.Verdict.ok, p.admit(false, 8192, 4096, 1, true)); // shared read-only is fine
    try std.testing.expectEqual(p.Verdict.ok, p.admit(false, 0, 4096, 3, false)); // private writable is a private copy
    try std.testing.expectEqual(p.Verdict.invalid, p.admit(false, 100, 4096, 1, false));
    // a bad offset wins over every other complaint
    try std.testing.expectEqual(p.Verdict.invalid, p.admit(true, 1, 1 << 40, 3, true));
    try std.testing.expectEqual(p.Verdict.no_device, p.admit(true, 0, 4096, 1, false));
    try std.testing.expectEqual(p.Verdict.access, p.admit(false, 0, 4096, 2, true));
    try std.testing.expectEqual(p.Verdict.access, p.admit(false, 0, 4096, 3, true));
}

test "the size cap refuses what would be populated eagerly" {
    const cap = p.MAX_PAGES * p.PAGE;
    try std.testing.expectEqual(p.Verdict.ok, p.admit(false, 0, cap, 1, false));
    try std.testing.expectEqual(p.Verdict.no_memory, p.admit(false, 0, cap + 1, 1, false));
    try std.testing.expectEqual(p.Verdict.no_memory, p.admit(false, 0, std.math.maxInt(u64), 1, false));
}

test "page counts round up" {
    try std.testing.expectEqual(@as(u64, 1), p.pageCount(1));
    try std.testing.expectEqual(@as(u64, 1), p.pageCount(4096));
    try std.testing.expectEqual(@as(u64, 2), p.pageCount(4097));
    try std.testing.expectEqual(@as(u64, 74), p.pageCount(300000));
}

test "valid bytes: full pages, a partial last page, and nothing past EOF" {
    const size: u64 = 300000; // 73 full pages + 2208 bytes
    try std.testing.expectEqual(@as(u32, 4096), p.validBytes(size, 0, 0));
    try std.testing.expectEqual(@as(u32, 4096), p.validBytes(size, 0, 72));
    try std.testing.expectEqual(@as(u32, 300000 - 73 * 4096), p.validBytes(size, 0, 73));
    try std.testing.expectEqual(@as(u32, 0), p.validBytes(size, 0, 74));
    // an offset shifts the window
    try std.testing.expectEqual(@as(u32, 4096), p.validBytes(size, 8192, 0));
    try std.testing.expectEqual(@as(u32, 300000 - 73 * 4096), p.validBytes(size, 8192, 71));
    try std.testing.expectEqual(@as(u32, 0), p.validBytes(size, 8192, 72));
    // an exact multiple has no partial page
    try std.testing.expectEqual(@as(u32, 4096), p.validBytes(8192, 0, 1));
    try std.testing.expectEqual(@as(u32, 0), p.validBytes(8192, 0, 2));
    try std.testing.expectEqual(@as(u32, 0), p.validBytes(0, 0, 0));
}

test "hostile offsets and indexes cannot overflow" {
    const huge = std.math.maxInt(u64) - 4095;
    try std.testing.expectEqual(@as(u32, 0), p.validBytes(1000, huge, 1));
    try std.testing.expectEqual(@as(u32, 0), p.validBytes(1000, 0, std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(u32, 0), p.validBytes(std.math.maxInt(u64), huge, 5));
}
