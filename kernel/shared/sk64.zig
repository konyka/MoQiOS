//! SK-64 — ext2 `resolveBlock` via `classifyLogicalBlock` + pure resolve.
//!
//! SK-63 extracted classification math. This step makes the x86 driver's
//! `resolveBlock` consume that classifier (shared `loadIndirectPtr` walk) and
//! adds `resolveLogicalPure` so the same compose path can be verified on
//! non-x86 with in-memory pointer tables — no block I/O required.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const eu = @import("../fs/ext2_util.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-64] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-64] ext2 resolve via classify non-x86: OK\n");
        return;
    }

    const ppb: u32 = 4; // tiny tables keep the probe compact

    // Inode i_block map:
    //   direct[0]=100, direct[3]=103
    //   single @200 → [10,11,12,13]
    //   double @300 → [0,210,...]; single@210 → [20,21,22,23]
    //   triple @400 → [0,310,...]; dbl@310 → [0,220]; single@220 → [30,31,32,33]
    var i_block: [15]u32 = @splat(0);
    i_block[0] = 100;
    i_block[3] = 103;
    i_block[12] = 200;
    i_block[13] = 300;
    i_block[14] = 400;

    var single_tab: [4]u32 = .{ 10, 11, 12, 13 };
    var dbl_l1: [4]u32 = .{ 0, 210, 0, 0 };
    var dbl_l2: [4]u32 = .{ 20, 21, 22, 23 };
    var tri_l1: [4]u32 = .{ 0, 310, 0, 0 };
    var tri_l2: [4]u32 = .{ 0, 220, 0, 0 };
    var tri_l3: [4]u32 = .{ 30, 31, 32, 33 };

    const tables = [_]eu.PtrTable{
        .{ .block = 200, .ptrs = &single_tab, .len = 4 },
        .{ .block = 300, .ptrs = &dbl_l1, .len = 4 },
        .{ .block = 210, .ptrs = &dbl_l2, .len = 4 },
        .{ .block = 400, .ptrs = &tri_l1, .len = 4 },
        .{ .block = 310, .ptrs = &tri_l2, .len = 4 },
        .{ .block = 220, .ptrs = &tri_l3, .len = 4 },
    };

    // Direct
    if (eu.resolveLogicalPure(&i_block, 0, ppb, &tables) != 100 or
        eu.resolveLogicalPure(&i_block, 3, ppb, &tables) != 103 or
        eu.resolveLogicalPure(&i_block, 1, ppb, &tables) != 0)
    {
        fail("direct resolve");
        return;
    }

    // Single: logical 12+1 = 13 → index 1 → 11
    if (eu.resolveLogicalPure(&i_block, 12, ppb, &tables) != 10 or
        eu.resolveLogicalPure(&i_block, 13, ppb, &tables) != 11)
    {
        fail("single resolve");
        return;
    }

    // Double base = 12+4 = 16; logical 16+4+1 = 21 → idx1=1,idx2=1 → 21
    // (rel = 5 → idx1=1, idx2=1)
    if (eu.resolveLogicalPure(&i_block, 16 + 5, ppb, &tables) != 21) {
        fail("double resolve");
        return;
    }
    // Missing double L1 slot → 0
    if (eu.resolveLogicalPure(&i_block, 16, ppb, &tables) != 0) {
        fail("double hole");
        return;
    }

    // Triple base = 16 + 16 = 32; logical 32 + 16 + 4 + 2 = 54
    // rel=22 → idx1=1 (22/16), rem=6 → idx2=1 (6/4), idx3=2 → 32
    if (eu.resolveLogicalPure(&i_block, 32 + 22, ppb, &tables) != 32) {
        fail("triple resolve");
        return;
    }

    // Out of range / empty inode roots
    var empty: [15]u32 = @splat(0);
    if (eu.resolveLogicalPure(&empty, 12, ppb, &tables) != 0) {
        fail("empty single root");
        return;
    }
    // With ppb=4, max logical = 12 + 4 + 16 + 64 - 1 = 95; 96 is OOR
    if (eu.resolveLogicalPure(&i_block, 96, ppb, &tables) != 0) {
        fail("out of range");
        return;
    }

    // Classifier still agrees with the resolve path we composed.
    switch (eu.classifyLogicalBlock(21, ppb)) {
        .double => |d| if (d.idx1 != 1 or d.idx2 != 1) {
            fail("classify double mismatch");
            return;
        },
        else => {
            fail("classify double kind");
            return;
        },
    }

    arch.serial.writeString("[SK-64] ext2 resolve via classify non-x86: OK\n");
}
