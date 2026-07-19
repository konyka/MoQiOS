/// Sequential readahead — detects sequential access patterns and prefetches
/// blocks ahead of the current read position.
const builtin = @import("builtin");
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const PAGE_SIZE: u64 = 4096;
/// SK-37: non-x86 bring-up never streams file reads through vfs, but the
/// per-fd cache array dominates Task size (64 fds x 64 tasks). Keep the
/// window minimal there so the static task table stays small.
const MAX_WINDOW: u32 = if (builtin.cpu.arch == .x86_64) 32 else MIN_WINDOW;
const MIN_WINDOW: u32 = 2;
pub const CachedBlock = struct {
    block_num: u64 = 0,
    data: u64 = 0,
    valid: bool = false,
};
pub const ReadaheadState = struct {
    last_offset: u64 = 0,
    sequential_count: u32 = 0,
    window_size: u32 = MIN_WINDOW,
    prefetch_end: u64 = 0,
    cache: [MAX_WINDOW]CachedBlock = @splat(.{}),
    cache_count: u32 = 0,
    initialized: bool = false,
};
var ra_lock: IrqSpinlock = .{};
pub fn initState(state: *ReadaheadState) void {
    state.* = .{
        .last_offset = 0,
        .sequential_count = 0,
        .window_size = MIN_WINDOW,
        .prefetch_end = 0,
        .cache_count = 0,
        .initialized = true,
    };
}
pub fn invalidateCache(state: *ReadaheadState) void {
    const flags = ra_lock.acquire();
    defer ra_lock.release(flags);
    for (0..MAX_WINDOW) |i| {
        if (state.cache[i].valid) {
            if (state.cache[i].data != 0) pmm.freePage(state.cache[i].data);
            state.cache[i] = .{};
        }
    }
    state.cache_count = 0;
    state.initialized = false;
}
fn isSequential(state: *const ReadaheadState, offset: u64) bool {
    if (!state.initialized) return false;
    if (state.sequential_count == 0) return true;
    const diff: i64 = @as(i64, @bitCast(offset)) - @as(i64, @bitCast(state.last_offset));
    if (diff <= 0) return false;
    const diff_u64: u64 = @intCast(diff);
    return diff_u64 <= @as(u64, state.window_size) * PAGE_SIZE;
}
pub fn getCachedBlock(state: *ReadaheadState, block_num: u64) ?[*]u8 {
    const flags = ra_lock.acquire();
    defer ra_lock.release(flags);
    for (0..MAX_WINDOW) |i| {
        if (state.cache[i].valid and state.cache[i].block_num == block_num) {
            const virt: u64 = hhdm.physToVirt(state.cache[i].data);
            return @ptrFromInt(virt);
        }
    }
    return null;
}
fn insertCachedBlock(state: *ReadaheadState, block_num: u64, data: [*]const u8, block_size: u32) bool {
    for (0..MAX_WINDOW) |i| {
        if (!state.cache[i].valid) {
            const page = pmm.allocPage() orelse return false;
            const virt: u64 = hhdm.physToVirt(page);
            const dst: [*]u8 = @ptrFromInt(virt);
            const copy_len = @min(block_size, @as(u32, 4096));
            @memcpy(dst[0..copy_len], data[0..copy_len]);
            state.cache[i] = .{ .block_num = block_num, .data = page, .valid = true };
            state.cache_count += 1;
            return true;
        }
    }
    if (state.cache[0].valid and state.cache[0].data != 0) pmm.freePage(state.cache[0].data);
    var i: usize = 0;
    while (i < MAX_WINDOW - 1) : (i += 1) state.cache[i] = state.cache[i + 1];
    const page = pmm.allocPage() orelse return false;
    const virt: u64 = hhdm.physToVirt(page);
    const dst: [*]u8 = @ptrFromInt(virt);
    const copy_len = @min(block_size, @as(u32, 4096));
    @memcpy(dst[0..copy_len], data[0..copy_len]);
    state.cache[MAX_WINDOW - 1] = .{ .block_num = block_num, .data = page, .valid = true };
    return true;
}
pub const FsReadBlockFn = *const fn (u64, [*]u8) bool;
pub fn checkAndPrefetch(state: *ReadaheadState, current_offset: u64, block_size: u32, fs_read_fn: FsReadBlockFn) void {
    const flags = ra_lock.acquire();
    if (!state.initialized) { ra_lock.release(flags); return; }
    const current_block = current_offset / block_size;
    if (isSequential(state, current_offset)) {
        state.sequential_count += 1;
        if (state.sequential_count >= 2 and state.window_size < MAX_WINDOW) {
            state.window_size *|= 2;
            if (state.window_size > MAX_WINDOW) state.window_size = MAX_WINDOW;
        }
    } else {
        state.sequential_count = 0;
        state.window_size = MIN_WINDOW;
        state.prefetch_end = current_block;
    }
    state.last_offset = current_offset;
    const window_start = state.prefetch_end;
    const window_end = window_start + state.window_size;
    const half_window = window_start + state.window_size / 2;
    const need_prefetch = current_block >= half_window or (window_start == 0 and state.sequential_count == 1);
    if (!need_prefetch) { ra_lock.release(flags); return; }
    const new_start = window_end;
    const new_end = new_start + state.window_size;
    ra_lock.release(flags);
    var block_num = new_start;
    while (block_num < new_end) : (block_num += 1) {
        const tmp_phys = pmm.allocPage() orelse break;
        const tmp_virt: u64 = hhdm.physToVirt(tmp_phys);
        const tmp: [*]u8 = @ptrFromInt(tmp_virt);
        const ok = fs_read_fn(block_num, tmp);
        if (!ok) { pmm.freePage(tmp_phys); break; }
        const lock2 = ra_lock.acquire();
        const inserted = insertCachedBlock(state, block_num, tmp, block_size);
        ra_lock.release(lock2);
        pmm.freePage(tmp_phys);
        if (!inserted) break;
    }
    const lock3 = ra_lock.acquire();
    state.prefetch_end = new_end;
    ra_lock.release(lock3);
}
pub fn copyFromCache(state: *ReadaheadState, block_num: u64, block_offset: u32, buf: [*]u8, count: u32) u32 {
    const cached = getCachedBlock(state, block_num) orelse return 0;
    const to_copy = @min(count, 4096 - block_offset);
    @memcpy(buf[0..to_copy], cached[block_offset .. block_offset + to_copy]);
    return to_copy;
}
