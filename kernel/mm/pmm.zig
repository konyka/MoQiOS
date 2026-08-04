/// Physical Memory Manager — bitmap allocator for 4KB page frames.
/// Limine memmap init (x86) or compact arena init (SK-5 shared path).
const builtin = @import("builtin");
const limine = @import("../limine.zig");
const hhdm = @import("hhdm.zig");
const serial = @import("../arch/arch.zig").serial;
const klog = @import("../klog.zig");
const page_frame = @import("page_frame.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const fmt = @import("../lib/fmt.zig");

const PAGE_SIZE: u64 = 4096;

// --- State ---
var bitmap: [*]u8 = undefined;
var bitmap_size: u64 = 0;
var total_pages: u64 = 0;
var free_pages: u64 = 0;
var highest_phys: u64 = 0;
var ref_counts: [*]u16 = undefined;
var lock: IrqSpinlock = .{};

// v53.12: Guard against recursive swap reclaim (reclaimPages → swapOut → allocPage)
var in_swap_reclaim: bool = false;

/// Skip first 2 MB (512 pages) on Limine boots — legacy BIOS area.
/// Arena mode (SK-5) sets this to 0.
var min_alloc_page: u64 = 512;

/// When true, page indices are relative to `arena_base` (compact shared PMM).
var arena_mode: bool = false;
var arena_base: u64 = 0;

// ─── L1: recorded RAM ranges (user driver framework MMIO validation) ───
/// Half-open physical ranges the boot memmap reported as RAM-like (usable,
/// kernel/modules, reclaimable). Used by `isRamPhys` to decide whether a
/// physical range may be handed to userspace as device MMIO.
pub const RamRange = struct { base: u64, len: u64 };
pub const MAX_RAM_RANGES: u32 = 48;
var ram_ranges: [MAX_RAM_RANGES]RamRange = undefined;
var ram_range_count: u32 = 0;

fn recordRamRange(base: u64, len: u64) void {
    if (len == 0 or ram_range_count >= MAX_RAM_RANGES) return;
    ram_ranges[ram_range_count] = .{ .base = base, .len = len };
    ram_range_count += 1;
}

/// The recorded boot-time RAM ranges (for the host-tested overlap logic in
/// drivers/userdrv_core.zig).
pub fn ramRanges() []const RamRange {
    return ram_ranges[0..ram_range_count];
}

/// L1: heuristic "is this physical address RAM" predicate.
///
/// True when the address lies in a recorded boot RAM range (covers free RAM,
/// allocated RAM, the kernel image and reclaimable regions) or names a
/// managed frame that is currently free/allocated in the bitmap. MMIO apertures
/// (PCI BARs, LAPIC/IOAPIC windows) are reserved memmap holes: never recorded
/// and never bitmap-managed, so they read as non-RAM.
///
/// Lock-free by design (called from teardown loops and syscall validation):
/// the answer is stable for MMIO holes, and a racing free/alloc of a RAM frame
/// can only ever flip the answer towards "RAM", which is the safe direction
/// for the map-MMIO rejection path. Limits: RAM the memmap did not report as
/// RAM-like (e.g. a framebuffer inside a "usable" entry) is treated as RAM —
/// such regions cannot be mapped with dev_map_mmio.
pub fn isRamPhys(phys: u64) bool {
    for (ram_ranges[0..ram_range_count]) |r| {
        if (phys >= r.base and phys - r.base < r.len) return true;
    }
    const page = pageFromPhys(phys);
    if (page < total_pages and (isBitSet(page) or ref_counts[page] > 0)) return true;
    return false;
}

fn physFromPage(page: u64) u64 {
    if (arena_mode) return arena_base + page * PAGE_SIZE;
    return page * PAGE_SIZE;
}

fn pageFromPhys(phys: u64) u64 {
    if (arena_mode) {
        if (phys < arena_base) return total_pages;
        return (phys - arena_base) / PAGE_SIZE;
    }
    return phys / PAGE_SIZE;
}

/// Return total number of physical pages.
pub fn totalPages() u64 {
    return total_pages;
}

/// Return number of free physical pages.
pub fn freePages() u64 {
    return free_pages;
}

var next_free_hint: u64 = 0;

// --- Public API ---

pub fn init(memmap: *const limine.MemmapResponse) void {
    arena_mode = false;
    arena_base = 0;
    min_alloc_page = 512;

    const entry_count = memmap.entry_count;
    const entries = memmap.entries;

    // Pass 1: find highest usable physical address
    highest_phys = 0;
    ram_range_count = 0;
    for (0..entry_count) |i| {
        const entry = entries[i];
        const top = entry.base + entry.length;
        switch (entry.kind) {
            .usable, .bootloader_reclaimable, .kernel_and_modules, .acpi_reclaimable => {
                if (top > highest_phys) highest_phys = top;
                // L1: remember every RAM-like range so dev_map_mmio can reject
                // user mappings of real memory (kernel image included).
                recordRamRange(entry.base, entry.length);
            },
            else => {},
        }
    }

    total_pages = highest_phys / PAGE_SIZE;
    bitmap_size = (total_pages + 7) / 8;

    const ref_counts_size = total_pages * 2;
    const page_frames_size = total_pages * @sizeOf(page_frame.PageFrame);
    // Account for alignment padding between ref_counts and page_frames (up to 3 bytes)
    const alignment_padding: u64 = 3;
    const metadata_size = ((bitmap_size + 7) & ~@as(u64, 7)) + ref_counts_size + alignment_padding + page_frames_size;

    // Pass 2: find a usable region large enough for bitmap + ref_counts
    var bitmap_phys: u64 = 0;
    var found = false;
    for (0..entry_count) |i| {
        const entry = entries[i];
        if (entry.kind == .usable and entry.length >= metadata_size) {
            bitmap_phys = entry.base;
            found = true;
            break;
        }
    }
    if (!found) {
        serial.writeString("[PMM] FATAL: no region large enough for bitmap\n");
        return;
    }

    // Map via HHDM
    bitmap = @ptrFromInt(hhdm.physToVirt(bitmap_phys));
    const ref_counts_phys = (bitmap_phys + bitmap_size + 7) & ~@as(u64, 7);
    ref_counts = @ptrFromInt(@as(usize, @truncate(hhdm.physToVirt(ref_counts_phys))));

    // Clear bitmap (all used = 0)
    @memset(bitmap[0..bitmap_size], 0);
    // Zero ref counts
    const rc_bytes: [*]u8 = @ptrCast(ref_counts);
    @memset(rc_bytes[0 .. total_pages * 2], 0);

    // Initialize page frame descriptor array (must be aligned to @alignOf(PageFrame))
    const page_frames_phys = (ref_counts_phys + ref_counts_size + 3) & ~@as(u64, 3);
    const page_frames_ptr: [*]page_frame.PageFrame = @ptrFromInt(@as(usize, @truncate(hhdm.physToVirt(page_frames_phys))));
    page_frame.init(total_pages, page_frames_ptr);

    // Pass 3: mark usable regions as free (1)
    free_pages = 0;
    for (0..entry_count) |i| {
        const entry = entries[i];
        if (entry.kind == .usable) {
            const start_page = entry.base / PAGE_SIZE;
            const page_count = entry.length / PAGE_SIZE;
            for (start_page..start_page + page_count) |p| {
                if (p >= total_pages) break;
                setBit(p);
                free_pages += 1;
            }
        }
    }

    // Mark metadata pages as used
    const metadata_pages = (metadata_size + PAGE_SIZE - 1) / PAGE_SIZE;
    const bitmap_start_page = bitmap_phys / PAGE_SIZE;
    for (bitmap_start_page..bitmap_start_page + metadata_pages) |p| {
        if (p < total_pages) {
            if (isBitSet(p)) {
                clearBit(p);
                if (free_pages > 0) free_pages -= 1;
            }
        }
    }

    // Mark kernel-and-modules pages as used (Limine reports these accurately)
    for (0..entry_count) |i| {
        const entry = entries[i];
        if (entry.kind == .kernel_and_modules) {
            const start_page = entry.base / PAGE_SIZE;
            const page_count = entry.length / PAGE_SIZE;
            for (start_page..start_page + page_count) |p| {
                if (p >= total_pages) break;
                if (isBitSet(p)) {
                    clearBit(p);
                    if (free_pages > 0) free_pages -= 1;
                }
            }
        }
    }

    next_free_hint = min_alloc_page;

    serial.writeString("[PMM] Total pages: ");
    fmt.writeDecimal64(total_pages);
    serial.writeString(", free: ");
    fmt.writeDecimal64(free_pages);
    serial.writeString("\n[PMM] bitmap_phys=0x");
    fmt.writeHex(bitmap_phys);
    serial.writeString(" metadata_pages=");
    fmt.writeDecimal64(metadata_pages);
    serial.writeString(" metadata_end=0x");
    fmt.writeHex(bitmap_phys + metadata_pages * PAGE_SIZE);
    serial.writeString("\n");

    klog.log(.info, "PMM initialized");
}

/// SK-5: compact PMM over a contiguous identity-mapped arena (no Limine).
/// Page indices are relative to `phys_base`; suitable for non-x86 shared-kernel smoke.
pub fn initArena(phys_base: u64, length: u64) void {
    arena_mode = true;
    arena_base = phys_base;
    min_alloc_page = 0;
    highest_phys = phys_base + length;
    ram_range_count = 0;
    recordRamRange(phys_base, length);

    total_pages = length / PAGE_SIZE;
    if (total_pages == 0) {
        serial.writeString("[PMM] FATAL: arena too small\n");
        return;
    }
    bitmap_size = (total_pages + 7) / 8;
    const ref_counts_size = total_pages * 2;
    const page_frames_size = total_pages * @sizeOf(page_frame.PageFrame);
    const alignment_padding: u64 = 3;
    const metadata_size = ((bitmap_size + 7) & ~@as(u64, 7)) + ref_counts_size + alignment_padding + page_frames_size;
    if (metadata_size + PAGE_SIZE > length) {
        serial.writeString("[PMM] FATAL: arena too small for metadata\n");
        return;
    }

    const bitmap_phys = phys_base;
    bitmap = @ptrFromInt(hhdm.physToVirt(bitmap_phys));
    const ref_counts_phys = (bitmap_phys + bitmap_size + 7) & ~@as(u64, 7);
    ref_counts = @ptrFromInt(@as(usize, @truncate(hhdm.physToVirt(ref_counts_phys))));

    @memset(bitmap[0..bitmap_size], 0);
    const rc_bytes: [*]u8 = @ptrCast(ref_counts);
    @memset(rc_bytes[0 .. total_pages * 2], 0);

    const page_frames_phys = (ref_counts_phys + ref_counts_size + 3) & ~@as(u64, 3);
    const page_frames_ptr: [*]page_frame.PageFrame = @ptrFromInt(@as(usize, @truncate(hhdm.physToVirt(page_frames_phys))));
    page_frame.init(total_pages, page_frames_ptr);

    free_pages = 0;
    var p: u64 = 0;
    while (p < total_pages) : (p += 1) {
        setBit(p);
        free_pages += 1;
    }

    const metadata_pages = (metadata_size + PAGE_SIZE - 1) / PAGE_SIZE;
    p = 0;
    while (p < metadata_pages) : (p += 1) {
        if (isBitSet(p)) {
            clearBit(p);
            if (free_pages > 0) free_pages -= 1;
        }
    }

    next_free_hint = 0;
    serial.writeString("[PMM] arena pages: ");
    fmt.writeDecimal64(total_pages);
    serial.writeString(", free: ");
    fmt.writeDecimal64(free_pages);
    serial.writeString("\n");
    klog.log(.info, "PMM arena initialized");
}

/// Allocate a single 4KB physical page. Returns physical address or null.
/// Uses word-at-a-time bitmap scanning for performance (64 pages per iteration).
/// v53.12: On OOM, attempts swap reclaim before returning null.
pub fn allocPage() ?u64 {
    {
        const flags = lock.acquire();
        const result = allocPageLocked();
        lock.release(flags);
        if (result != null) return result;
    }

    // v53.12: OOM — try swap reclaim before giving up (x86 shared-kernel path only).
    if (comptime builtin.cpu.arch == .x86_64) {
        if (@cmpxchgStrong(bool, &in_swap_reclaim, false, true, .acquire, .monotonic) == null) {
            defer @atomicStore(bool, &in_swap_reclaim, false, .release);

            const swap = @import("swap.zig");
            if (swap.isEnabled()) {
                const sched = @import("../proc/sched.zig");
                if (sched.currentTask()) |t| {
                    if (t.page_table_phys != 0) {
                        _ = swap.reclaimPages(t.page_table_phys, 32);
                        const flags = lock.acquire();
                        const result = allocPageLocked();
                        lock.release(flags);
                        return result;
                    }
                }
            }
        }
    }

    return null;
}

/// Inner allocation — caller must hold lock.
/// Word-at-a-time bitmap scanning: reads 64 bits at once, skips empty
/// 64-page blocks in a single iteration. Uses @ctz for fast bit scan.
fn allocPageLocked() ?u64 {
    const words: [*]const u64 = @ptrCast(@alignCast(bitmap));
    const total_words = bitmap_size / 8;
    const start_word = next_free_hint / 64;

    // Phase 1: scan forward from hint
    var w: u64 = start_word;
    while (w < total_words) : (w += 1) {
        var word = words[w];
        while (word != 0) {
            const bit = @ctz(word);
            const page = w * 64 + bit;
            if (page >= total_pages) return null;
            if (page >= min_alloc_page and ref_counts[page] == 0) {
                clearBit(page);
                ref_counts[page] = 1;
                free_pages -= 1;
                next_free_hint = page + 1;
                return physFromPage(page);
            }
            // Stale bit — clear and try next bit in same word
            clearBit(page);
            word &= word - 1; // clear lowest set bit
        }
    }

    // Phase 2: wrap around from min_alloc_page to hint
    const end_word = @min(start_word + 1, total_words);
    w = min_alloc_page / 64;
    while (w < end_word) : (w += 1) {
        var word = words[w];
        while (word != 0) {
            const bit = @ctz(word);
            const page = w * 64 + bit;
            if (page >= total_pages) return null;
            if (page >= min_alloc_page and ref_counts[page] == 0) {
                clearBit(page);
                ref_counts[page] = 1;
                free_pages -= 1;
                next_free_hint = page + 1;
                return physFromPage(page);
            }
            clearBit(page);
            word &= word - 1;
        }
    }

    next_free_hint = min_alloc_page;
    return null;
}

/// Allocate `count` physically contiguous pages. Returns base physical address or null.
pub fn allocContiguous(count: usize) ?u64 {
    return allocContiguousAligned(count, 1);
}

/// Allocate `count` contiguous frames starting at a multiple of
/// `align_pages` frames. Huge-page mappings require the base frame to be
/// aligned to the page size (a 2MiB PDE with a misaligned frame sets
/// reserved bits and faults on first access).
pub fn allocContiguousAligned(count: usize, align_pages: usize) ?u64 {
    if (count == 0) return null;
    if (count == 1) return allocPage();
    const alignment = @max(align_pages, 1);

    const flags = lock.acquire();
    defer lock.release(flags);

    const first = if (next_free_hint >= min_alloc_page and next_free_hint + count <= total_pages)
        next_free_hint
    else
        min_alloc_page;

    var pass: u8 = 0;
    var start: u64 = first;
    while (pass < 2) {
        const limit = if (pass == 0) total_pages else first;
        while (start + count <= limit) {
            const candidate = if (alignment <= 1) start else (start + alignment - 1) / alignment * alignment;
            if (candidate + count > limit) break;
            var skip_to = candidate + 1;
            if (tryAllocContiguousAt(candidate, count, &skip_to)) |phys| return phys;
            start = skip_to;
        }
        pass += 1;
        start = min_alloc_page;
    }
    return null;
}

fn tryAllocContiguousAt(start: u64, count: usize, skip_to: *u64) ?u64 {
    // Check if all pages [start, start+count) are free.
    for (0..count) |j| {
        const page = start + j;
        if (!isBitSet(page) or ref_counts[page] > 0) {
            skip_to.* = page + 1;
            return null;
        }
    }

    // Found contiguous free range — allocate all pages.
    for (0..count) |j| {
        const page = start + j;
        clearBit(page);
        ref_counts[page] = 1;
    }
    free_pages -= count;
    next_free_hint = start + @as(u64, @intCast(count));
    return physFromPage(start);
}

/// Free `count` physically contiguous pages starting at `phys` — the
/// counterpart of allocContiguous. Decrements each frame's refcount once
/// under a single lock acquisition; frames at refcount zero are skipped
/// silently (same double-free policy as freePageBatch).
pub fn freeContiguous(phys: u64, count: usize) void {
    if (count == 0) return;
    if (count == 1) {
        freePage(phys);
        return;
    }
    const flags = lock.acquire();
    defer lock.release(flags);
    const first = pageFromPhys(phys);
    for (0..count) |j| {
        const page = first + j;
        if (page >= total_pages) break;
        if (ref_counts[page] == 0) continue; // Skip double-free silently
        ref_counts[page] -= 1;
        if (ref_counts[page] == 0) {
            setBit(page);
            free_pages += 1;
            if (page < next_free_hint) next_free_hint = page;
        }
    }
}

/// Reserve a physical page (mark as used). Used to protect page table pages
/// that are already in use by Limine's mapping but might not be in the
/// kernel_and_modules memory map entry.
pub fn reservePage(phys: u64) void {
    const flags = lock.acquire();
    defer lock.release(flags);

    const page = pageFromPhys(phys);
    if (page >= total_pages) return;
    if (isBitSet(page)) {
        clearBit(page);
        if (free_pages > 0) free_pages -= 1;
    }
}

/// Free a physical page (decrement ref count, free if zero).
pub fn freePage(addr: u64) void {
    const flags = lock.acquire();

    const page = pageFromPhys(addr);
    if (page >= total_pages) {
        lock.release(flags);
        return;
    }
    if (ref_counts[page] == 0) {
        // v53.45: Release lock before serial I/O — holding pmm.lock during
        // UART output (~4ms for 50+ chars) blocks all CPUs' page alloc/free.
        lock.release(flags);
        serial.writeString("[PMM] BUG: double-free of page ");
        fmt.writeDecimal64(page);
        serial.writeString(" at addr 0x");
        fmt.writeHex(addr);
        serial.writeString("\n");
        return;
    }
    ref_counts[page] -= 1;
    if (ref_counts[page] == 0) {
        setBit(page);
        free_pages += 1;
        if (page < next_free_hint) next_free_hint = page;
    }
    lock.release(flags);
}

/// Increment reference count (for CoW).
pub fn addRef(addr: u64) void {
    const flags = lock.acquire();
    defer lock.release(flags);
    const page = pageFromPhys(addr);
    if (page < total_pages) ref_counts[page] +|= 1;
}

/// v53.47: Batch increment reference counts — single lock acquisition for
/// multiple pages. Used by fork COW to avoid N separate lock ops.
pub fn addRefBatch(addrs: []const u64) void {
    const flags = lock.acquire();
    defer lock.release(flags);
    for (addrs) |addr| {
        const page = pageFromPhys(addr);
        if (page < total_pages) ref_counts[page] +|= 1;
    }
}

/// v53.48: Batch free physical pages — single lock acquisition for multiple
/// pages. Used by destroyUserSpace to avoid N separate lock ops on process exit.
/// Double-frees are silently skipped (cannot do serial I/O mid-batch).
pub fn freePageBatch(addrs: []const u64) void {
    const flags = lock.acquire();
    defer lock.release(flags);
    for (addrs) |addr| {
        const page = pageFromPhys(addr);
        if (page >= total_pages) continue;
        if (ref_counts[page] == 0) continue; // Skip double-free silently
        ref_counts[page] -= 1;
        if (ref_counts[page] == 0) {
            setBit(page);
            free_pages += 1;
            if (page < next_free_hint) next_free_hint = page;
        }
    }
}

/// Decrement reference count, return new count.
pub fn decRef(addr: u64) u16 {
    const flags = lock.acquire();
    defer lock.release(flags);
    const page = pageFromPhys(addr);
    if (page >= total_pages) return 0;
    if (ref_counts[page] > 0) ref_counts[page] -= 1;
    return ref_counts[page];
}

/// Decrement a reference without returning the page to the free pool.
/// Used by address-space teardown, which must keep the root page readable
/// until all child page tables have been released.
pub fn decRefNoFree(addr: u64) ?u16 {
    const flags = lock.acquire();
    defer lock.release(flags);
    const page = pageFromPhys(addr);
    if (page >= total_pages or ref_counts[page] == 0) return null;
    ref_counts[page] -= 1;
    return ref_counts[page];
}

/// Get current reference count for a physical page.
pub fn getRefCount(addr: u64) u16 {
    const flags = lock.acquire();
    defer lock.release(flags);
    const page = pageFromPhys(addr);
    if (page >= total_pages) return 0;
    return ref_counts[page];
}

pub fn getFreePages() u64 {
    return free_pages;
}

pub fn getTotalPages() u64 {
    return total_pages;
}

// --- Bitmap helpers ---
fn setBit(page: u64) void {
    bitmap[page / 8] |= @as(u8, 1) << @intCast(page % 8);
}

fn clearBit(page: u64) void {
    bitmap[page / 8] &= ~(@as(u8, 1) << @intCast(page % 8));
}

fn isBitSet(page: u64) bool {
    return (bitmap[page / 8] & (@as(u8, 1) << @intCast(page % 8))) != 0;
}
