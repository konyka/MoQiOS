/// Physical Memory Manager — bitmap allocator for 4KB page frames.
/// Reads Limine memory map, creates bitmap + ref_counts in usable memory.
/// Tracks free/used pages with per-page reference counting.
const limine = @import("../limine.zig");
const hhdm = @import("hhdm.zig");
const serial = @import("../arch/x86_64/serial.zig");
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

/// Skip first 2 MB (512 pages) — legacy BIOS area.
const MIN_ALLOC_PAGE: u64 = 512;

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
    const entry_count = memmap.entry_count;
    const entries = memmap.entries;

    // Pass 1: find highest usable physical address
    highest_phys = 0;
    for (0..entry_count) |i| {
        const entry = entries[i];
        const top = entry.base + entry.length;
        switch (entry.kind) {
            .usable, .bootloader_reclaimable, .kernel_and_modules, .acpi_reclaimable => {
                if (top > highest_phys) highest_phys = top;
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

    next_free_hint = MIN_ALLOC_PAGE;

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

    // v53.12: OOM — try swap reclaim before giving up
    // v53.13: Use atomic CAS to ensure only one CPU enters reclaim at a time
    if (@cmpxchgStrong(bool, &in_swap_reclaim, false, true, .acquire, .monotonic) == null) {
        defer @atomicStore(bool, &in_swap_reclaim, false, .release);

        const swap = @import("swap.zig");
        if (swap.isEnabled()) {
            const sched = @import("../proc/sched.zig");
            if (sched.currentTask()) |t| {
                if (t.page_table_phys != 0) {
                    _ = swap.reclaimPages(t.page_table_phys, 32);
                    // Retry allocation after reclaim
                    const flags = lock.acquire();
                    const result = allocPageLocked();
                    lock.release(flags);
                    return result;
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
            if (page >= MIN_ALLOC_PAGE and ref_counts[page] == 0) {
                clearBit(page);
                ref_counts[page] = 1;
                free_pages -= 1;
                next_free_hint = page + 1;
                return page * PAGE_SIZE;
            }
            // Stale bit — clear and try next bit in same word
            clearBit(page);
            word &= word - 1; // clear lowest set bit
        }
    }

    // Phase 2: wrap around from MIN_ALLOC_PAGE to hint
    const end_word = @min(start_word + 1, total_words);
    w = MIN_ALLOC_PAGE / 64;
    while (w < end_word) : (w += 1) {
        var word = words[w];
        while (word != 0) {
            const bit = @ctz(word);
            const page = w * 64 + bit;
            if (page >= total_pages) return null;
            if (page >= MIN_ALLOC_PAGE and ref_counts[page] == 0) {
                clearBit(page);
                ref_counts[page] = 1;
                free_pages -= 1;
                next_free_hint = page + 1;
                return page * PAGE_SIZE;
            }
            clearBit(page);
            word &= word - 1;
        }
    }

    next_free_hint = MIN_ALLOC_PAGE;
    return null;
}

/// Allocate `count` physically contiguous pages. Returns base physical address or null.
pub fn allocContiguous(count: usize) ?u64 {
    if (count == 0) return null;
    if (count == 1) return allocPage();

    const flags = lock.acquire();
    defer lock.release(flags);

    var start: u64 = MIN_ALLOC_PAGE;
    while (start + count <= total_pages) : (start += 1) {
        // Check if all pages [start, start+count) are free
        var all_free = true;
        for (0..count) |j| {
            if (!isBitSet(start + j) or ref_counts[start + j] > 0) {
                all_free = false;
                start += j; // skip ahead past the used page
                break;
            }
        }
        if (!all_free) continue;

        // Found contiguous free range — allocate all pages
        for (0..count) |j| {
            const page = start + j;
            clearBit(page);
            ref_counts[page] = 1;
        }
        free_pages -= count;
        return start * PAGE_SIZE;
    }
    return null;
}

/// Reserve a physical page (mark as used). Used to protect page table pages
/// that are already in use by Limine's mapping but might not be in the
/// kernel_and_modules memory map entry.
pub fn reservePage(phys: u64) void {
    const flags = lock.acquire();
    defer lock.release(flags);

    const page = phys / PAGE_SIZE;
    if (page >= total_pages) return;
    if (isBitSet(page)) {
        clearBit(page);
        if (free_pages > 0) free_pages -= 1;
    }
}

/// Free a physical page (decrement ref count, free if zero).
pub fn freePage(addr: u64) void {
    const flags = lock.acquire();

    const page = addr / PAGE_SIZE;
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
    const page = addr / PAGE_SIZE;
    if (page < total_pages) ref_counts[page] +|= 1;
}

/// Decrement reference count, return new count.
pub fn decRef(addr: u64) u16 {
    const flags = lock.acquire();
    defer lock.release(flags);
    const page = addr / PAGE_SIZE;
    if (page >= total_pages) return 0;
    if (ref_counts[page] > 0) ref_counts[page] -= 1;
    return ref_counts[page];
}

/// Get current reference count for a physical page.
pub fn getRefCount(addr: u64) u16 {
    const flags = lock.acquire();
    defer lock.release(flags);
    const page = addr / PAGE_SIZE;
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
