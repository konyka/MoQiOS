//! SK-152 — writeback accepts writes larger than one buffer (non-x86).
//!
//! A dirty buffer holds at most one page, so `writeBuffered` has to spread a
//! longer write across several of them. It used to silently keep only the first
//! page while its callers reported a full write, losing half of every 8 KiB
//! chunk that `copy_file_range` and `splice` pipe→file push through.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const writeback = @import("../fs/writeback.zig");

const FILE_IDX: u32 = 52;
const BASE: u64 = 65536;

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-152] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-152] writeback multi-page write non-x86: OK\n");
        return;
    }

    // Distinct bytes per page so a dropped or duplicated extent is visible.
    var src: [8192]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @truncate(i / 4096 + 1);

    if (writeback.writeBuffered(FILE_IDX, BASE, &src, src.len, .ext2) != src.len) {
        fail("accepted len");
        return;
    }

    // Each page must be retrievable at its own offset with the right contents.
    var out: [4096]u8 = undefined;
    for (0..2) |page| {
        const off = BASE + @as(u64, page) * 4096;
        if (writeback.readBuffered(FILE_IDX, off, &out, out.len, .ext2) != out.len) {
            fail("extent len");
            return;
        }
        const want: u8 = @truncate(page + 1);
        if (out[0] != want or out[4095] != want) {
            fail("extent content");
            return;
        }
    }

    // Rewriting a shorter run at the same offset must not shorten the extent:
    // the untouched tail is still dirty and has not reached the disk yet.
    if (writeback.writeBuffered(FILE_IDX, BASE, src[0..16], 16, .ext2) != 16) {
        fail("short accept");
        return;
    }
    if (writeback.readBuffered(FILE_IDX, BASE, &out, out.len, .ext2) != out.len) {
        fail("tail dropped");
        return;
    }

    arch.serial.writeString("[SK-152] writeback multi-page write non-x86: OK\n");
}
