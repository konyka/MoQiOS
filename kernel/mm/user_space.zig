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

pub const PAGE_SIZE: u64 = 4096;

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

    // Walk user-space entries (0-255) and free all allocated tables/pages
    for (0..256) |pml4_idx| {
        if (pml4[pml4_idx] & paging.PRESENT == 0) continue;
        const pdpt_phys = pml4[pml4_idx] & paging.ADDR_MASK;
        const pdpt_virt = hhdm.physToVirt(pdpt_phys);
        const pdpt: [*]u64 = @ptrFromInt(pdpt_virt);

        for (0..512) |pdpt_idx| {
            if (pdpt[pdpt_idx] & paging.PRESENT == 0) continue;
            // Check for 1GB huge page in PDPT
            if (pdpt[pdpt_idx] & (1 << 7) != 0) {
                pmm.freePage(pdpt[pdpt_idx] & paging.ADDR_MASK);
                continue;
            }

            const pd_phys = pdpt[pdpt_idx] & paging.ADDR_MASK;
            const pd_virt = hhdm.physToVirt(pd_phys);
            const pd: [*]u64 = @ptrFromInt(pd_virt);

            for (0..512) |pd_idx| {
                if (pd[pd_idx] & paging.PRESENT == 0) continue;
                // Check for 2MB huge page in PD
                if (pd[pd_idx] & (1 << 7) != 0) {
                    pmm.freePage(pd[pd_idx] & paging.ADDR_MASK);
                    continue;
                }

                const pt_phys = pd[pd_idx] & paging.ADDR_MASK;
                const pt_virt = hhdm.physToVirt(pt_phys);
                const pt: [*]u64 = @ptrFromInt(pt_virt);

                for (0..512) |pt_idx| {
                    if (pt[pt_idx] & paging.PRESENT == 0) continue;
                    const page_phys = pt[pt_idx] & paging.ADDR_MASK;
                    if (page_phys != 0 and page_phys >= 512 * 4096) pmm.freePage(page_phys);
                }
                pmm.freePage(pt_phys);
            }
            pmm.freePage(pd_phys);
        }
        pmm.freePage(pdpt_phys);
    }
    pmm.freePage(pml4_phys);
}

/// Get the PML4 virtual address for a user space.
pub fn getPml4Virt(pml4_phys: u64) u64 {
    return hhdm.physToVirt(pml4_phys);
}
