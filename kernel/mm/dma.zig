/// DMA buffer management — physically contiguous buffers for device I/O.
/// Supports multi-page allocation and single-page mapping.
const pmm = @import("pmm.zig");
const hhdm = @import("hhdm.zig");
const serial = @import("../arch/x86_64/serial.zig");
const klog = @import("../klog.zig");
const paging = @import("../arch/x86_64/paging.zig");

pub const DmaBuffer = struct {
    virt_addr: u64,
    phys_addr: u64,
    size: usize,
    /// Number of physical pages (for freeCoherent).
    pages: u32 = 1,
};

/// Allocate a DMA-coherent buffer (physically contiguous).
/// For multi-page allocations, allocates contiguous pages from PMM.
pub fn allocCoherent(size: usize) ?DmaBuffer {
    const pages_needed = (size + 4095) / 4096;
    if (pages_needed == 0) return null;

    if (pages_needed == 1) {
        const phys = pmm.allocPage() orelse return null;
        const virt = hhdm.physToVirt(phys);
        // Zero the buffer
        const ptr: [*]u8 = @ptrFromInt(virt);
        @memset(ptr[0..4096], 0);
        return .{ .virt_addr = virt, .phys_addr = phys, .size = 4096, .pages = 1 };
    }

    // Multi-page: allocate contiguous physical pages
    const phys_base = pmm.allocContiguous(pages_needed) orelse {
        serial.writeString("[dma] allocCoherent: contiguous alloc failed for ");
        klog.log(.warn, "[dma] allocCoherent: contiguous alloc failed, falling back to scatter");
        return allocCoherentScatter(pages_needed);
    };
    const virt_base = hhdm.physToVirt(phys_base);
    const total_size = pages_needed * 4096;
    // Zero the buffer
    const ptr: [*]u8 = @ptrFromInt(virt_base);
    @memset(ptr[0..total_size], 0);
    return .{
        .virt_addr = virt_base,
        .phys_addr = phys_base,
        .size = total_size,
        .pages = @intCast(pages_needed),
    };
}

/// Fallback: allocate individual pages and map them contiguously in kernel space.
fn allocCoherentScatter(pages_needed: usize) ?DmaBuffer {
    const kernel_pml4 = paging.getKernelPml4();
    // Use the first page's HHDM address as the virtual base
    const phys0 = pmm.allocPage() orelse return null;
    const virt0 = hhdm.physToVirt(phys0);

    // For additional pages, map them contiguously after virt0 in kernel PML4
    var phys_pages: [256]u64 = undefined; // max 1MB scatter
    if (pages_needed > 256) {
        pmm.freePage(phys0);
        return null;
    }
    phys_pages[0] = phys0;

    var i: usize = 1;
    while (i < pages_needed) : (i += 1) {
        const phys = pmm.allocPage() orelse {
            // Cleanup
            for (0..i) |j| pmm.freePage(phys_pages[j]);
            return null;
        };
        phys_pages[i] = phys;
        const target_virt = virt0 + i * 4096;
        const flags = paging.MapFlags{
            .writable = true,
            .user = false,
            .no_execute = true,
            .global = true,
        };
        paging.mapPage(kernel_pml4, target_virt, phys, flags) catch {
            pmm.freePage(phys);
            for (0..i) |j| pmm.freePage(phys_pages[j]);
            return null;
        };
    }

    const total_size = pages_needed * 4096;
    const ptr: [*]u8 = @ptrFromInt(virt0);
    @memset(ptr[0..total_size], 0);
    return .{
        .virt_addr = virt0,
        .phys_addr = phys0,
        .size = total_size,
        .pages = @intCast(pages_needed),
    };
}

/// Free a DMA-coherent buffer.
pub fn freeCoherent(buf: DmaBuffer) void {
    if (buf.pages <= 1) {
        pmm.freePage(buf.phys_addr);
        return;
    }
    // For contiguous allocations, free each page
    for (0..buf.pages) |i| {
        pmm.freePage(buf.phys_addr + i * 4096);
    }
}

/// Map a single physical page for DMA access.
/// Returns the kernel virtual address (via HHDM).
pub fn mapSingle(phys: u64) ?u64 {
    return hhdm.physToVirt(phys);
}

/// Unmap a single DMA page (no-op for HHDM-mapped pages).
pub fn unmapSingle(phys: u64) void {
    _ = phys;
}

pub fn init() void {
    klog.log(.info, "DMA manager initialized (multi-page + scatter support)");
}
