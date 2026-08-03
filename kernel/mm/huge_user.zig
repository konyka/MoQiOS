// kernel/mm/huge_user.zig — pure helpers for user 2MiB huge pages (I1)
//
// Deliberately free of imports so the host test runner can exercise it
// (same pattern as cow_pte.zig). Runtime users: x86_64 paging (demote),
// mmap/mprotect/fork via huge_user_impl.zig.

pub const PAGE_SIZE: u64 = 4096;
pub const HUGE_BYTES: u64 = 2 * 1024 * 1024;
/// 4K pages per 2MiB huge block.
pub const HUGE_PAGES: u64 = HUGE_BYTES / PAGE_SIZE; // 512

// PTE bit constants (x86_64 layout; mirror of paging.zig's, kept local so
// this file stays import-free).
pub const PRESENT: u64 = 1 << 0;
pub const WRITABLE: u64 = 1 << 1;
pub const USER: u64 = 1 << 2;
pub const HUGE_BIT: u64 = 1 << 7;
pub const ADDR_MASK: u64 = 0x000F_FFFF_FFFF_F000;

/// Whether an anonymous mapping of `num_pages` at `base` may use 2MiB pages:
/// the base must be 2MiB-aligned and at least one full huge block must fit.
pub fn eligible(base: u64, num_pages: u64) bool {
    return num_pages >= HUGE_PAGES and base % HUGE_BYTES == 0;
}

/// Number of full 2MiB blocks in `num_pages` (the huge-eligible prefix).
pub fn hugeBlocksFor(num_pages: u64) u64 {
    return num_pages / HUGE_PAGES;
}

/// Fill `out[0..512]` with the 4K PTEs mirroring a 2MiB PDE (`pde_raw`):
/// same physical base and permission bits, huge bit dropped, each PTE
/// advanced by one 4K frame. Returns the replacement PDE value pointing at
/// the new page table at `pt_phys` — a present table entry inheriting the
/// huge page's present/writable/user bits (bits 0-2 are the only ones the
/// CPU consults in a table pointer; accessed/dirty/NX of a table entry are
/// ignored, so they are deliberately not propagated).
pub fn demotePtes(pde_raw: u64, out: *[512]u64, pt_phys: u64) u64 {
    const phys = pde_raw & ADDR_MASK;
    const flags = pde_raw & ~ADDR_MASK & ~HUGE_BIT;
    for (0..512) |i| {
        out[i] = (phys + @as(u64, @intCast(i)) * PAGE_SIZE) | flags;
    }
    return (pt_phys & ADDR_MASK) | (pde_raw & (PRESENT | WRITABLE | USER));
}
