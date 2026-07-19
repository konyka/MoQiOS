//! SK-46 — writeback boot fragment + shared buffer cache on non-x86.
//!
//! main.zig's v53.33 fragment (`vfs.initWritebackCallbacks`) now goes
//! through `subsystem_boot.initWritebackCallbacks` (x86 path — the ext2/
//! fat32 flush chain needs the x86 block drivers, so non-x86 must not pull
//! it in). The probe instead exercises the arch-clean writeback buffer
//! cache (`fs/writeback.zig`) directly: dirty-buffer round-trip, key
//! isolation by fs_type/offset, then flushFile with a probe-local callback
//! and a dirty-count drain check.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const writeback = @import("../fs/writeback.zig");

const FILE_IDX: u32 = 7;
const OFFSET: u64 = 4096;
const payload = "SK46-writeback!!";

var flushed_ok: bool = false;

fn probeFlush(file_idx: u32, byte_offset: u64, data: [*]const u8, len: u32) bool {
    if (file_idx != FILE_IDX or byte_offset != OFFSET or len != payload.len) return false;
    for (payload, 0..) |c, i| {
        if (data[i] != c) return false;
    }
    flushed_ok = true;
    return true;
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-46] shared writeback cache: OK\n");
        return;
    }

    // Dirty-buffer round-trip: write into the cache, read it back.
    writeback.writeBuffered(FILE_IDX, OFFSET, payload.ptr, payload.len, .ext2);
    var buf: [payload.len]u8 = undefined;
    const n = writeback.readBuffered(FILE_IDX, OFFSET, &buf, payload.len, .ext2);
    if (n != payload.len) {
        arch.serial.writeString("[SK-46] FAILED: readBuffered len\n");
        return;
    }
    for (payload, 0..) |c, i| {
        if (buf[i] != c) {
            arch.serial.writeString("[SK-46] FAILED: payload mismatch\n");
            return;
        }
    }
    // Wrong fs_type / offset must miss the cache.
    if (writeback.readBuffered(FILE_IDX, OFFSET, &buf, payload.len, .fat32) != 0) {
        arch.serial.writeString("[SK-46] FAILED: fs_type not keyed\n");
        return;
    }
    if (writeback.readBuffered(FILE_IDX, OFFSET + 4096, &buf, payload.len, .ext2) != 0) {
        arch.serial.writeString("[SK-46] FAILED: offset not keyed\n");
        return;
    }
    if (writeback.getDirtyCount() == 0) {
        arch.serial.writeString("[SK-46] FAILED: dirty count zero\n");
        return;
    }

    // Flush through the same comptime-callback path vfs.syncFile uses.
    writeback.flushFile(FILE_IDX, .ext2, probeFlush);
    if (!flushed_ok) {
        arch.serial.writeString("[SK-46] FAILED: flush callback\n");
        return;
    }
    if (writeback.getDirtyCount() != 0) {
        arch.serial.writeString("[SK-46] FAILED: dirty not drained\n");
        return;
    }

    arch.serial.writeString("[SK-46] shared writeback cache: OK\n");
}
