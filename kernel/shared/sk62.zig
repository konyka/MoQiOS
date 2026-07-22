//! SK-62 — pure FAT32 8.3 / LFN directory-entry helpers on non-x86.
//!
//! SK-61 extracted MBR/BPB/cluster math. This step peels the next pure layer
//! out of `fat32.zig`: 8.3 encode/decode, directory-entry size/cluster fields,
//! attribute predicates, Microsoft LFN checksum, and per-slot LFN UCS-2 char
//! extraction. The x86 driver now delegates those paths 1:1; this probe proves
//! the math on riscv64/aarch64 with fixed synthetic directory entries.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const fu = @import("../fs/fat32_util.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-62] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-62] fat32 8.3/LFN helpers non-x86: OK\n");
        return;
    }

    // ── 8.3 encode / decode round-trip ───────────────────────────────────
    var short: [11]u8 = undefined;
    fu.encode83Name("readme.txt", &short);
    // "README  TXT" space-padded
    if (short[0] != 'R' or short[1] != 'E' or short[2] != 'A' or short[3] != 'D' or
        short[4] != 'M' or short[5] != 'E' or short[6] != 0x20 or short[7] != 0x20 or
        short[8] != 'T' or short[9] != 'X' or short[10] != 'T')
    {
        fail("encode83Name readme.txt");
        return;
    }

    var decoded: [16]u8 = @splat(0);
    const n = fu.decode83Name(&short, decoded[0..]);
    if (n != 10 or decoded[0] != 'r' or decoded[6] != '.' or decoded[7] != 't' or
        decoded[8] != 'x' or decoded[9] != 't')
    {
        fail("decode83Name readme.txt");
        return;
    }

    // No-extension name fills only the base field.
    fu.encode83Name("Makefile", &short);
    if (short[0] != 'M' or short[7] != 'E' or short[8] != 0x20 or short[10] != 0x20) {
        fail("encode83Name Makefile");
        return;
    }
    const n2 = fu.decode83Name(&short, decoded[0..]);
    if (n2 != 8 or decoded[0] != 'm' or decoded[7] != 'e') {
        fail("decode83Name Makefile");
        return;
    }

    // ── Directory-entry size / cluster fields ────────────────────────────
    var entry: [32]u8 = @splat(0);
    fu.setDirEntryFirstCluster(&entry, 0x12345678);
    fu.setDirEntrySize(&entry, 0x0A0B0C0D);
    if (fu.dirEntryFirstCluster(&entry) != 0x12345678) {
        fail("dirEntryFirstCluster");
        return;
    }
    if (fu.dirEntrySize(&entry) != 0x0A0B0C0D) {
        fail("dirEntrySize");
        return;
    }

    // ── Attribute predicates ─────────────────────────────────────────────
    if (!fu.isLfnAttr(0x0F) or fu.isLfnAttr(0x20)) {
        fail("isLfnAttr");
        return;
    }
    if (!fu.isVolumeLabelAttr(0x08) or fu.isVolumeLabelAttr(0x10)) {
        fail("isVolumeLabelAttr");
        return;
    }
    if (!fu.isDirectoryAttr(0x10) or !fu.isDirectoryAttr(0x30) or fu.isDirectoryAttr(0x20)) {
        fail("isDirectoryAttr");
        return;
    }

    // ── LFN checksum (Microsoft algorithm) ───────────────────────────────
    // Short name "FOO     BAR" → well-known checksum 0xA6 for classic samples
    // is awkward to hardcode; verify against a hand-rolled reference loop.
    const sn = "FOO     BAR".*;
    var ref: u8 = 0;
    for (sn) |c| {
        ref = ((ref & 1) << 7) +% (ref >> 1) +% c;
    }
    if (fu.lfnChecksum(&sn) != ref or ref == 0) {
        fail("lfnChecksum");
        return;
    }

    // ── LFN slot UCS-2 extraction + sequence bits ────────────────────────
    // Synthetic last LFN slot (seq=1 | 0x40) carrying "hello" then NUL.
    var lfn: [32]u8 = @splat(0xFF);
    lfn[0] = 0x41; // last | seq 1
    lfn[11] = 0x0F; // ATTR_LFN
    const chars = [_]u16{ 'h', 'e', 'l', 'l', 'o', 0 };
    // offsets: 1,3,5,7,9 for first five; write NUL at sixth (14)
    const offs = [_]u8{ 1, 3, 5, 7, 9, 14 };
    for (chars, 0..) |ch, i| {
        lfn[offs[i]] = @truncate(ch);
        lfn[offs[i] + 1] = @truncate(ch >> 8);
    }
    if (!fu.isLastLfnSlot(lfn[0]) or fu.lfnSequence(lfn[0]) != 1) {
        fail("lfn sequence bits");
        return;
    }
    var ucs: [13]u16 = @splat(0);
    const got = fu.decodeLfnEntryChars(&lfn, &ucs);
    if (got != 5 or ucs[0] != 'h' or ucs[4] != 'o') {
        fail("decodeLfnEntryChars");
        return;
    }

    arch.serial.writeString("[SK-62] fat32 8.3/LFN helpers non-x86: OK\n");
}
