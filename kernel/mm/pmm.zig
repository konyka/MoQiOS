/// Physical Memory Manager — bitmap allocator for 4KB page frames.
/// Reads Limine memory map, creates bitmap + ref_counts in usable memory.
/// Tracks free/used pages with per-page reference counting.

const limine = @import("../limine.zig");
const hhdm = @import("hhdm.zig");
const serial = @import("../arch/x86_64/serial.zig");
const klog = @import("../klog.zig");
const page_frame = @import("page_frame.zig");

const PAGE_SIZE: u64 = 4096;

// --- State ---
var bitmap: [*]u8 = undefined;
var bitmap_size: u64 = 0;
var total_pages: u64 = 0;
var free_pages: u64 = 0;
var highest_phys: u64 = 0;
var ref_counts: [*]u16 = undefined;

/// Skip first 2 MB (512 pages) — legacy BIOS area.
const MIN_ALLOC_PAGE: u64 = 512;

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
    var buf: [20]u8 = undefined;
    serial.writeString(formatInt(&buf, total_pages));
    serial.writeString(", free: ");
    serial.writeString(formatInt(&buf, free_pages));
    serial.writeString("\n");

    klog.log(.info, "PMM initialized");
}

/// Allocate a single 4KB physical page. Returns physical address or null.
pub fn allocPage() ?u64 {
    var i: u64 = next_free_hint;
    while (i < total_pages) : (i += 1) {
        if (isBitSet(i)) {
            clearBit(i);
            ref_counts[i] = 1;
            free_pages -= 1;
            next_free_hint = i + 1;
            return i * PAGE_SIZE;
        }
    }
    i = MIN_ALLOC_PAGE;
    while (i < next_free_hint) : (i += 1) {
        if (isBitSet(i)) {
            clearBit(i);
            ref_counts[i] = 1;
            free_pages -= 1;
            next_free_hint = i + 1;
            return i * PAGE_SIZE;
        }
    }
    next_free_hint = MIN_ALLOC_PAGE;
    return null;
}

/// Free a physical page (decrement ref count, free if zero).
pub fn freePage(addr: u64) void {
    const page = addr / PAGE_SIZE;
    if (page >= total_pages) return;
    if (ref_counts[page] == 0) {
        serial.writeString("[PMM] BUG: double-free of page ");
        var buf: [20]u8 = undefined;
        serial.writeString(formatInt(&buf, page));
        serial.writeString(" at addr 0x");
        serial.writeString(formatHex(&buf, addr));
        serial.writeString("\n");
        return;
    }
    ref_counts[page] -= 1;
    if (ref_counts[page] == 0) {
        setBit(page);
        free_pages += 1;
        if (page < next_free_hint) next_free_hint = page;
    }
}

/// Increment reference count (for CoW).
pub fn addRef(addr: u64) void {
    const page = addr / PAGE_SIZE;
    if (page < total_pages) ref_counts[page] +|= 1;
}

/// Decrement reference count, return new count.
pub fn decRef(addr: u64) u16 {
    const page = addr / PAGE_SIZE;
    if (page >= total_pages) return 0;
    if (ref_counts[page] > 0) ref_counts[page] -= 1;
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

fn formatInt(buf: []u8, value: u64) []const u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var i: usize = 0;
    var v = value;
    while (v > 0) : (v /= 10) {
        buf[i] = @intCast(v % 10 + '0');
        i += 1;
    }
    var j: usize = 0;
    while (j < i / 2) : (j += 1) {
        const tmp = buf[j];
        buf[j] = buf[i - 1 - j];
        buf[i - 1 - j] = tmp;
    }
    return buf[0..i];
}

fn formatHex(buf: []u8, value: u64) []const u8 {
    const hex = "0123456789abcdef";
    var i: usize = 16;
    var v = value;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@as(usize, @intCast(v & 0xf))];
        v >>= 4;
    }
    return buf[0..16];
}
