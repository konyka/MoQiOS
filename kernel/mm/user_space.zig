/// User-space address space management.
///
/// Each user process has its own PML4 page table:
///   - Entries 0-255 (lower half): user-space mappings
///   - Entries 256-511 (upper half): shared kernel mappings (copied from kernel PML4)
///
/// The kernel PML4 entries are shared (not copied), so kernel mappings
/// are automatically visible in every user address space.

const paging = @import("../arch/x86_64/paging.zig");
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");

const PAGE_SIZE: u64 = 4096;

/// User-space virtual address layout:
///   0x0000_0000_0000_0000 - 0x0000_7FFF_FFFF_FFFF : user space (lower half)
///   0xFFFF_8000_0000_0000 - ...                    : kernel space (shared via HHDM)
///
/// Specific regions within user space:
///   0x0000_0000_0040_0000 (4MB)    : code region (load address)
///   0x0000_0000_7FC0_0000 (~2GB-64MB): stack region (grows down from ~2GB)

pub const USER_CODE_BASE: u64 = 0x0040_0000; // 4MB — where programs are loaded
pub const USER_STACK_TOP: u64 = 0x0080_0000; // 8MB — stack grows down from here

/// Create a new user address space (PML4).
/// Copies kernel-space entries (256-511) from the kernel PML4.
/// Returns the physical address of the new PML4, or null on failure.
pub fn createUserSpace() ?u64 {
    const pml4_phys = pmm.allocPage() orelse return null;
    const pml4_virt = hhdm.physToVirt(pml4_phys);

    // Zero the new PML4
    const pml4: [*]u64 = @ptrFromInt(pml4_virt);
    @memset(pml4[0..512], 0);

    // Copy kernel-space entries (upper half, entries 256-511) from kernel PML4
    const kernel_pml4_phys = paging.getKernelPml4();
    const kernel_pml4_virt = hhdm.physToVirt(kernel_pml4_phys);
    const kernel_pml4: [*]u64 = @ptrFromInt(kernel_pml4_virt);
    for (256..512) |i| {
        pml4[i] = kernel_pml4[i];
    }

    return pml4_phys;
}

/// Map a page into a user address space.
pub fn mapUserPage(pml4_phys: u64, virt: u64, phys: u64, writable: bool) !void {
    const flags = paging.MapFlags{
        .writable = writable,
        .user = true, // User-accessible
        .no_execute = true,
        .global = false, // Not global (per-process)
    };

    try paging.mapPage(pml4_phys, virt, phys, flags);
}

/// Destroy a user address space — free all user-space page tables and mapped pages.
/// Does NOT free the kernel pages (those are shared).
pub fn destroyUserSpace(pml4_phys: u64) void {
    const pml4_virt = hhdm.physToVirt(pml4_phys);
    const pml4: [*]u64 = @ptrFromInt(pml4_virt);

    // Walk entries 0-255 (user space), free page tables and mapped pages
    for (0..256) |i| {
        const pdpe_entry = pml4[i];
        if (pdpe_entry & paging.PRESENT == 0) continue;

        const pdpt_phys = pdpe_entry & paging.ADDR_MASK;
        if (pdpt_phys == 0) continue;
        if (pdpt_phys < 512 * 4096) continue;
        const pdpt_virt = hhdm.physToVirt(pdpt_phys);
        const pdpt: [*]u64 = @ptrFromInt(pdpt_virt);

        for (0..512) |j| {
            const pd_entry = pdpt[j];
            if (pd_entry & paging.PRESENT == 0) continue;
            // Check for 1GB huge page
            if (pd_entry & (1 << 7) != 0) continue;

            const pd_phys = pd_entry & paging.ADDR_MASK;
            if (pd_phys == 0) continue;
            if (pd_phys < 512 * 4096) continue;
            const pd_virt = hhdm.physToVirt(pd_phys);
            const pd: [*]u64 = @ptrFromInt(pd_virt);

            for (0..512) |k| {
                const pt_entry = pd[k];
                if (pt_entry & paging.PRESENT == 0) continue;
                // Check for 2MB huge page
                if (pt_entry & (1 << 7) != 0) {
                    const page_phys = pt_entry & paging.ADDR_MASK;
                    if (page_phys != 0) pmm.freePage(page_phys);
                    continue;
                }

                const pt_phys = pt_entry & paging.ADDR_MASK;
                if (pt_phys == 0) continue;
                if (pt_phys < 512 * 4096) continue;

                const pt_virt = hhdm.physToVirt(pt_phys);
                const pt: [*]u64 = @ptrFromInt(pt_virt);

                for (0..512) |l| {
                    const page_entry = pt[l];
                    if (page_entry & paging.PRESENT == 0) continue;

                    // Free the mapped physical page
                    const page_phys = page_entry & paging.ADDR_MASK;
                    if (page_phys == 0) continue;
                    if (page_phys < 512 * 4096) continue;
                    pmm.freePage(page_phys);
                }
                // Free the page table page
                pmm.freePage(pt_phys);
            }
            // Free the page directory page
            pmm.freePage(pd_phys);
        }
        // Free the PDPT page
        pmm.freePage(pdpt_phys);
    }

    // Free the PML4 itself
    pmm.freePage(pml4_phys);
}

fn fmtHex(val: u64) []const u8 {
    const chars = "0123456789abcdef";
    var buf: [18]u8 = undefined;
    buf[0..2].* = .{ '0', 'x' };
    var k: usize = 2;
    var started = false;
    for (0..16) |i| {
        const nibble = (val >> @intCast(60 - i * 4)) & 0xF;
        if (nibble != 0 or started or i == 15) {
            buf[k] = chars[@intCast(nibble)];
            k += 1;
            started = true;
        }
    }
    return buf[0..k];
}

fn fmtInt(val: u64) []const u8 {
    var buf: [20]u8 = undefined;
    if (val == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var v = val;
    var i: usize = 0;
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

/// Get the PML4 virtual address for a user space.
pub fn getPml4Virt(pml4_phys: u64) u64 {
    return hhdm.physToVirt(pml4_phys);
}
