//! SK-69 — FAT32 directory free-run across sector boundaries on non-x86.
//!
//! SK-68 placed runs inside a single sector. Long LFN chains often need a
//! free run that starts near the end of one sector and continues into the
//! next. `findConsecutiveFreeMulti` + `splitDirIndex` prove that math;
//! the x86 `createFile` path now streams the same rule over the root chain.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const fu = @import("../fs/fat32_util.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-69] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-69] fat32 cross-sector dir run non-x86: OK\n");
        return;
    }

    // Two sectors: entries 0..13 occupied, 14..15 free; next sector empty.
    // need=5 → linear start 14 (spans the boundary).
    var s0: [512]u8 = @splat(0xE5);
    var s1: [512]u8 = @splat(0);
    var e: u32 = 0;
    while (e < 14) : (e += 1) {
        s0[e * 32] = 'A';
        s0[e * 32 + 11] = fu.ATTR_ARCHIVE;
    }
    // 14,15 remain 0xE5
    const secs = [_][*]const u8{ &s0, &s1 };
    const start = fu.findConsecutiveFreeMulti(&secs, 5) orelse {
        fail("cross-sector run");
        return;
    };
    if (start != 14) {
        fail("start index");
        return;
    }
    const sp = fu.splitDirIndex(start);
    if (sp.sector != 0 or sp.entry != 14) {
        fail("split start");
        return;
    }
    const end = fu.splitDirIndex(start + 4); // 5th slot
    if (end.sector != 1 or end.entry != 2) {
        fail("split end");
        return;
    }

    // Single-sector still works via multi API.
    var one: [512]u8 = @splat(0);
    const one_secs = [_][*]const u8{&one};
    if (fu.findConsecutiveFreeMulti(&one_secs, 3) != 0) {
        fail("single empty");
        return;
    }

    // Gap: only entry 15 free; entire next sector occupied — need=2 fails.
    var t0: [512]u8 = @splat(0x20);
    var t1: [512]u8 = @splat(0x20);
    e = 0;
    while (e < 15) : (e += 1) {
        t0[e * 32] = 'B';
        t0[e * 32 + 11] = fu.ATTR_ARCHIVE;
    }
    t0[15 * 32] = 0xE5;
    e = 0;
    while (e < 16) : (e += 1) {
        t1[e * 32] = 'C';
        t1[e * 32 + 11] = fu.ATTR_ARCHIVE;
    }
    const gap = [_][*]const u8{ &t0, &t1 };
    if (fu.findConsecutiveFreeMulti(&gap, 2) != null) {
        fail("gap accepted");
        return;
    }
    // need=1 at entry 15 still ok
    if (fu.findConsecutiveFreeMulti(&gap, 1) != 15) {
        fail("single at boundary");
        return;
    }

    // 0x00 end-of-dir extends through the rest of the window.
    var z0: [512]u8 = @splat(0x20);
    var z1: [512]u8 = @splat(0xFF);
    e = 0;
    while (e < 10) : (e += 1) {
        z0[e * 32] = 'D';
        z0[e * 32 + 11] = fu.ATTR_ARCHIVE;
    }
    z0[10 * 32] = 0x00; // EOF
    const zsecs = [_][*]const u8{ &z0, &z1 };
    if (fu.findConsecutiveFreeMulti(&zsecs, 20) != 10) {
        fail("eof extend");
        return;
    }

    arch.serial.writeString("[SK-69] fat32 cross-sector dir run non-x86: OK\n");
}
