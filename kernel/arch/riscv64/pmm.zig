//! Physical page allocator for the riscv64 skeleton (Milestone 3).
//!
//! Intrusive freelist of 4 KiB pages. Usable RAM comes from the FDT `/memory`
//! regions, minus OpenSBI (below kernel), the kernel image, and the DTB page
//! range. No locks — single-hart early boot only.

pub const PAGE_SIZE: usize = 4096;

extern const __kernel_end: u8;

var free_head: usize = 0;
var free_count: usize = 0;
var total_pages: usize = 0;

fn alignUp(v: usize, a: usize) usize {
    return (v + a - 1) & ~(a - 1);
}

fn alignDown(v: usize, a: usize) usize {
    return v & ~(a - 1);
}

fn pushPage(phys: usize) void {
    const ptr: *usize = @ptrFromInt(phys);
    ptr.* = free_head;
    free_head = phys;
    free_count += 1;
}

/// Mark `[start, end)` as free pages (page-aligned). Skips the DTB span.
fn addRange(start: usize, end: usize, dtb_lo: usize, dtb_hi: usize) void {
    var p = alignUp(start, PAGE_SIZE);
    const last = alignDown(end, PAGE_SIZE);
    while (p + PAGE_SIZE <= last) : (p += PAGE_SIZE) {
        if (p < dtb_hi and p + PAGE_SIZE > dtb_lo) continue;
        pushPage(p);
        total_pages += 1;
    }
}

/// Initialise the freelist from FDT memory regions.
pub fn init(regions: []const @import("fdt.zig").MemRegion, dtb: usize, dtb_size: usize, free_start: usize) void {
    free_head = 0;
    free_count = 0;
    total_pages = 0;

    const kernel_end = alignUp(@intFromPtr(&__kernel_end), PAGE_SIZE);
    const start_floor = @max(kernel_end, alignUp(free_start, PAGE_SIZE));
    const dtb_lo = alignDown(dtb, PAGE_SIZE);
    const dtb_hi = alignUp(dtb + dtb_size, PAGE_SIZE);

    for (regions) |r| {
        const base: usize = @intCast(r.base);
        const end: usize = @intCast(r.base + r.size);
        // Free only memory above the shared-kernel carve / kernel image.
        const start = @max(base, start_floor);
        if (start < end) addRange(start, end, dtb_lo, dtb_hi);
    }
}

pub fn allocPage() ?usize {
    if (free_head == 0) return null;
    const page = free_head;
    const ptr: *usize = @ptrFromInt(page);
    free_head = ptr.*;
    free_count -= 1;
    // Clear the page so page-table allocations start zeroed.
    const bytes: [*]u8 = @ptrFromInt(page);
    @memset(bytes[0..PAGE_SIZE], 0);
    return page;
}

pub fn freePage(phys: usize) void {
    pushPage(phys);
}

pub fn freeCount() usize {
    return free_count;
}

pub fn totalManaged() usize {
    return total_pages;
}
