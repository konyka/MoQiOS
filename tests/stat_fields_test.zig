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

test "fromExt2 carries blocks and timestamps" {
    const s = p.fromExt2(5, .{
        .mode = 0o100644,
        .uid_lo = 0,
        .uid_hi = 0,
        .gid_lo = 0,
        .gid_hi = 0,
        .links_count = 1,
        .size_lo = 5000,
        .size_hi = 0,
        .blocks = 16,
        .atime = 100,
        .mtime = 200,
        .ctime = 300,
    });
    try std.testing.expectEqual(@as(u64, 16), s.blocks);
    try std.testing.expectEqual(@as(u64, 100), s.atime);
    try std.testing.expectEqual(@as(u64, 200), s.mtime);
    try std.testing.expectEqual(@as(u64, 300), s.ctime);
}

const fu = @import("kernel_shared").fat32_util;

test "FAT timestamps round-trip at 2-second resolution" {
    const cases = [_]u64{ 315532800, 951782400, 1700000000, 1792659426, 4102444798 };
    for (cases) |t| {
        const s = fu.unixToDos(t);
        try std.testing.expectEqual(t - (t % 2), fu.dosToUnix(s.date, s.time));
    }
}

test "FAT timestamps clamp to the FAT epoch and treat date 0 as unset" {
    const s = fu.unixToDos(0);
    try std.testing.expectEqual(@as(u64, 315532800), fu.dosToUnix(s.date, s.time));
    try std.testing.expectEqual(@as(u64, 0), fu.dosToUnix(0, 0));
}

test "FAT directory entry write time is stored at offsets 22..25" {
    var e: [32]u8 = @splat(0);
    fu.setDirEntryMtime(&e, fu.unixToDos(1700000000));
    try std.testing.expectEqual(@as(u64, 1700000000), fu.dirEntryMtime(&e));
}
