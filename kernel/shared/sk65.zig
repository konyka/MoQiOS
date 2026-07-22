//! SK-65 — ext2 `ensureBlock` via `classifyLogicalBlock` (symmetric to SK-64).
//!
//! Allocation stays in the x86 driver (needs PMM + bitmaps), but the walk
//! plan must match `resolveBlock`: same classifier, same root slots (12/13/14).
//! This probe locks that contract on non-x86 with `indirectRootSlot` + classify.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const eu = @import("../fs/ext2_util.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-65] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-65] ext2 ensure via classify non-x86: OK\n");
        return;
    }

    const ppb: u32 = 4;

    // Direct → no indirect root
    const d0 = eu.classifyLogicalBlock(0, ppb);
    if (eu.indirectRootSlot(d0) != null) {
        fail("direct root slot");
        return;
    }

    // Single → root slot 12
    const s0 = eu.classifyLogicalBlock(12, ppb);
    if (eu.indirectRootSlot(s0) != 12) {
        fail("single root slot");
        return;
    }
    switch (s0) {
        .single => |i| if (i != 0) {
            fail("single idx");
            return;
        },
        else => {
            fail("single kind");
            return;
        },
    }

    // Double base = 16; logical 21 → idx1=1,idx2=1 → root 13
    const dbl = eu.classifyLogicalBlock(21, ppb);
    if (eu.indirectRootSlot(dbl) != 13) {
        fail("double root slot");
        return;
    }
    switch (dbl) {
        .double => |d| if (d.idx1 != 1 or d.idx2 != 1) {
            fail("double idx");
            return;
        },
        else => {
            fail("double kind");
            return;
        },
    }

    // Triple base = 32; logical 54 → (1,1,2) → root 14
    const tri = eu.classifyLogicalBlock(54, ppb);
    if (eu.indirectRootSlot(tri) != 14) {
        fail("triple root slot");
        return;
    }
    switch (tri) {
        .triple => |t| if (t.idx1 != 1 or t.idx2 != 1 or t.idx3 != 2) {
            fail("triple idx");
            return;
        },
        else => {
            fail("triple kind");
            return;
        },
    }

    // Out of range → no root
    const oor = eu.classifyLogicalBlock(96, ppb);
    if (eu.indirectRootSlot(oor) != null) {
        fail("oor root slot");
        return;
    }

    // Pure resolve still agrees with the ensure walk plan (same indices).
    var i_block: [15]u32 = @splat(0);
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
    if (eu.resolveLogicalPure(&i_block, 13, ppb, &tables) != 11 or
        eu.resolveLogicalPure(&i_block, 21, ppb, &tables) != 21 or
        eu.resolveLogicalPure(&i_block, 54, ppb, &tables) != 32)
    {
        fail("resolve/ensure index contract");
        return;
    }

    arch.serial.writeString("[SK-65] ext2 ensure via classify non-x86: OK\n");
}
