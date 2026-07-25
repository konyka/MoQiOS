//! SK-153 — ext2 block group descriptor stride is the on-disk 32 bytes (non-x86).
//!
//! `Ext2GroupDesc` omitted the trailing pad and reserved words, so `@sizeOf`
//! was 20. Every descriptor after the first was then indexed 12 bytes short of
//! where it lives on disk — `bg_inode_table` for group 1 read as 0 — and
//! `writeGroupDescs` wrote the table back with the same wrong stride, landing
//! on top of the next descriptor.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const eu = @import("../fs/ext2_util.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-153] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

/// Two descriptors exactly as mke2fs lays them out on the 16384-block, 1KiB
/// test image: group 0 at +0, group 1 at +32.
const bgdt: [64]u8 align(@alignOf(eu.Ext2GroupDesc)) = .{
    0x42, 0x00, 0x00, 0x00, 0x43, 0x00, 0x00, 0x00, 0x44, 0x00, 0x00, 0x00,
    0x9c, 0x1f, 0x32, 0x00, 0x02, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x42, 0x20, 0x00, 0x00, 0x43, 0x20, 0x00, 0x00, 0x44, 0x20, 0x00, 0x00,
    0xac, 0x1f, 0x40, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-153] ext2 group desc stride non-x86: OK\n");
        return;
    }

    if (@sizeOf(eu.Ext2GroupDesc) != eu.GROUP_DESC_SIZE or eu.GROUP_DESC_SIZE != 32) {
        fail("stride");
        return;
    }

    // Indexing the real on-disk table must reach group 1's actual fields.
    const gds: [*]const eu.Ext2GroupDesc = @ptrCast(&bgdt);
    if (gds[0].bg_inode_table != 0x44 or gds[0].bg_free_inodes_count != 0x32) {
        fail("group0");
        return;
    }
    if (gds[1].bg_block_bitmap != 0x2042 or
        gds[1].bg_inode_bitmap != 0x2043 or
        gds[1].bg_inode_table != 0x2044 or
        gds[1].bg_free_inodes_count != 64)
    {
        fail("group1");
        return;
    }

    // Inode 65 is the first inode of group 1 on that image (64 per group), so
    // it must resolve against group 1's inode table, not group 0's.
    const loc = eu.inodeLocation(65, 64, 256, 1024, gds[1].bg_inode_table);
    if (loc.group != 1 or loc.index != 0 or loc.target_block != 0x2044) {
        fail("inode 65");
        return;
    }
    // Last inode of group 1: index 63, byte offset 63*256 = 15 blocks in.
    const last = eu.inodeLocation(128, 64, 256, 1024, gds[1].bg_inode_table);
    if (last.index != 63 or last.target_block != 0x2044 + 15 or last.offset_in_block != 768) {
        fail("inode 128");
        return;
    }

    arch.serial.writeString("[SK-153] ext2 group desc stride non-x86: OK\n");
}
