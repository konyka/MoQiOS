//! SK-66 — multi-slot FAT32 LFN → UTF-8 assembly on non-x86.
//!
//! SK-62 extracted per-slot LFN helpers. This step assembles a forward-scan
//! chain of LFN directory entries into a UTF-8 name, verifies the Microsoft
//! checksum against the short entry, and handles BMP + surrogate pairs. The
//! x86 `listRootDir` path now prefers the assembled name when a valid chain
//! precedes a short entry.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const fu = @import("../fs/fat32_util.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-66] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

fn writeU16(buf: []u8, off: usize, v: u16) void {
    buf[off] = @truncate(v);
    buf[off + 1] = @truncate(v >> 8);
}

/// Build one 32-byte LFN slot: seq (with optional last bit), checksum, chars.
fn fillLfnSlot(out: *[32]u8, seq: u8, last: bool, checksum: u8, chars: []const u16) void {
    @memset(out, 0xFF);
    out[0] = if (last) seq | 0x40 else seq;
    out[11] = fu.ATTR_LFN;
    out[12] = 0;
    out[13] = checksum;
    out[26] = 0;
    out[27] = 0;
    const offsets = [_]u8{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
    var i: usize = 0;
    while (i < 13) : (i += 1) {
        const ch: u16 = if (i < chars.len) chars[i] else if (i == chars.len) 0 else 0xFFFF;
        writeU16(out, offsets[i], ch);
    }
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-66] fat32 LFN assemble UTF-8 non-x86: OK\n");
        return;
    }

    // Short name "HELLO   TXT" for hello.txt
    var short: [11]u8 = undefined;
    fu.encode83Name("hello.txt", &short);
    const sum = fu.lfnChecksum(&short);

    // Two-slot name: "hello-world.txt" (15 chars → needs 2 slots)
    // Slot 2 (last): "d.txt" + NUL  ; Slot 1: "hello-world.tx" wait
    // Full: h e l l o - w o r l d . t x t = 15 units
    // Slot1 (seq1): first 13 chars "hello-world.t"
    // Slot2 (last|2): remaining "xt" + NUL
    const name_units = [_]u16{ 'h', 'e', 'l', 'l', 'o', '-', 'w', 'o', 'r', 'l', 'd', '.', 't', 'x', 't' };
    var slot2: [32]u8 = undefined;
    var slot1: [32]u8 = undefined;
    fillLfnSlot(&slot2, 2, true, sum, name_units[13..]);
    fillLfnSlot(&slot1, 1, false, sum, name_units[0..13]);

    const entries = [_][*]const u8{ &slot2, &slot1 };
    var out: [64]u8 = @splat(0);
    const n = fu.assembleLfnUtf8(&entries, &short, out[0..]) orelse {
        fail("assemble two-slot");
        return;
    };
    const expect = "hello-world.txt";
    if (n != expect.len) {
        fail("length");
        return;
    }
    for (0..expect.len) |i| {
        if (out[i] != expect[i]) {
            fail("bytes");
            return;
        }
    }

    // Single-slot ASCII
    var slot_hi: [32]u8 = undefined;
    fillLfnSlot(&slot_hi, 1, true, sum, &[_]u16{ 'h', 'e', 'l', 'l', 'o', '.', 't', 'x', 't' });
    const one = [_][*]const u8{&slot_hi};
    const n1 = fu.assembleLfnUtf8(&one, &short, out[0..]) orelse {
        fail("assemble one-slot");
        return;
    };
    if (n1 != 9 or out[0] != 'h' or out[8] != 't') {
        fail("one-slot bytes");
        return;
    }

    // Bad checksum rejected
    var bad = slot_hi;
    bad[13] = sum +% 1;
    const bad_e = [_][*]const u8{&bad};
    if (fu.assembleLfnUtf8(&bad_e, &short, out[0..]) != null) {
        fail("bad checksum accepted");
        return;
    }

    // First entry must carry last-slot marker
    var not_last = slot1;
    // slot1 is seq=1 without 0x40 — use it alone
    const nl = [_][*]const u8{&not_last};
    if (fu.assembleLfnUtf8(&nl, &short, out[0..]) != null) {
        fail("missing last marker accepted");
        return;
    }

    // Surrogate pair: U+1F600 😀 → UTF-8 F0 9F 98 80
    // Encode as UTF-16: D83D DE00
    var short2: [11]u8 = undefined;
    fu.encode83Name("emoji", &short2);
    const sum2 = fu.lfnChecksum(&short2);
    var emo: [32]u8 = undefined;
    fillLfnSlot(&emo, 1, true, sum2, &[_]u16{ 0xD83D, 0xDE00 });
    const emo_e = [_][*]const u8{&emo};
    const ne = fu.assembleLfnUtf8(&emo_e, &short2, out[0..]) orelse {
        fail("surrogate assemble");
        return;
    };
    if (ne != 4 or out[0] != 0xF0 or out[1] != 0x9F or out[2] != 0x98 or out[3] != 0x80) {
        fail("surrogate utf8");
        return;
    }

    arch.serial.writeString("[SK-66] fat32 LFN assemble UTF-8 non-x86: OK\n");
}
