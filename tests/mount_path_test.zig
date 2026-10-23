const std = @import("std");
const p = @import("kernel_shared").mount_path_policy;

fn norm(in: []const u8) ?[]const u8 {
    const S = struct {
        var buf: [256]u8 = undefined;
    };
    return p.normalizeAbs(in, &S.buf);
}

test "normalisation collapses dots, slashes and parents" {
    try std.testing.expectEqualStrings("/mnt/e", norm("/mnt/e").?);
    try std.testing.expectEqualStrings("/mnt/e", norm("//mnt///e/").?);
    try std.testing.expectEqualStrings("/mnt/e", norm("/mnt/./e").?);
    try std.testing.expectEqualStrings("/mnt", norm("/mnt/e/..").?);
    try std.testing.expectEqualStrings("/", norm("/..").?);
    try std.testing.expectEqualStrings("/", norm("/mnt/../..").?);
    try std.testing.expectEqualStrings("/a/c", norm("/a/b/../c").?);
    try std.testing.expect(norm("relative") == null);
    try std.testing.expect(norm("") == null);
}

test "an over-long path is rejected, not truncated" {
    const long = "/" ++ "a" ** 300;
    try std.testing.expect(norm(long) == null);
}

test "mount targets: root and the built-in trees are refused" {
    try std.testing.expectEqual(p.TargetError.ok, p.checkTarget("/mnt/e"));
    try std.testing.expectEqual(p.TargetError.ok, p.checkTarget("/data"));
    try std.testing.expectEqual(p.TargetError.is_root, p.checkTarget("/"));
    try std.testing.expectEqual(p.TargetError.reserved, p.checkTarget("/dev"));
    try std.testing.expectEqual(p.TargetError.reserved, p.checkTarget("/dev/disk"));
    try std.testing.expectEqual(p.TargetError.reserved, p.checkTarget("/proc"));
    try std.testing.expectEqual(p.TargetError.reserved, p.checkTarget("/tmp/x"));
    try std.testing.expectEqual(p.TargetError.not_absolute, p.checkTarget("mnt"));
    // a name that merely starts with a reserved one is fine
    try std.testing.expectEqual(p.TargetError.ok, p.checkTarget("/devices"));
    try std.testing.expectEqual(p.TargetError.ok, p.checkTarget("/tmpfiles"));
}

test "prefix matching respects component boundaries" {
    try std.testing.expect(p.under("/mnt/e", "/mnt/e"));
    try std.testing.expect(p.under("/mnt/e/a/b", "/mnt/e"));
    try std.testing.expect(!p.under("/mnt/ex", "/mnt/e"));
    try std.testing.expect(!p.under("/mnt", "/mnt/e"));
    try std.testing.expectEqualStrings("a/b", p.rest("/mnt/e/a/b", "/mnt/e"));
    try std.testing.expectEqualStrings("", p.rest("/mnt/e", "/mnt/e"));
    try std.testing.expectEqualStrings("a", p.rest("/mnt/e//a", "/mnt/e"));
}

test "nested or identical mount targets overlap" {
    try std.testing.expect(p.overlaps("/mnt/e", "/mnt/e"));
    try std.testing.expect(p.overlaps("/mnt", "/mnt/e"));
    try std.testing.expect(p.overlaps("/mnt/e/sub", "/mnt/e"));
    try std.testing.expect(!p.overlaps("/mnt/e", "/mnt/n"));
    try std.testing.expect(!p.overlaps("/mnt/e", "/mnt/ex"));
}
