/// User-space address space management.
///
/// Each user process has its own PML4 page table:
///   - Entries 0-255 (lower half): user-space mappings
///   - Entries 256-511 (upper half): shared kernel mappings (copied from kernel PML4)
///
/// The kernel PML4 entries are shared (not copied), so kernel mappings
/// are automatically visible in every user address space.
const paging = @import("../arch/arch.zig").paging;
const pcid = @import("../arch/arch.zig").pcid;
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");

pub const PAGE_SIZE: u64 = 4096;

/// User-space virtual address layout:
///   0x0000_0000_0000_0000 - 0x0000_7FFF_FFFF_FFFF : user space (lower half)
///   0xFFFF_8000_0000_0000 - ...                    : kernel space (shared via HHDM)
///
/// Specific regions within user space:
///   0x0000_0000_0040_0000 (4MB) : load address for flat binaries
///   0x0000_0000_0080_0000 (8MB) : stack top; the stack grows down from here
///
/// ELF images carry their own load addresses and the C user programs link at
/// 16MB, i.e. *above* the stack. So there is no single ordering of code, heap
/// and stack that holds for both image kinds: for flat binaries the heap grows
/// from 4MB up toward the stack, while for ELF images it grows from 16MB upward
/// with the stack far below. Range checks that assume one ordering are wrong for
/// the other; callers must instead test whether the pages they want are free and
/// clamp against USER_HEAP_MAX.
pub const USER_CODE_BASE: u64 = 0x0040_0000; // 4MB — where programs are loaded
pub const USER_STACK_TOP: u64 = 0x0080_0000; // 8MB — stack grows down from here
pub const USER_STACK_BOTTOM: u64 = 0x0001_0000; // 64KB — minimum stack address
pub const USER_STACK_INITIAL: u64 = 64 * PAGE_SIZE; // 256KB — initial stack allocation

/// Top of the user half. Addresses at or above this belong to the kernel.
pub const USER_ADDR_MAX: u64 = 0x0000_8000_0000_0000; // 128TB

/// Ceiling for break growth. Well below the lower-half limit, so arithmetic on
/// `addr + length` cannot wrap into kernel space.
pub const USER_HEAP_MAX: u64 = 0x0000_0001_0000_0000; // 4GB

/// Window mmap draws from when the kernel picks the address. Kept above
/// USER_HEAP_MAX so that break growth and mmap never compete for pages — a
/// mapping placed directly above the break would otherwise wall the heap in —
/// and above USER_STACK_TOP so it stays clear of the stack's demand-grow range.
pub const USER_MMAP_BASE: u64 = 0x0000_0002_0000_0000; // 8GB
pub const USER_MMAP_MAX: u64 = 0x0000_0004_0000_0000; // 16GB

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

    // PCID: assign a process-context identifier to the new address space
    // (no-op when PCID is unsupported/disabled or the table is full — the
    // space then runs with legacy flush-on-switch semantics).
    pcid.registerSpace(pml4_phys);

    return pml4_phys;
}

/// Map a page into a user address space.
pub fn mapUserPage(pml4_phys: u64, virt: u64, phys: u64, writable: bool) !void {
    try mapUserPageInner(pml4_phys, virt, phys, writable, true);
}

/// Map a user page without TLB flush — for building new page tables.
pub fn mapUserPageNoFlush(pml4_phys: u64, virt: u64, phys: u64, writable: bool) !void {
    try mapUserPageInner(pml4_phys, virt, phys, writable, false);
}

fn mapUserPageInner(pml4_phys: u64, virt: u64, phys: u64, writable: bool, flush: bool) !void {
    const flags = paging.MapFlags{
        .writable = writable,
        .user = true,
        .no_execute = true,
        .global = false,
    };
    if (flush)
        try paging.mapPage(pml4_phys, virt, phys, flags)
    else
        try paging.mapPageNoFlush(pml4_phys, virt, phys, flags);
}

/// Retain a shared user address space for CLONE_VM.
pub fn retainUserSpace(pml4_phys: u64) void {
    pmm.addRef(pml4_phys);
}

/// Release a user address space. Shared CLONE_VM roots are destroyed only when
/// the last task drops its reference. Kernel mappings are never freed here.
pub fn destroyUserSpace(pml4_phys: u64) void {
    const remaining = pmm.decRefNoFree(pml4_phys) orelse return;
    if (remaining != 0) return;

    // PCID: free the space's identifier and poison its cached translations
    // (generation bump + local INVPCID) before the root page can be reused.
    pcid.unregisterSpace(pml4_phys);

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
                    // I1: a huge block owns 512 frames (allocContiguous sets
                    // one refcount each) — a single freePage would leak the
                    // other 511.
                    pmm.freeContiguous(pd[pd_idx] & paging.ADDR_MASK, 512);
                    continue;
                }

                const pt_phys = pd[pd_idx] & paging.ADDR_MASK;
                const pt_virt = hhdm.physToVirt(pt_phys);
                const pt: [*]u64 = @ptrFromInt(pt_virt);

                // v53.48: Batch free user pages — collect phys addresses and
                // flush every 128 to reduce pmm.lock acquisitions from O(N) to O(N/128).
                var free_buf: [128]u64 = undefined;
                var free_count: u32 = 0;
                for (0..512) |pt_idx| {
                    if (pt[pt_idx] & paging.PRESENT == 0) continue;
                    const virt = (@as(u64, pml4_idx) << 39) |
                        (@as(u64, pdpt_idx) << 30) |
                        (@as(u64, pd_idx) << 21) |
                        (@as(u64, pt_idx) << 12);
                    if (virt == @import("../proc/signal.zig").SIGRETURN_TRAMPOLINE_ADDR) continue;
                    const page_phys = pt[pt_idx] & paging.ADDR_MASK;
                    if (page_phys != 0 and page_phys >= 512 * 4096) {
                        free_buf[free_count] = page_phys;
                        free_count += 1;
                        if (free_count == 128) {
                            pmm.freePageBatch(free_buf[0..free_count]);
                            free_count = 0;
                        }
                    }
                }
                if (free_count > 0) pmm.freePageBatch(free_buf[0..free_count]);
                pmm.freePage(pt_phys);
            }
            pmm.freePage(pd_phys);
        }
        pmm.freePage(pdpt_phys);
    }
    // decRefNoFree left the root at refcount zero but allocated while the walk
    // was in progress. Restore one owned reference for the final free.
    pmm.addRef(pml4_phys);
    pmm.freePage(pml4_phys);
}

/// Get the PML4 virtual address for a user space.
pub fn getPml4Virt(pml4_phys: u64) u64 {
    return hhdm.physToVirt(pml4_phys);
}
