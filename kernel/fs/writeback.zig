/// Writeback — delayed write coalescing (buffer cache).
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const serial = @import("../arch/x86_64/serial.zig");
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

inline fn bmSet(bm: *[BM_WORDS]u64, idx: u32) void {
    bm[idx >> 6] |= @as(u64, 1) << @intCast(idx & 63);
}
inline fn bmClr(bm: *[BM_WORDS]u64, idx: u32) void {
    bm[idx >> 6] &= ~(@as(u64, 1) << @intCast(idx & 63));
}

pub fn writeBuffered(file_idx: u32, byte_offset: u64, data: [*]const u8, len: u32, fs_type: FsType) void {
    const copy_len = @min(len, @as(u32, 4096));
    const flags = wb_lock.acquire();
    defer wb_lock.release(flags);
    var buf = findBufferLocked(file_idx, byte_offset, fs_type);
    if (buf) |b| {
        @memcpy(b.data[0..copy_len], data[0..copy_len]);
        b.data_len = copy_len;
        b.dirty = true;
        b.dirty_time = wb_tick;
        const idx: u32 = @intCast((@intFromPtr(b) - @intFromPtr(&dirty_buffers)) / @sizeOf(DirtyBuffer));
        bmSet(&dirty_bm, idx);
        return;
    }
    buf = findOrAllocBufferLocked(file_idx, byte_offset, fs_type);
    if (buf) |b| {
        @memcpy(b.data[0..copy_len], data[0..copy_len]);
        b.data_len = copy_len;
        b.dirty = true;
        b.dirty_time = wb_tick;
        const idx: u32 = @intCast((@intFromPtr(b) - @intFromPtr(&dirty_buffers)) / @sizeOf(DirtyBuffer));
        bmSet(&dirty_bm, idx);
    }
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
fn findOrAllocBufferLocked(file_idx: u32, byte_offset: u64, fs_type: FsType) ?*DirtyBuffer {
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
    // Evict oldest dirty buffer
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
    bmClr(&dirty_bm, oldest_idx);
    dirty_buffers[oldest_idx] = .{ .in_use = true, .file_idx = file_idx, .byte_offset = byte_offset, .fs_type = fs_type };
    bmSet(&in_use_bm, oldest_idx);
    return &dirty_buffers[oldest_idx];
}
pub fn readBuffered(file_idx: u32, byte_offset: u64, buf: [*]u8, len: u32, fs_type: FsType) bool {
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
                return true;
            }
        }
    }
    return false;
}
pub fn flushFile(file_idx: u32, fs_type: FsType, comptime write_fn: fn (u32, u64, [*]const u8, u32) bool) void {
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
                var tmp_data: [PAGE_SIZE]u8 = undefined;
                @memcpy(tmp_data[0..b.data_len], b.data[0..b.data_len]);
                const tmp_len = b.data_len;
                const tmp_offset = b.byte_offset;
                const tmp_file_idx = b.file_idx;
                b.dirty = false;
                dirty_bm[w] &= ~(@as(u64, 1) << @intCast(bit));
                wb_lock.release(flags);
                _ = write_fn(tmp_file_idx, tmp_offset, &tmp_data, tmp_len);
                _ = wb_lock.acquire();
            }
        }
    }
}
pub fn flushAll(comptime write_fn: fn (u32, u64, [*]const u8, u32) bool) void {
    const flags = wb_lock.acquire();
    for (0..BM_WORDS) |w| {
        var bits = dirty_bm[w];
        dirty_bm[w] = 0;
        while (bits != 0) {
            const bit = @ctz(bits);
            bits &= bits - 1;
            const i: u32 = @intCast(w * 64 + @as(u32, bit));
            const b = &dirty_buffers[i];
            var tmp_data: [PAGE_SIZE]u8 = undefined;
            @memcpy(tmp_data[0..b.data_len], b.data[0..b.data_len]);
            const tmp_len = b.data_len;
            const tmp_offset = b.byte_offset;
            const tmp_file_idx = b.file_idx;
            b.dirty = false;
            wb_lock.release(flags);
            _ = write_fn(tmp_file_idx, tmp_offset, &tmp_data, tmp_len);
            _ = wb_lock.acquire();
        }
    }
    wb_lock.release(flags);
}
pub fn invalidateFile(file_idx: u32, fs_type: FsType, comptime write_fn: fn (u32, u64, [*]const u8, u32) bool) void {
    flushFile(file_idx, fs_type, write_fn);
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
                var tmp_data: [PAGE_SIZE]u8 = undefined;
                @memcpy(tmp_data[0..b.data_len], b.data[0..b.data_len]);
                const tmp_len = b.data_len;
                const tmp_offset = b.byte_offset;
                const tmp_file_idx = b.file_idx;
                b.dirty = false;
                dirty_bm[w] &= ~(@as(u64, 1) << @intCast(bit));
                wb_lock.release(flags);
                _ = write_fn(tmp_file_idx, tmp_offset, &tmp_data, tmp_len);
                _ = wb_lock.acquire();
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
