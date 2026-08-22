// kernel/mm/huge_user_impl.zig — runtime helpers for user 2MiB huge pages (I1).
//
// The feature is x86_64-only: the huge paths reach into x86 paging internals
// (2MiB PDEs). Other backends get no-op stubs so shared mm code
// (mmap/mprotect/fork) compiles unchanged; with the stubs no huge page is
// ever created and every demote is a no-op. Pure flag/address arithmetic
// lives in huge_user.zig (host-tested); this file is the arch-touching half.

const builtin = @import("builtin");

/// Whether this backend supports user 2MiB huge pages at all. mmap.zig ANDs
/// this with its `huge_user_enable` compile-time gate.
pub const enable: bool = builtin.cpu.arch == .x86_64;

const x86 = struct {
    const paging = @import("../arch/x86_64/paging.zig");
    const tlb = @import("../arch/x86_64/tlb.zig");
    const pmm = @import("pmm.zig");
    const hhdm = @import("hhdm.zig");
    const huge = @import("huge_user.zig");

    /// munmap/unmapRange pre-pass over [base, base + num_pages*4096):
    /// - a huge block FULLY inside the range is unmapped and its 512 frames
    ///   freed directly (no demote);
    /// - a huge block only PARTIALLY overlapped is demoted to 4K pages, so
    ///   the caller's ordinary 4K unmap pass applies to it.
    fn prescanHuge(cr3: u64, base: u64, num_pages: u64) void {
        const end = base + num_pages * huge.PAGE_SIZE;
        var blk = base & ~(huge.HUGE_BYTES - 1);
        while (blk < end) : (blk += huge.HUGE_BYTES) {
            const pde = paging.getPdEntry(cr3, blk) orelse continue;
            if (!pde.huge_page) continue;
            if (!pde.present and pde.getPhysAddr() == 0) continue;
            if (blk >= base and blk + huge.HUGE_BYTES <= end) {
                const phys = paging.unmapHugePage(cr3, blk).?;
                tlb.shootdownRange(blk, @intCast(huge.HUGE_PAGES), cr3);
                pmm.freeContiguous(phys, huge.HUGE_PAGES);
            } else {
                // OOM splitting: leave the block mapped — the 4K pass skips
                // it (unmapPage refuses huge entries), leaking the block
                // rather than corrupting the address space.
                paging.demoteHugePage(cr3, blk) catch {};
            }
        }
    }

    /// Allocate + zero + map one 2MiB block. Returns false when no
    /// contiguous run is available or the map failed (frames released);
    /// the caller then falls back to 4K pages for the rest of the region.
    fn mapHugeBlock(cr3: u64, virt: u64, flags: paging.MapFlags) bool {
        // The base frame MUST be 2MiB-aligned — a misaligned huge PDE sets
        // reserved bits and faults on first access.
        const phys = pmm.allocContiguousAligned(huge.HUGE_PAGES, huge.HUGE_PAGES) orelse return false;
        // Zero the block (security: don't leak kernel data), same rule as
        // the 4K path.
        const ptr: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
        @memset(ptr[0..huge.HUGE_BYTES], 0);
        paging.mapHugePage(cr3, virt, phys, flags) catch {
            pmm.freeContiguous(phys, huge.HUGE_PAGES);
            return false;
        };
        return true;
    }

    /// Demote every 2MiB huge block overlapping [base, base + num_pages*4096).
    fn demoteRange(cr3: u64, base: u64, num_pages: u64) !void {
        const end = base + num_pages * huge.PAGE_SIZE;
        var blk = base & ~(huge.HUGE_BYTES - 1);
        while (blk < end) : (blk += huge.HUGE_BYTES) {
            try paging.demoteHugePage(cr3, blk); // no-op unless a huge PDE
        }
    }

    /// mprotect pre-pass over [addr, end): the 4K PTE walk skips huge PDEs
    /// (getPageEntry refuses them), so a huge block FULLY covered by the
    /// range is re-flagged in place (stays huge) and a PARTIALLY covered
    /// block is demoted for the 4K walk to re-flag. Huge pages are never
    /// COW-shared (fork/clone demote both sides first), so no COW unshare
    /// is needed here.
    fn protectHugeOverlaps(cr3: u64, addr: u64, end: u64, prot: u64) !void {
        var blk = addr & ~(huge.HUGE_BYTES - 1);
        while (blk < end) : (blk += huge.HUGE_BYTES) {
            const pde = paging.getPdEntry(cr3, blk) orelse continue;
            if (!pde.huge_page) continue;
            if (blk >= addr and blk + huge.HUGE_BYTES <= end) {
                if (prot == 0) { // PROT_NONE
                    pde.present = false; // frame preserved, mirrors the 4K path
                } else {
                    pde.present = true;
                    pde.no_execute = (prot & 4) == 0; // PROT_EXEC
                    pde.user = true;
                    pde.writable = (prot & 2) != 0; // PROT_WRITE
                }
            } else {
                try paging.demoteHugePage(cr3, blk);
            }
        }
    }

    fn protectHugeOverlapsReserved(cr3: u64, addr: u64, end: u64, prot: u64, reserved: []const u64) u32 {
        var used: u32 = 0;
        var blk = addr & ~(huge.HUGE_BYTES - 1);
        while (blk < end) : (blk += huge.HUGE_BYTES) {
            const pde = paging.getPdEntry(cr3, blk) orelse continue;
            if (!pde.huge_page) continue;
            if (blk >= addr and blk + huge.HUGE_BYTES <= end) {
                if (prot == 0) {
                    pde.present = false;
                } else {
                    pde.present = true;
                    pde.no_execute = (prot & 4) == 0;
                    pde.user = true;
                    pde.writable = (prot & 2) != 0;
                }
            } else {
                if (used >= reserved.len) unreachable;
                if (paging.demoteHugePageReserved(cr3, blk, reserved[used])) used += 1;
            }
        }
        return used;
    }

    /// fork/clone COW walks are 4K-only. If `pd[pd_idx]` is a huge PDE,
    /// demote it in the parent and return the replacement (table) entry;
    /// otherwise return the entry unchanged.
    fn demoteIfHugePde(cr3: u64, pd: [*]u64, pd_idx: usize, virt: u64) !u64 {
        const pde = pd[pd_idx];
        if (pde == 0 or pde & 1 == 0) return pde;
        if (pde & huge.HUGE_BIT == 0) return pde;
        try paging.demoteHugePage(cr3, virt);
        return pd[pd_idx];
    }
};

const stub = struct {
    fn prescanHuge(cr3: u64, base: u64, num_pages: u64) void {
        _ = cr3;
        _ = base;
        _ = num_pages;
    }
    fn mapHugeBlock(cr3: u64, virt: u64, flags: anytype) bool {
        _ = cr3;
        _ = virt;
        _ = flags;
        return false;
    }
    fn demoteRange(cr3: u64, base: u64, num_pages: u64) !void {
        _ = cr3;
        _ = base;
        _ = num_pages;
    }
    fn protectHugeOverlaps(cr3: u64, addr: u64, end: u64, prot: u64) !void {
        _ = cr3;
        _ = addr;
        _ = end;
        _ = prot;
    }
    fn demoteIfHugePde(cr3: u64, pd: [*]u64, pd_idx: usize, virt: u64) !u64 {
        _ = cr3;
        _ = virt;
        return pd[pd_idx];
    }

    fn protectHugeOverlapsReserved(cr3: u64, addr: u64, end: u64, prot: u64, reserved: []const u64) u32 {
        _ = cr3;
        _ = addr;
        _ = end;
        _ = prot;
        _ = reserved;
        return 0;
    }
};

const impl = switch (builtin.cpu.arch) {
    .x86_64 => x86,
    else => stub,
};

pub const prescanHuge = impl.prescanHuge;
pub const mapHugeBlock = impl.mapHugeBlock;
pub const demoteRange = impl.demoteRange;
pub const protectHugeOverlaps = impl.protectHugeOverlaps;
pub const protectHugeOverlapsReserved = impl.protectHugeOverlapsReserved;
pub const demoteIfHugePde = impl.demoteIfHugePde;
