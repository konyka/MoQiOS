//! SK-154 — ext2 directory records are validated against their block (non-x86).
//!
//! The five directory walkers all cast `buf + pos` to an 8-byte header while
//! only knowing `pos < block_size`, then copied `name_len` bytes after it and
//! advanced by an unchecked `rec_len`. A corrupt or hostile image could read up
//! to 7 bytes past the block for the header, up to 255 for the name, land the
//! cast on an unaligned address, and (in `addDirEntry`) underflow the
//! `rec_len - actual_len` gap into an out-of-bounds write.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const eu = @import("../fs/ext2_util.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-154] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

const BS: u32 = 64; // pretend block size, keeps the fixtures readable

/// Two well-formed records: "." (rec_len 12) then ".." filling the rest.
fn goodBlock() [BS]u8 {
    var b: [BS]u8 = @splat(0);
    // inode 2, rec_len 12, name_len 1, type 2, "."
    b[0] = 2;
    b[4] = 12;
    b[6] = 1;
    b[7] = 2;
    b[8] = '.';
    // inode 2, rec_len 52, name_len 2, type 2, ".."
    b[12] = 2;
    b[16] = 52;
    b[18] = 2;
    b[19] = 2;
    b[20] = '.';
    b[21] = '.';
    // Padding inside the second record, arranged so that a *misaligned* read at
    // pos 26 would decode as a plausible record (inode 5, rec_len 12,
    // name_len 3). Without the alignment check that read is accepted, so this
    // is what makes the check observable rather than incidentally redundant.
    b[26] = 5;
    b[30] = 12;
    b[32] = 3;
    return b;
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-154] ext2 dir record validation non-x86: OK\n");
        return;
    }

    var block = goodBlock();
    const buf: [*]const u8 = &block;

    // A well-formed block must parse, and walking it must land exactly on the end.
    const first = eu.readDirEntry(buf, 0, BS) orelse {
        fail("good first");
        return;
    };
    if (first.inode != 2 or first.rec_len != 12 or first.name_len != 1 or first.name_pos != 8) {
        fail("good first fields");
        return;
    }
    const second = eu.readDirEntry(buf, 12, BS) orelse {
        fail("good second");
        return;
    };
    if (second.rec_len != 52 or second.name_pos != 20) {
        fail("good second fields");
        return;
    }
    if (12 + second.rec_len != BS) {
        fail("walk end");
        return;
    }

    // Header straddling the end of the block: only 4 of 8 bytes are inside.
    if (eu.readDirEntry(buf, BS - 4, BS) != null) {
        fail("short header");
        return;
    }
    if (eu.readDirEntry(buf, BS, BS) != null) {
        fail("header at end");
        return;
    }

    // Unaligned position — a previous record's rec_len was not a multiple of 4,
    // so the struct cast the callers do would be misaligned. The bytes at 26
    // decode as a plausible record, so only the alignment check rejects this.
    if (eu.readDirEntry(buf, 26, BS) != null) {
        fail("unaligned pos");
        return;
    }

    // rec_len 0 would make the walkers spin in place.
    block[16] = 0;
    if (eu.readDirEntry(buf, 12, BS) != null) {
        fail("rec_len 0");
        return;
    }

    // rec_len not a multiple of 4 leaves the next position unaligned.
    block[16] = 13;
    if (eu.readDirEntry(buf, 12, BS) != null) {
        fail("rec_len unaligned");
        return;
    }

    // rec_len too small for its own name: the name would spill into the record
    // that follows, and in addDirEntry the gap subtraction would wrap.
    block[16] = 12;
    block[18] = 200;
    if (eu.readDirEntry(buf, 12, BS) != null) {
        fail("name overruns rec_len");
        return;
    }

    // rec_len past the end of the block.
    block[16] = 56;
    block[18] = 2;
    if (eu.readDirEntry(buf, 12, BS) != null) {
        fail("rec_len past block");
        return;
    }

    // Exactly reaching the block end stays valid (the common last record).
    block[16] = 52;
    if (eu.readDirEntry(buf, 12, BS) == null) {
        fail("rec_len at block end");
        return;
    }

    // A name that exactly fills its record is accepted, and its bytes stay in
    // the block: name_pos + name_len must not pass block_size.
    block[16] = 52;
    block[18] = 44;
    const tight = eu.readDirEntry(buf, 12, BS) orelse {
        fail("tight name");
        return;
    };
    if (tight.name_pos + tight.name_len > BS) {
        fail("tight name bounds");
        return;
    }

    arch.serial.writeString("[SK-154] ext2 dir record validation non-x86: OK\n");
}
