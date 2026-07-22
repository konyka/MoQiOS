//! SK-63 — pure ext2 superblock / geometry / inode addressing on non-x86.
//!
//! After SK-61/62 peeled FAT32 parsing, the next fs/ pure layer is ext2:
//! superblock magic+geometry, inode-table location math, mode predicates, and
//! logical-block classification. The x86 driver now delegates those paths via
//! `ext2_util.zig`; this probe builds synthetic on-disk bytes in memory and
//! checks exact values on riscv64/aarch64.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const eu = @import("../fs/ext2_util.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-63] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

fn writeU16(buf: []u8, off: usize, v: u16) void {
    buf[off] = @truncate(v);
    buf[off + 1] = @truncate(v >> 8);
}
fn writeU32(buf: []u8, off: usize, v: u32) void {
    buf[off] = @truncate(v);
    buf[off + 1] = @truncate(v >> 8);
    buf[off + 2] = @truncate(v >> 16);
    buf[off + 3] = @truncate(v >> 24);
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-63] ext2 parse/geometry non-x86: OK\n");
        return;
    }

    // ── Synthetic superblock (1024-byte blocks, rev 1, 256-byte inodes) ───
    var raw: [@sizeOf(eu.Ext2Superblock)]u8 = @splat(0);
    writeU32(&raw, 0, 128); // inodes_count
    writeU32(&raw, 4, 1024); // blocks_count
    writeU32(&raw, 20, 1); // first_data_block (for 1KiB blocks)
    writeU32(&raw, 24, 0); // log_block_size → 1024
    writeU32(&raw, 32, 8192); // blocks_per_group
    writeU32(&raw, 40, 128); // inodes_per_group
    writeU16(&raw, 56, eu.EXT2_MAGIC);
    writeU32(&raw, 76, 1); // rev_level
    writeU16(&raw, 88, 256); // inode_size

    const sb = eu.parseSuperblock(&raw) orelse {
        fail("parseSuperblock");
        return;
    };
    if (sb.magic != eu.EXT2_MAGIC or sb.blocks_count != 1024 or sb.inode_size != 256) {
        fail("superblock fields");
        return;
    }

    // Bad magic → null.
    var bad: [@sizeOf(eu.Ext2Superblock)]u8 = raw;
    writeU16(&bad, 56, 0x1234);
    if (eu.parseSuperblock(&bad) != null) {
        fail("bad magic accepted");
        return;
    }

    const geo = eu.deriveGeometry(&sb) orelse {
        fail("deriveGeometry");
        return;
    };
    // groups_count = ceil(1024/8192) = 1; block_size = 1024; inode_size = 256
    if (geo.block_size != 1024 or geo.groups_count != 1 or geo.inode_size != 256 or
        geo.inodes_per_group != 128 or geo.first_data_block != 1)
    {
        fail("geometry values");
        return;
    }
    if (eu.bgdtBlock(geo.first_data_block) != 2) {
        fail("bgdtBlock");
        return;
    }
    if (eu.ptrsPerBlock(1024) != 256 or eu.ptrsPerBlock(4096) != 1024) {
        fail("ptrsPerBlock");
        return;
    }

    // Zero blocks_per_group → null geometry.
    var zero_bpb = sb;
    zero_bpb.blocks_per_group = 0;
    if (eu.deriveGeometry(&zero_bpb) != null) {
        fail("zero bpg accepted");
        return;
    }

    // ── Inode location (inode 3, table @ block 5, 256-byte stride, 1KiB) ─
    // index = 2 → byte_offset = 512 → block_offset = 0, offset_in_block = 512
    const loc = eu.inodeLocation(3, 128, 256, 1024, 5);
    if (loc.group != 0 or loc.index != 2 or loc.byte_offset != 512 or
        loc.block_offset != 0 or loc.offset_in_block != 512 or loc.target_block != 5 or
        loc.copy_len != @sizeOf(eu.Ext2Inode))
    {
        fail("inodeLocation same block");
        return;
    }
    // inode 5 → index 4 → byte_offset 1024 → next table block
    const loc2 = eu.inodeLocation(5, 128, 256, 1024, 5);
    if (loc2.block_offset != 1 or loc2.offset_in_block != 0 or loc2.target_block != 6) {
        fail("inodeLocation next block");
        return;
    }

    // ── Mode predicates ──────────────────────────────────────────────────
    if (!eu.isDirectory(0x41ED) or eu.isDirectory(0x81A4) or !eu.isRegular(0x81A4) or
        !eu.isSymlink(0xA1FF) or eu.isSymlink(0x41ED))
    {
        fail("mode predicates");
        return;
    }

    // ── Logical block classification (1KiB → 256 ptrs/block) ─────────────
    const ppb: u32 = 256;
    switch (eu.classifyLogicalBlock(3, ppb)) {
        .direct => |i| if (i != 3) {
            fail("direct idx");
            return;
        },
        else => {
            fail("direct kind");
            return;
        },
    }
    switch (eu.classifyLogicalBlock(12, ppb)) {
        .single => |i| if (i != 0) {
            fail("single idx0");
            return;
        },
        else => {
            fail("single kind");
            return;
        },
    }
    // first double-indirect logical = 12 + 256 = 268; rel 0 → (0,0)
    switch (eu.classifyLogicalBlock(268, ppb)) {
        .double => |d| if (d.idx1 != 0 or d.idx2 != 0) {
            fail("double 0,0");
            return;
        },
        else => {
            fail("double kind");
            return;
        },
    }
    // rel 257 → idx1=1, idx2=1
    switch (eu.classifyLogicalBlock(268 + 257, ppb)) {
        .double => |d| if (d.idx1 != 1 or d.idx2 != 1) {
            fail("double 1,1");
            return;
        },
        else => {
            fail("double 1,1 kind");
            return;
        },
    }
    // first triple = 12 + 256 + 256*256 = 65804
    switch (eu.classifyLogicalBlock(65804, ppb)) {
        .triple => |t| if (t.idx1 != 0 or t.idx2 != 0 or t.idx3 != 0) {
            fail("triple 0,0,0");
            return;
        },
        else => {
            fail("triple kind");
            return;
        },
    }

    // ── Dir-entry name helper ────────────────────────────────────────────
    var dent: [16]u8 = @splat(0);
    dent[0] = 2; // inode = 2
    dent[4] = 16; // rec_len
    dent[6] = 3; // name_len
    dent[8] = 'f';
    dent[9] = 'o';
    dent[10] = 'o';
    const name = eu.dirEntryNameSlice(&dent, 3);
    if (!eu.namesEqual(name, "foo") or eu.namesEqual(name, "bar")) {
        fail("dir entry name");
        return;
    }

    arch.serial.writeString("[SK-63] ext2 parse/geometry non-x86: OK\n");
}
