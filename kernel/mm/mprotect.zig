/// mprotect system call — modify protection attributes of mapped memory regions.
///
/// prot flags: PROT_NONE=0, PROT_READ=1, PROT_WRITE=2, PROT_EXEC=4
///
/// Implementation walks the page tables for the given range and modifies
/// PTE permission bits directly. For PROT_NONE the present bit is cleared
/// while the physical frame number is preserved so the mapping can be
/// restored later.
const paging = @import("../arch/arch.zig").paging;
const tlb = @import("../arch/arch.zig").tlb;
const sched = @import("../proc/sched.zig");
const task = @import("../proc/task.zig");
const user_space = @import("user_space.zig");
const pmm = @import("pmm.zig");
const hhdm = @import("hhdm.zig");
const cow_pte = @import("cow_pte.zig");
const filemap = @import("filemap.zig");
const huge_impl = @import("huge_user_impl.zig");
const policy = @import("mprotect_policy.zig");

pub const PROT_NONE: u64 = 0;
pub const PROT_READ: u64 = 1;
pub const PROT_WRITE: u64 = 2;
pub const PROT_EXEC: u64 = 4;

const errno = @import("../lib/errno.zig");
const EINVAL = errno.EINVAL;
const ENOMEM = errno.ENOMEM;
const EACCES = errno.EACCES;

/// H1: insert a file-region piece cloned from `proto` with a different
/// prot/file_offset, for mprotect splits. Mirrors the split piece in
/// mmap.zig's untrackMmapRange, including the ext2 open-slot retain (each
/// piece's releaseRegionBacking balances one reference).
fn insertRegionPiece(cur: *task.Task, base: u64, num_pages: u64, proto: *const task.MmapRegion, prot: u8, file_offset: u64) void {
    for (&cur.mmap_regions) |*slot| {
        if (!slot.active) {
            slot.* = .{
                .base = base,
                .num_pages = num_pages,
                .active = true,
                .locked = proto.locked,
                // L1: a split user-MMIO/DMA piece keeps the no-free accounting.
                .no_free = proto.no_free,
                .file_kind = proto.file_kind,
                .shared = proto.shared,
                .prot = prot,
                .file_offset = file_offset,
                .file_size = proto.file_size,
                .file_idx = proto.file_idx,
                .file_data = proto.file_data,
                .inode_id = proto.inode_id,
            };
            if (proto.file_kind == @intFromEnum(filemap.FsKind.ext2)) {
                @import("../fs/ext2.zig").retainFile(proto.file_idx);
            }
            cur.mmap_count += 1;
            const idx = (@intFromPtr(slot) - @intFromPtr(&cur.mmap_regions[0])) / @sizeOf(task.MmapRegion);
            cur.mmap_active_bm |= @as(u64, 1) << @intCast(idx);
            return;
        }
    }
    unreachable; // slot capacity is checked before any PTE is touched
}

/// sysMprotect(addr, len, prot) → 0 on success, negative errno on failure.
pub fn sysMprotect(addr: u64, len: u64, prot: u64) i64 {
    // 1. Validate addr is page-aligned
    if (addr % paging.PAGE_SIZE != 0) return EINVAL;
    if (len == 0) return EINVAL;

    // 2. Validate prot — valid bits are 0..7 (NONE|READ|WRITE|EXEC)
    if (prot & ~@as(u64, 7) != 0) return EINVAL;

    // 3. Reject kernel-half ranges — kernel stacks and DMA pages share PML4
    // entries 256-511, so flipping U/S+writable there must not be possible.
    // Mirrors the munmap check in mmap.zig.
    if (addr >= user_space.USER_ADDR_MAX) return EINVAL;
    if (len > user_space.USER_ADDR_MAX - addr) return EINVAL;
    // The TLB shootdown API takes a u32 page count; reject larger requests
    // before any preflight work rather than allowing a truncating cast.
    if (len / paging.PAGE_SIZE > 0xFFFF_FFFF) return ENOMEM;

    // 4. Get current task
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = task.getTask(cur_idx) orelse return -1;
    if (cur.page_table_phys == 0) return EINVAL; // kernel thread — not allowed

    // H1: file-backed regions carry the prot metadata the demand-fault path
    // synthesises page permissions from. Partial overlaps split regions, so
    // count the extra slots BEFORE touching page tables — failing after the
    // PTE rewrite would leave metadata and page tables describing different
    // permissions.
    const len_pages = (len + paging.PAGE_SIZE - 1) / paging.PAGE_SIZE;
    var slots_needed: u32 = 0;
    const free_slots: u32 = @intCast(cur.mmap_regions.len - @popCount(cur.mmap_active_bm));
    var bits = cur.mmap_active_bm;
    while (bits != 0) {
        const i: usize = @intCast(@ctz(bits));
        bits &= bits - 1;
        const r = &cur.mmap_regions[i];
        if (r.file_kind == 0) continue; // anonymous faults never read prot
        slots_needed += filemap.planProtUpdate(r.base, r.num_pages, addr, len_pages).slots_needed;
    }
    if (slots_needed > free_slots) return ENOMEM;

    // 5. Preflight every resource which commit can consume. Partial huge
    // demotions need one PT page each; writable COW entries need one data page
    // each. The fixed arrays and caps make ENOMEM happen before mutation.
    const end = addr + len;
    var huge_demotions: u32 = 0;
    var block = addr & ~(paging.PAGE_2MB - 1);
    while (block < end) : (block += paging.PAGE_2MB) {
        const pde = paging.getPdEntry(cur.page_table_phys, block) orelse continue;
        if (!pde.huge_page) continue;
        if (!(block >= addr and block + paging.PAGE_2MB <= end)) huge_demotions += 1;
    }

    var cow_copies: u32 = 0;
    if ((prot & PROT_WRITE) != 0) {
        var scan = addr;
        while (scan < end) : (scan += paging.PAGE_SIZE) {
            const pte = paging.getProtectionPageEntry(cur.page_table_phys, scan) orelse continue;
            const raw: u64 = @bitCast(pte.*);
            if (cow_pte.isCow(raw) and pmm.getRefCount(raw & paging.ADDR_MASK) > 1) cow_copies += 1;
        }
    }
    if (!policy.supported(huge_demotions, cow_copies)) return ENOMEM;

    var reserved_pt: [policy.MAX_PARTIAL_HUGE_DEMOTIONS]u64 = undefined;
    var reserved_data: [policy.MAX_COW_COPIES]u64 = undefined;
    var got_pt: u32 = 0;
    var got_data: u32 = 0;
    while (got_pt < huge_demotions) : (got_pt += 1) {
        reserved_pt[got_pt] = pmm.allocPageNoReclaim() orelse {
            pmm.freePageBatch(reserved_pt[0..got_pt]);
            return ENOMEM;
        };
        const bytes: [*]u8 = @ptrFromInt(hhdm.physToVirt(reserved_pt[got_pt]));
        @memset(bytes[0..paging.PAGE_SIZE], 0);
    }
    while (got_data < cow_copies) : (got_data += 1) {
        reserved_data[got_data] = pmm.allocPageNoReclaim() orelse {
            pmm.freePageBatch(reserved_pt[0..got_pt]);
            pmm.freePageBatch(reserved_data[0..got_data]);
            return ENOMEM;
        };
    }

    // 6. Commit page-table and PTE changes. No operation below allocates or
    // returns an error after the reservations have succeeded.
    _ = huge_impl.protectHugeOverlapsReserved(
        cur.page_table_phys,
        addr,
        end,
        prot,
        reserved_pt[0..huge_demotions],
    );

    var v = addr;
    var data_used: u32 = 0;

    while (v < end) : (v += paging.PAGE_SIZE) {
        const pte_opt = paging.getProtectionPageEntry(cur.page_table_phys, v);
        const pte = pte_opt orelse continue; // skip unmapped pages

        if (prot == PROT_NONE) {
            // Clear present bit — keep physical frame so we can restore later.
            // On x86_64, when present=0 the CPU ignores all other bits except
            // the physical frame field, which we preserve for re-mprotect.
            pte.present = false;
        } else {
            pte.present = true;
            // PROT_EXEC → clear no_execute; no EXEC → set no_execute
            pte.no_execute = (prot & PROT_EXEC) == 0;
            // Always user-accessible for user-space mprotect
            pte.user = true;

            if ((prot & PROT_WRITE) != 0) {
                // Granting write on a COW-shared frame (bit 9) must unshare it
                // first — setting writable directly would silently make every
                // sharee writable. Same allocate-copy-decRef sequence as
                // handleCowFault in idt.zig.
                const pte_val: u64 = @bitCast(pte.*);
                if (cow_pte.isCow(pte_val)) {
                    const frame = pte_val & paging.ADDR_MASK;
                    if (pmm.getRefCount(frame) > 1) {
                        const new_phys = reserved_data[data_used];
                        data_used += 1;
                        const src: [*]const u8 = @ptrFromInt(hhdm.physToVirt(frame));
                        const dst: [*]u8 = @ptrFromInt(hhdm.physToVirt(new_phys));
                        @memcpy(dst[0..paging.PAGE_SIZE], src[0..paging.PAGE_SIZE]);
                        pte.* = @bitCast((pte_val & ~paging.ADDR_MASK & ~cow_pte.COW) | new_phys);
                        _ = pmm.decRef(frame);
                    } else {
                        // Sole owner — just drop the COW marker.
                        pte.* = @bitCast(pte_val & ~cow_pte.COW);
                    }
                }
                pte.writable = true;
            } else {
                pte.writable = false;
            }
        }
    }

    // M8-6: one ranged TLB shootdown covers the whole rewrite — cheaper than
    // per-page invlpg on the local CPU and crucial for cross-CPU correctness
    // when the same address space is mapped on another core (CLONE_VM thread).
    const num_pages: u32 = @intCast((end - addr) / paging.PAGE_SIZE);
    tlb.shootdownRange(addr, num_pages, cur.page_table_phys);

    pmm.freePageBatch(reserved_data[data_used..got_data]);

    // H1: update the file regions' prot metadata (splitting on partial
    // overlaps) so later demand faults grant the new permissions.
    const new_prot: u8 = @intCast(prot & 7);
    for (&cur.mmap_regions) |*r| {
        if (!r.active or r.file_kind == 0) continue;
        const plan = filemap.planProtUpdate(r.base, r.num_pages, addr, len_pages);
        if (plan.overlap == .none) continue;
        const old_prot = r.prot;
        const old_offset = r.file_offset;

        // Granting WRITE on a MAP_SHARED ext2/fat32 region: pages already
        // faulted read-only now become writable without another fault, so
        // their cache frames must be marked dirty now — the fault-time
        // markDirty never runs for them. Misses are no-ops (not yet cached).
        if ((new_prot & 2) != 0 and r.shared and
            (r.file_kind == @intFromEnum(filemap.FsKind.ext2) or
                r.file_kind == @intFromEnum(filemap.FsKind.fat32)))
        {
            const page_cache = @import("../fs/page_cache.zig");
            const mid_first_file_page = (old_offset + plan.head_pages * paging.PAGE_SIZE) / paging.PAGE_SIZE;
            for (0..plan.mid_pages) |p| {
                page_cache.markDirty(r.inode_id, filemap.mmapCacheKey(mid_first_file_page + p));
            }
        }

        switch (plan.overlap) {
            .none => unreachable,
            .cover => r.prot = new_prot,
            .head => {
                // Protected head: r becomes the new-prot head piece; insert
                // the tail piece keeping the old prot.
                insertRegionPiece(cur, r.base + plan.mid_pages * paging.PAGE_SIZE, plan.tail_pages, r, old_prot, filemap.advanceFileOffset(old_offset, plan.mid_pages));
                r.num_pages = plan.mid_pages;
                r.prot = new_prot;
            },
            .tail => {
                // r keeps the old-prot head; insert the protected tail piece.
                insertRegionPiece(cur, r.base + plan.head_pages * paging.PAGE_SIZE, plan.mid_pages, r, new_prot, filemap.advanceFileOffset(old_offset, plan.head_pages));
                r.num_pages = plan.head_pages;
            },
            .middle => {
                // r keeps the old-prot head; insert the protected middle and
                // the old-prot tail (tail first: insertRegionPiece cannot
                // fail, so order is only about slot fill).
                insertRegionPiece(cur, addr + plan.mid_pages * paging.PAGE_SIZE, plan.tail_pages, r, old_prot, filemap.advanceFileOffset(old_offset, plan.head_pages + plan.mid_pages));
                insertRegionPiece(cur, addr, plan.mid_pages, r, new_prot, filemap.advanceFileOffset(old_offset, plan.head_pages));
                r.num_pages = plan.head_pages;
            },
        }
    }

    return 0;
}
