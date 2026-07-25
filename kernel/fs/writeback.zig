/// Writeback — delayed write coalescing (buffer cache).
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const serial = @import("../arch/arch.zig").serial;
const PAGE_SIZE: u64 = 4096;
const BUFFER_COUNT: u32 = 512;
const BM_WORDS: u32 = (BUFFER_COUNT + 63) / 64; // = 2
const DEFAULT_MAX_AGE_TICKS: u64 = 500;
const TIMER_CHECK_INTERVAL: u64 = 100;
pub const FsType = enum(u8) { none = 0, ext2 = 1, fat32 = 2 };
pub const DirtyBuffer = struct {
    file_idx: u32 = 0,
    byte_offset: u64 = 0,
    data: [PAGE_SIZE]u8 = @splat(0),
    data_len: u32 = 0,
    dirty: bool = false,
    dirty_time: u64 = 0,
    fs_type: FsType = .none,
    in_use: bool = false,
};
var dirty_buffers: [BUFFER_COUNT]DirtyBuffer = @splat(.{});
var in_use_bm: [BM_WORDS]u64 = @splat(0);
var dirty_bm: [BM_WORDS]u64 = @splat(0);
var wb_lock: IrqSpinlock = .{};
var wb_tick: u64 = 0;
var next_check: u64 = TIMER_CHECK_INTERVAL;

// v53.33: Global flush callbacks for eviction-time flushing (prevents data loss)
const FlushFn = *const fn (u32, u64, [*]const u8, u32) bool;
var flush_callbacks: [3]?FlushFn = @splat(null);

pub fn setFlushCallback(fs_type: FsType, callback: FlushFn) void {
    flush_callbacks[@intFromEnum(fs_type)] = callback;
}

inline fn bmSet(bm: *[BM_WORDS]u64, idx: u32) void {
    bm[idx >> 6] |= @as(u64, 1) << @intCast(idx & 63);
}
inline fn bmClr(bm: *[BM_WORDS]u64, idx: u32) void {
    bm[idx >> 6] &= ~(@as(u64, 1) << @intCast(idx & 63));
}

/// Buffer `len` bytes for delayed writeback, split across buffer-sized extents.
///
/// Returns the number of bytes accepted. A single buffer holds at most
/// PAGE_SIZE, so longer writes span several of them; callers that write more
/// than that (`copy_file_range`, `splice` pipe→file) used to have everything
/// past the first page dropped while still reporting a full write. A short
/// return means the buffer pool is exhausted and the caller must report a
/// short write rather than claim the whole length.
pub fn writeBuffered(file_idx: u32, byte_offset: u64, data: [*]const u8, len: u32, fs_type: FsType) u32 {
    var done: u32 = 0;
    while (done < len) {
        const chunk = @min(len - done, @as(u32, 4096));
        if (!writeExtentLocked(file_idx, byte_offset + done, data + done, chunk, fs_type)) break;
        done += chunk;
    }
    return done;
}

/// Stage one buffer-sized extent. Returns false when no buffer can be had.
fn writeExtentLocked(file_idx: u32, byte_offset: u64, data: [*]const u8, len: u32, fs_type: FsType) bool {
    const flags = wb_lock.acquire();
    defer wb_lock.release(flags);
    const b = findBufferLocked(file_idx, byte_offset, fs_type) orelse
        findOrAllocBufferLocked(file_idx, byte_offset, fs_type, flags) orelse
        return false;
    @memcpy(b.data[0..len], data[0..len]);
    // Only the first `len` bytes are replaced, so an extent that already held
    // more still owns that tail. Shrinking data_len here would drop it before
    // it ever reached the disk.
    if (len > b.data_len) b.data_len = len;
    b.dirty = true;
    b.dirty_time = wb_tick;
    const idx: u32 = @intCast((@intFromPtr(b) - @intFromPtr(&dirty_buffers)) / @sizeOf(DirtyBuffer));
    bmSet(&dirty_bm, idx);
    return true;
}
fn findBufferLocked(file_idx: u32, byte_offset: u64, fs_type: FsType) ?*DirtyBuffer {
    for (0..BM_WORDS) |w| {
        var bits = in_use_bm[w];
        while (bits != 0) {
            const bit = @ctz(bits);
            bits &= bits - 1;
            const i: u32 = @intCast(w * 64 + @as(u32, bit));
            if (dirty_buffers[i].fs_type == fs_type and dirty_buffers[i].file_idx == file_idx and dirty_buffers[i].byte_offset == byte_offset) return &dirty_buffers[i];
        }
    }
    return null;
}
fn findOrAllocBufferLocked(file_idx: u32, byte_offset: u64, fs_type: FsType, flags: u64) ?*DirtyBuffer {
    // Find free slot via inverted in_use bitmap
    for (0..BM_WORDS) |w| {
        const inv = ~in_use_bm[w];
        if (inv == 0) continue;
        const bit = @ctz(inv);
        const i: u32 = @intCast(w * 64 + @as(u32, bit));
        if (i >= BUFFER_COUNT) break;
        dirty_buffers[i] = .{ .in_use = true, .file_idx = file_idx, .byte_offset = byte_offset, .fs_type = fs_type };
        bmSet(&in_use_bm, i);
        return &dirty_buffers[i];
    }
    // Evict oldest dirty buffer — flush outside lock to prevent data loss + SMP stalls (v53.35)
    var oldest_idx: u32 = 0;
    var oldest_time: u64 = @as(u64, 1) << 63;
    for (0..BM_WORDS) |w| {
        var bits = dirty_bm[w];
        while (bits != 0) {
            const bit = @ctz(bits);
            bits &= bits - 1;
            const i: u32 = @intCast(w * 64 + @as(u32, bit));
            if (dirty_buffers[i].dirty_time < oldest_time) {
                oldest_time = dirty_buffers[i].dirty_time;
                oldest_idx = i;
            }
        }
    }
    // v53.35: Copy evict data to stack, release lock for I/O, check flush return.
    // Fixes W2 (ignored flush failure → data loss) + W3 (spinlock held during I/O).
    const evict = &dirty_buffers[oldest_idx];
    var evict_data: [PAGE_SIZE]u8 = undefined;
    @memcpy(evict_data[0..evict.data_len], evict.data[0..evict.data_len]);
    const evict_len = evict.data_len;
    const evict_offset = evict.byte_offset;
    const evict_file_idx = evict.file_idx;
    const evict_fs = evict.fs_type;
    evict.dirty = false;
    bmClr(&dirty_bm, oldest_idx);
    // Keep in_use during flush so readBuffered can still serve reads (W1 fix)
    wb_lock.release(flags);
    const flush_ok = if (flush_callbacks[@intFromEnum(evict_fs)]) |cb|
        cb(evict_file_idx, evict_offset, &evict_data, evict_len)
    else
        false; // v53.36: no callback = cannot flush = refuse eviction (W3 fix)
    _ = wb_lock.acquire();
    if (!flush_ok) {
        // Flush failed — restore dirty state, refuse allocation
        dirty_buffers[oldest_idx].dirty = true;
        bmSet(&dirty_bm, oldest_idx);
        return null;
    }
    if (dirty_buffers[oldest_idx].dirty) {
        // Buffer was re-dirtied during flush — refuse allocation
        return null;
    }
    dirty_buffers[oldest_idx] = .{ .in_use = true, .file_idx = file_idx, .byte_offset = byte_offset, .fs_type = fs_type };
    bmSet(&in_use_bm, oldest_idx);
    return &dirty_buffers[oldest_idx];
}
pub fn readBuffered(file_idx: u32, byte_offset: u64, buf: [*]u8, len: u32, fs_type: FsType) u32 {
    // v53.35: Return actual bytes copied (0 = miss) instead of bool.
    // Fixes W4: VFS was returning min(count,4096) regardless of data_len,
    // causing garbage data when write < 4096 bytes.
    const copy_len = @min(len, @as(u32, 4096));
    const flags = wb_lock.acquire();
    defer wb_lock.release(flags);
    for (0..BM_WORDS) |w| {
        var bits = in_use_bm[w];
        while (bits != 0) {
            const bit = @ctz(bits);
            bits &= bits - 1;
            const i: u32 = @intCast(w * 64 + @as(u32, bit));
            if (dirty_buffers[i].fs_type == fs_type and dirty_buffers[i].file_idx == file_idx and dirty_buffers[i].byte_offset == byte_offset) {
                const n = @min(copy_len, dirty_buffers[i].data_len);
                @memcpy(buf[0..n], dirty_buffers[i].data[0..n]);
                return n;
            }
        }
    }
    return 0;
}
/// Flush one file's dirty buffers. Returns false if any buffer could not be
/// written; those stay dirty, so the caller must not report success.
pub fn flushFile(file_idx: u32, fs_type: FsType, comptime write_fn: fn (u32, u64, [*]const u8, u32) bool) bool {
    var all_ok = true;
    const flags = wb_lock.acquire();
    defer wb_lock.release(flags);
    for (0..BM_WORDS) |w| {
        var bits = dirty_bm[w];
        while (bits != 0) {
            const bit = @ctz(bits);
            bits &= bits - 1;
            const i: u32 = @intCast(w * 64 + @as(u32, bit));
            if (dirty_buffers[i].fs_type == fs_type and dirty_buffers[i].file_idx == file_idx) {
                const b = &dirty_buffers[i];
                if (!b.dirty) continue; // v53.35: skip already-flushed (stale snapshot)
                var tmp_data: [PAGE_SIZE]u8 = undefined;
                @memcpy(tmp_data[0..b.data_len], b.data[0..b.data_len]);
                const tmp_len = b.data_len;
                const tmp_offset = b.byte_offset;
                const tmp_file_idx = b.file_idx;
                b.dirty = false;
                dirty_bm[w] &= ~(@as(u64, 1) << @intCast(bit));
                // v53.35: keep in_use during flush for read-after-write consistency (W1)
                wb_lock.release(flags);
                const write_ok = write_fn(tmp_file_idx, tmp_offset, &tmp_data, tmp_len);
                _ = wb_lock.acquire();
                if (!write_ok) { // v53.36: restore dirty on flush failure (W2 fix)
                    b.dirty = true;
                    dirty_bm[w] |= (@as(u64, 1) << @intCast(bit));
                    all_ok = false;
                    continue;
                }
                if (!b.dirty) {
                    b.in_use = false;
                    bmClr(&in_use_bm, i);
                }
            }
        }
    }
    return all_ok;
}
/// Flush every dirty buffer of one filesystem. Returns false if any failed.
pub fn flushAllByType(fs_type: FsType, comptime write_fn: fn (u32, u64, [*]const u8, u32) bool) bool {
    // v53.35: Rename flushAll → flushAllByType + add fs_type filter (C1 fix).
    // Previously dirty_bm[w] = 0 cleared ALL dirty bits (including other fs_type),
    // causing fat32 data loss when syncAll called flushAll(ext2WriteFlush) first.
    var all_ok = true;
    const flags = wb_lock.acquire();
    for (0..BM_WORDS) |w| {
        var bits = dirty_bm[w];
        while (bits != 0) {
            const bit = @ctz(bits);
            bits &= bits - 1;
            const i: u32 = @intCast(w * 64 + @as(u32, bit));
            if (dirty_buffers[i].fs_type != fs_type) continue;
            const b = &dirty_buffers[i];
            if (!b.dirty) continue; // v53.35: skip already-flushed (stale snapshot)
            var tmp_data: [PAGE_SIZE]u8 = undefined;
            @memcpy(tmp_data[0..b.data_len], b.data[0..b.data_len]);
            const tmp_len = b.data_len;
            const tmp_offset = b.byte_offset;
            const tmp_file_idx = b.file_idx;
            b.dirty = false;
            dirty_bm[w] &= ~(@as(u64, 1) << @intCast(bit));
            // v53.35: keep in_use during flush for read-after-write consistency (W1)
            wb_lock.release(flags);
            const write_ok = write_fn(tmp_file_idx, tmp_offset, &tmp_data, tmp_len);
            _ = wb_lock.acquire();
            if (!write_ok) { // v53.36: restore dirty on flush failure (W2 fix)
                b.dirty = true;
                dirty_bm[w] |= (@as(u64, 1) << @intCast(bit));
                all_ok = false;
                continue;
            }
            if (!b.dirty) {
                b.in_use = false;
                bmClr(&in_use_bm, i);
            }
        }
    }
    wb_lock.release(flags);
    return all_ok;
}
/// Drop a file's buffers after flushing. Returns false if the flush failed, in
/// which case the buffers are discarded anyway — the caller is closing the file
/// and has nowhere left to retry, but it can still report the loss.
pub fn invalidateFile(file_idx: u32, fs_type: FsType, comptime write_fn: fn (u32, u64, [*]const u8, u32) bool) bool {
    const flush_ok = flushFile(file_idx, fs_type, write_fn);
    const flags = wb_lock.acquire();
    defer wb_lock.release(flags);
    for (0..BM_WORDS) |w| {
        var bits = in_use_bm[w];
        while (bits != 0) {
            const bit = @ctz(bits);
            bits &= bits - 1;
            const i: u32 = @intCast(w * 64 + @as(u32, bit));
            if (dirty_buffers[i].fs_type == fs_type and dirty_buffers[i].file_idx == file_idx) {
                dirty_buffers[i] = .{};
                in_use_bm[w] &= ~(@as(u64, 1) << @intCast(bit));
                bmClr(&dirty_bm, i);
            }
        }
    }
    return flush_ok;
}
pub fn writebackTimerTick() bool {
    wb_tick += 1;
    next_check -|= 1;
    if (next_check == 0) {
        next_check = TIMER_CHECK_INTERVAL;
        return hasExpiredBuffers(DEFAULT_MAX_AGE_TICKS);
    }
    return false;
}
fn hasExpiredBuffers(max_age_ticks: u64) bool {
    const flags = wb_lock.acquire();
    defer wb_lock.release(flags);
    for (0..BM_WORDS) |w| {
        var bits = dirty_bm[w];
        while (bits != 0) {
            const bit = @ctz(bits);
            bits &= bits - 1;
            const i: u32 = @intCast(w * 64 + @as(u32, bit));
            if (wb_tick - dirty_buffers[i].dirty_time >= max_age_ticks) return true;
        }
    }
    return false;
}
pub fn flushExpiredByFs(fs_type: FsType, comptime write_fn: fn (u32, u64, [*]const u8, u32) bool) void {
    const flags = wb_lock.acquire();
    for (0..BM_WORDS) |w| {
        var bits = dirty_bm[w];
        while (bits != 0) {
            const bit = @ctz(bits);
            bits &= bits - 1;
            const i: u32 = @intCast(w * 64 + @as(u32, bit));
            if (dirty_buffers[i].fs_type == fs_type and wb_tick - dirty_buffers[i].dirty_time >= DEFAULT_MAX_AGE_TICKS) {
                const b = &dirty_buffers[i];
                if (!b.dirty) continue; // v53.35: skip already-flushed (stale snapshot)
                var tmp_data: [PAGE_SIZE]u8 = undefined;
                @memcpy(tmp_data[0..b.data_len], b.data[0..b.data_len]);
                const tmp_len = b.data_len;
                const tmp_offset = b.byte_offset;
                const tmp_file_idx = b.file_idx;
                b.dirty = false;
                dirty_bm[w] &= ~(@as(u64, 1) << @intCast(bit));
                // v53.35: keep in_use during flush for read-after-write consistency (W1)
                wb_lock.release(flags);
                const write_ok = write_fn(tmp_file_idx, tmp_offset, &tmp_data, tmp_len);
                _ = wb_lock.acquire();
                if (!write_ok) { // v53.36: restore dirty on flush failure (W2 fix)
                    b.dirty = true;
                    dirty_bm[w] |= (@as(u64, 1) << @intCast(bit));
                    continue;
                }
                if (!b.dirty) {
                    b.in_use = false;
                    bmClr(&in_use_bm, i);
                }
            }
        }
    }
    wb_lock.release(flags);
}
pub fn getTick() u64 {
    return wb_tick;
}
pub fn getDirtyCount() u32 {
    var count: u32 = 0;
    for (0..BM_WORDS) |w| {
        count += @popCount(dirty_bm[w]);
    }
    return count;
}
