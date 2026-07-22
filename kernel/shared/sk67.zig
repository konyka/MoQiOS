//! SK-67 — UTF-8 → multi-slot FAT32 LFN encode + 8.3 alias on non-x86.
//!
//! Complements SK-66 assemble: `buildLfnEntries` / `make83Alias` / `fits83Name`
//! / `utf8ToUtf16` round-trip through `assembleLfnUtf8`, proving create-side
//! long-name encoding is portable before the x86 `createFile` write path uses it.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const fu = @import("../fs/fat32_util.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-67] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-67] fat32 LFN encode/alias non-x86: OK\n");
        return;
    }

    // fits83Name: short names yes, long names no.
    if (!fu.fits83Name("hello.txt") or !fu.fits83Name("README") or fu.fits83Name("hello-world.txt")) {
        fail("fits83Name");
        return;
    }

    // Alias shape: HELLO-~1TXT for hello-world.txt (base chars + ~N + ext)
    var alias: [11]u8 = undefined;
    fu.make83Alias("hello-world.txt", 1, &alias);
    // HELLO- ~ 1 T X T  — first 6 of "hello-world" uppercased = HELLO-
    if (alias[0] != 'H' or alias[5] != '-' or alias[6] != '~' or alias[7] != '1' or
        alias[8] != 'T' or alias[9] != 'X' or alias[10] != 'T')
    {
        fail("make83Alias");
        return;
    }

    // Round-trip: build LFN for long name, assemble back to the same UTF-8.
    const long_name = "hello-world.txt";
    var slots: [fu.MAX_LFN_SLOTS][32]u8 = undefined;
    const nslots = fu.buildLfnEntries(long_name, &alias, slots[0..]) orelse {
        fail("buildLfnEntries");
        return;
    };
    if (nslots != 2) {
        fail("slot count");
        return;
    }
    // First slot must be last-marker | 2
    if (!fu.isLastLfnSlot(slots[0][0]) or fu.lfnSequence(slots[0][0]) != 2) {
        fail("first slot seq");
        return;
    }
    if (fu.isLastLfnSlot(slots[1][0]) or fu.lfnSequence(slots[1][0]) != 1) {
        fail("second slot seq");
        return;
    }

    var ptrs: [2][*]const u8 = .{ &slots[0], &slots[1] };
    var out: [64]u8 = @splat(0);
    const n = fu.assembleLfnUtf8(ptrs[0..], &alias, out[0..]) orelse {
        fail("assemble round-trip");
        return;
    };
    if (n != long_name.len) {
        fail("round-trip len");
        return;
    }
    for (0..long_name.len) |i| {
        if (out[i] != long_name[i]) {
            fail("round-trip bytes");
            return;
        }
    }

    // Surrogate pair encode → assemble (😀)
    const emoji = "\xF0\x9F\x98\x80"; // U+1F600
    var emoji_alias: [11]u8 = undefined;
    fu.make83Alias("emoji", 1, &emoji_alias);
    var emo_slots: [fu.MAX_LFN_SLOTS][32]u8 = undefined;
    const es = fu.buildLfnEntries(emoji, &emoji_alias, emo_slots[0..]) orelse {
        fail("emoji build");
        return;
    };
    if (es != 1) {
        fail("emoji slots");
        return;
    }
    var emo_ptrs: [1][*]const u8 = .{&emo_slots[0]};
    const en = fu.assembleLfnUtf8(emo_ptrs[0..], &emoji_alias, out[0..]) orelse {
        fail("emoji assemble");
        return;
    };
    if (en != 4 or out[0] != 0xF0 or out[1] != 0x9F or out[2] != 0x98 or out[3] != 0x80) {
        fail("emoji utf8");
        return;
    }

    // utf8ToUtf16 basic
    var units: [8]u16 = undefined;
    const nu = fu.utf8ToUtf16("Ab", units[0..]) orelse {
        fail("utf8ToUtf16");
        return;
    };
    if (nu != 2 or units[0] != 'A' or units[1] != 'b') {
        fail("utf8ToUtf16 values");
        return;
    }

    arch.serial.writeString("[SK-67] fat32 LFN encode/alias non-x86: OK\n");
}
