//! Host tests for kernel/fs/stat_info.zig: ext2 inode → fstat/statx fields.

const std = @import("std");
const p = @import("kernel_shared").stat_info;

test "ext2 directory mode keeps S_IFDIR and permission bits" {
    try std.testing.expectEqual(@as(u32, 0o040755), p.ext2StMode(0o040755));
}

test "ext2 regular file mode is reported verbatim, not 0o100644" {
    try std.testing.expectEqual(@as(u32, 0o100600), p.ext2StMode(0o100600));
    try std.testing.expectEqual(@as(u32, 0o104755), p.ext2StMode(0o104755));
    try std.testing.expectEqual(@as(u32, 0o120777), p.ext2StMode(0o120777));
}

test "ext2 inode without type bits falls back to S_IFREG" {
    try std.testing.expectEqual(@as(u32, 0o100644), p.ext2StMode(0o644));
}

test "ext2 size_high only extends regular files" {
    try std.testing.expectEqual(@as(u64, 0x1_0000_0010), p.ext2Size(0o100644, 0x10, 1));
    try std.testing.expectEqual(@as(u64, 4096), p.ext2Size(0o040755, 4096, 7));
}

test "ext2 uid/gid combine low and high halves" {
    try std.testing.expectEqual(@as(u32, 1000), p.ext2Id(1000, 0));
    try std.testing.expectEqual(@as(u32, 0x0001_0002), p.ext2Id(2, 1));
}

test "fromExt2 uses the real inode number and link count" {
    const s = p.fromExt2(12, .{
        .mode = 0o100640,
        .uid_lo = 1000,
        .uid_hi = 0,
        .gid_lo = 100,
        .gid_hi = 0,
        .links_count = 3,
        .size_lo = 5000,
        .size_hi = 0,
    });
    try std.testing.expectEqual(@as(u64, 12), s.ino);
    try std.testing.expectEqual(@as(u32, 0o100640), s.mode);
    try std.testing.expectEqual(@as(u32, 1000), s.uid);
    try std.testing.expectEqual(@as(u32, 100), s.gid);
    try std.testing.expectEqual(@as(u32, 3), s.nlink);
    try std.testing.expectEqual(@as(u64, 5000), s.size);
}
