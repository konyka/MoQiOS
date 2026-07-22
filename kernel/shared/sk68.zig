//! SK-68 — FAT32 directory slot placement helpers on non-x86.
//!
//! SK-67 createFile only searched the first root sector. Placement math
//! (`findConsecutiveFree` / `shortNameTaken` / `sectorHasDirEnd`) is now pure
//! in `fat32_util`; the x86 driver walks every sector of the root cluster
//! chain (and can grow it). This probe locks the per-sector placement rules.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const fu = @import("../fs/fat32_util.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-68] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-68] fat32 dir slot placement non-x86: OK\n");
        return;
    }

    // Empty sector: any need ≤ 16 fits at index 0; 0x00 extends the run.
    var sec: [512]u8 = @splat(0);
    if (fu.findConsecutiveFree(&sec, 1) != 0 or fu.findConsecutiveFree(&sec, 16) != 0 or
        fu.findConsecutiveFree(&sec, 17) != null)
    {
        fail("empty sector free");
        return;
    }
    if (!fu.sectorHasDirEnd(&sec)) {
        fail("empty has dir end");
        return;
    }

    // Occupied [0..2], free from 3: need=3 → start 3; need=14 → start 3; need=15 → null
    @memset(&sec, 0xE5);
    sec[0] = 'A';
    sec[11] = fu.ATTR_ARCHIVE;
    sec[32] = 'B';
    sec[32 + 11] = fu.ATTR_ARCHIVE;
    sec[64] = 'C';
    sec[64 + 11] = fu.ATTR_ARCHIVE;
    // entry 3..15 still 0xE5 (free)
    if (fu.findConsecutiveFree(&sec, 3) != 3 or fu.findConsecutiveFree(&sec, 13) != 3 or
        fu.findConsecutiveFree(&sec, 14) != null)
    {
        fail("partial free run");
        return;
    }
    if (fu.sectorHasDirEnd(&sec)) {
        fail("no dir end expected");
        return;
    }

    // shortNameTaken: match short name at entry 0 (entry-0 0x00 would end the dir).
    var short: [11]u8 = undefined;
    fu.encode83Name("foo.txt", &short);
    @memset(&sec, 0);
    @memcpy(sec[0..11], short[0..11]);
    sec[11] = fu.ATTR_ARCHIVE;
    if (!fu.shortNameTaken(&sec, &short)) {
        fail("short taken");
        return;
    }
    var other: [11]u8 = undefined;
    fu.encode83Name("bar.txt", &other);
    if (fu.shortNameTaken(&sec, &other)) {
        fail("short not taken");
        return;
    }
    // LFN slot must not count as a collision; the following short entry does.
    @memset(&sec, 0);
    sec[0] = 0x41;
    sec[11] = fu.ATTR_LFN;
    @memcpy(sec[32..43], short[0..11]);
    sec[32 + 11] = fu.ATTR_ARCHIVE;
    if (!fu.shortNameTaken(&sec, &short)) {
        fail("short behind lfn");
        return;
    }

    // Gap breaks a run: free 0, occupied 1, free 2.. → need=2 null from start
    @memset(&sec, 0xE5);
    sec[32] = 'X';
    sec[32 + 11] = fu.ATTR_ARCHIVE;
    if (fu.findConsecutiveFree(&sec, 2) != 2) { // starts at entry 2
        fail("gap run");
        return;
    }
    if (fu.findConsecutiveFree(&sec, 1) != 0) {
        fail("first free slot");
        return;
    }

    arch.serial.writeString("[SK-68] fat32 dir slot placement non-x86: OK\n");
}
