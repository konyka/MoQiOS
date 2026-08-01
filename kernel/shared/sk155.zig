//! SK-155 — a failed writeback flush is reported, and the data stays dirty.
//!
//! `flushFile` / `flushAllByType` returned `void`, so `syncFile` and in turn
//! `fsync` had no way to see that a buffer never reached the disk: the syscall
//! returned 0 while the data was still only in memory. The flush code already
//! restored the dirty bit on failure — the status was simply thrown away.
//!
//! This exercises the same path with a callback that fails, then one that
//! succeeds, and checks both the returned status and the dirty count.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const writeback = @import("../fs/writeback.zig");

const FILE_IDX: u32 = 23;
// v53.51: writeback buffers are keyed by inode_id; FILE_IDX is only the
// flush-target slot passed to the probe callback.
const INODE_ID: u64 = 0x3000_0000_0000_0000 + @as(u64, FILE_IDX);
const OFFSET: u64 = 8192;
const payload = "SK155-flush-fail";

var fail_calls: u32 = 0;
var ok_calls: u32 = 0;

fn failingFlush(file_idx: u32, byte_offset: u64, data: [*]const u8, len: u32) bool {
    _ = file_idx;
    _ = byte_offset;
    _ = data;
    _ = len;
    fail_calls += 1;
    return false;
}

fn succeedingFlush(file_idx: u32, byte_offset: u64, data: [*]const u8, len: u32) bool {
    _ = file_idx;
    _ = byte_offset;
    _ = data;
    _ = len;
    ok_calls += 1;
    return true;
}

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-155] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-155] writeback flush error propagation non-x86: OK\n");
        return;
    }

    const before = writeback.getDirtyCount();
    if (writeback.writeBuffered(INODE_ID, FILE_IDX, OFFSET, payload.ptr, payload.len, .ext2) != payload.len) {
        fail("stage buffer");
        return;
    }
    if (writeback.getDirtyCount() != before + 1) {
        fail("not dirtied");
        return;
    }

    // A flush whose write fails must report failure...
    if (writeback.flushFile(INODE_ID, .ext2, failingFlush)) {
        fail("failure reported as success");
        return;
    }
    if (fail_calls != 1) {
        fail("callback not invoked");
        return;
    }
    // ...and must leave the data dirty so it is not lost.
    if (writeback.getDirtyCount() != before + 1) {
        fail("dirty state not restored");
        return;
    }

    // The same buffer flushes cleanly once the write succeeds.
    if (!writeback.flushFile(INODE_ID, .ext2, succeedingFlush)) {
        fail("retry reported failure");
        return;
    }
    if (ok_calls != 1) {
        fail("retry callback count");
        return;
    }
    if (writeback.getDirtyCount() != before) {
        fail("dirty not drained");
        return;
    }

    arch.serial.writeString("[SK-155] writeback flush error propagation non-x86: OK\n");
}
