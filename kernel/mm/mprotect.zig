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
const mm_mod = @import("mm.zig");
const ledger = @import("mprotect_ledger.zig");
const huge_user = @import("huge_user.zig");
const rlimit_mod = @import("../proc/rlimit.zig");

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
    for (cur.vma().regions) |*slot| {
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
                .may_write = proto.may_write,
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
            cur.vma().count += 1;
            const idx = (@intFromPtr(slot) - @intFromPtr(&cur.vma().regions[0])) / @sizeOf(task.MmapRegion);
            cur.vma().active_bm |= @as(u64, 1) << @intCast(idx);
            return;
        }
    }
    unreachable; // slot capacity is checked before any PTE is touched
}

/// Pages of [r_base, +r_pages) that fall inside [addr, +len_pages).
fn overlapPages(r_base: u64, r_pages: u64, addr: u64, len_pages: u64) u64 {
    const page = paging.PAGE_SIZE;
    const lo = @max(r_base, addr);
    const hi = @min(r_base + r_pages * page, addr + len_pages * page);
    return if (hi > lo) (hi - lo) / page else 0;
}

/// Anonymous regions: record the new protection on the part of each region the range covers (splitting a region the range only partly covers) and
/// move the RLIMIT_DATA ledger by the pages that became or stopped being writable private data. Region slots were reserved by the preflight, so this
/// cannot fail. File regions are handled by the metadata pass that follows.
fn commitAnonymousProt(cur: *task.Task, addr: u64, len_pages: u64, new_prot: u8) void {
    const page = paging.PAGE_SIZE;
    var bits = cur.vma().active_bm;
    while (bits != 0) {
        const i: usize = @intCast(@ctz(bits));
        bits &= bits - 1;
        const r = &cur.vma().regions[i];
        if (!r.active or r.file_kind != 0 or r.no_free) continue;
        const plan = filemap.planProtUpdate(r.base, r.num_pages, addr, len_pages);
        if (plan.overlap == .none) continue;
        const d = ledger.delta(r.prot, new_prot, r.shared, plan.mid_pages);
        cur.dataUsed().* = ledger.apply(cur.dataUsed().*, d, page);
        if (r.prot == new_prot) continue;
        const old_prot = r.prot;
        switch (plan.overlap) {
            .none => unreachable,
            .cover => r.prot = new_prot,
            .head => {
                insertAnonPiece(cur, r.base + plan.mid_pages * page, plan.tail_pages, r, old_prot);
                r.num_pages = plan.mid_pages;
                r.prot = new_prot;
                r.huge_pages = @intCast(@min(r.huge_pages, r.num_pages / huge_user.HUGE_PAGES));
            },
            .tail => {
                insertAnonPiece(cur, r.base + plan.head_pages * page, plan.mid_pages, r, new_prot);
                r.num_pages = plan.head_pages;
                r.huge_pages = @intCast(@min(r.huge_pages, r.num_pages / huge_user.HUGE_PAGES));
            },
            .middle => {
                insertAnonPiece(cur, addr + plan.mid_pages * page, plan.tail_pages, r, old_prot);
                insertAnonPiece(cur, addr, plan.mid_pages, r, new_prot);
                r.num_pages = plan.head_pages;
                r.huge_pages = @intCast(@min(r.huge_pages, r.num_pages / huge_user.HUGE_PAGES));
            },
        }
    }
}

/// A region cloned from `proto` with another protection, covering [base, +pages). Anonymous, so there is no file backing to retain; a split piece
/// never keeps a huge block count (the page-table-driven paths handle any huge block that stays mapped).
fn insertAnonPiece(cur: *task.Task, base: u64, num_pages: u64, proto: *const task.MmapRegion, prot: u8) void {
    for (cur.vma().regions, 0..) |*slot, idx| {
        if (slot.active) continue;
        slot.* = .{
            .base = base,
            .num_pages = num_pages,
            .active = true,
            .locked = proto.locked,
            .shared = proto.shared,
            .may_write = proto.may_write,
            .prot = prot,
        };
        cur.vma().count += 1;
        cur.vma().active_bm |= @as(u64, 1) << @intCast(idx);
        return;
    }
    unreachable; // the preflight reserved the slots
}

/// sysMprotect(addr, len, prot) → 0 on success, negative errno on failure.
pub fn sysMprotect(addr: u64, len: u64, prot: u64) i64 {
    // 1-2. Alignment, zero length (a successful no-op) and PROT bits, in Linux's order.
    switch (policy.early(addr, len, prot)) {
        .err => |e| return e,
        .noop => return 0,
        .proceed => {},
    }

    // 3. Reject kernel-half ranges — kernel stacks and DMA pages share PML4
    // entries 256-511, so flipping U/S+writable there must not be possible.
    // Mirrors the munmap check in mmap.zig.
    // Linux: a range that leaves user space (or wraps when rounded up) is ENOMEM, not EINVAL.
    if (addr >= user_space.USER_ADDR_MAX) return ENOMEM;
    if (len > user_space.USER_ADDR_MAX - addr) return ENOMEM;
    // The TLB shootdown API takes a u32 page count; reject larger requests
    // before any preflight work rather than allowing a truncating cast.
    const len_pages = policy.pageCount(len);
    if (len_pages > 0xFFFF_FFFF) return ENOMEM;

    // 4. Get current task
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = task.getTask(cur_idx) orelse return -1;
    if (cur.mm == null) return -1;
    if (cur.page_table_phys == 0) return EINVAL; // kernel thread — not allowed
    var vm_guard = mm_mod.Mm.beginVmMutation(cur.mm, @ptrCast(cur)) catch return -35;
    defer vm_guard.release();
    if (mm_mod.Mm.sealed(cur.mm, addr, len_pages * paging.PAGE_SIZE)) return -1; // EPERM: mseal

    // A hole in the range is ENOMEM on Linux. The pages that do exist are still
    // changed, so the result is reported after the commit.
    var mapped_pages: u64 = 0;
    {
        var pg: u64 = 0;
        while (pg < len_pages) : (pg += 1) {
            const va = addr + pg * paging.PAGE_SIZE;
            if (paging.isPageOccupied(cur.page_table_phys, va) or @import("mmap.zig").hasMmapOverlap(cur, va, 1)) {
                mapped_pages += 1;
                continue;
            }
            // Nothing here: jump over the stretch with no page table, but never past a tracked region.
            pg += (@import("mmap.zig").skipHole(cur, va, true) - va) / paging.PAGE_SIZE - 1;
        }
    }

    // SysV SHM pages belong to the segment, not to the address space: their
    // frames carry no PMM reference of their own and the attachment record
    // assumes the PTEs stay as shmat installed them. Changing their
    // protection would both bypass the segment's permission (a SHM_RDONLY
    // attach becoming writable) and, via PROT_NONE, strand the frames for a
    // double free at exit. Only shmat/shmdt may touch them (as munmap, mmap
    // and brk already enforce).
    if (@import("../ipc/sysv_shm.zig").overlapsAttachment(cur.page_table_phys, addr, len_pages)) return EINVAL;

    // H1: file-backed regions carry the prot metadata the demand-fault path
    // synthesises page permissions from. Partial overlaps split regions, so
    // count the extra slots BEFORE touching page tables — failing after the
    // PTE rewrite would leave metadata and page tables describing different
    // permissions.
    var slots_needed: u32 = 0;
    const new_prot_u8: u8 = @intCast(prot & 7);
    const free_slots: u32 = @intCast(cur.vma().regions.len - @popCount(cur.vma().active_bm));
    var bits = cur.vma().active_bm;
    while (bits != 0) {
        const i: usize = @intCast(@ctz(bits));
        bits &= bits - 1;
        const r = &cur.vma().regions[i];
        if (r.file_kind == 0) {
            // Anonymous faults never read prot, but the region records it for the RLIMIT_DATA ledger and for MAP_FIXED, so a partial overlap needs
            // the same split as a file region.
            if (!r.active or r.no_free) continue;
            const aplan = filemap.planProtUpdate(r.base, r.num_pages, addr, len_pages);
            if (aplan.overlap != .none and r.prot != new_prot_u8) slots_needed += aplan.slots_needed;
            continue;
        }
        const plan = filemap.planProtUpdate(r.base, r.num_pages, addr, len_pages);
        // A shared mapping of a read-only fd can never become writable:
        // the write would land in the file the caller cannot write.
        if (plan.overlap != .none and !policy.writeGrantAllowed(prot, r.shared, r.may_write)) return EACCES;
        // Nor can a shared mapping of a write-sealed memfd, whether the seal
        // came before or after the mapping (seals are read live).
        if (plan.overlap != .none and r.file_kind == @intFromEnum(filemap.FsKind.tmpfs)) {
            const tmpfs = @import("../fs/tmpfs.zig");
            const tidx: u16 = @intCast(r.file_idx);
            const seals = if (tmpfs.tmpfsGetCtime(tidx) == r.file_data) tmpfs.tmpfsGetSeals(tidx) orelse 0 else 0;
            if (!policy.writeGrantAllowed(prot, r.shared, @import("../fs/memfd_policy.zig").mapMayWrite(seals, r.shared, r.may_write))) return EACCES;
        }
        slots_needed += plan.slots_needed;
    }
    if (slots_needed > free_slots) return ENOMEM;

    // RLIMIT_DATA: the call may turn private pages writable (they join the data ledger) and others read-only (they leave it). The net growth has to
    // fit the limit before anything changes, as Linux's mprotect does.
    {
        var add_pages: u64 = 0;
        var release_pages: u64 = 0;
        var lb = cur.vma().active_bm;
        while (lb != 0) {
            const i: usize = @intCast(@ctz(lb));
            lb &= lb - 1;
            const r = &cur.vma().regions[i];
            if (!r.active or r.no_free) continue;
            const overlap = overlapPages(r.base, r.num_pages, addr, len_pages);
            if (overlap == 0) continue;
            const d = ledger.delta(r.prot, new_prot_u8, r.shared, overlap);
            add_pages += d.add;
            release_pages += d.release;
        }
        if (!ledger.fits(cur.dataUsed().*, add_pages, release_pages, paging.PAGE_SIZE, cur.lim().data.cur, rlimit_mod.RLIM_INFINITY)) return ENOMEM;
    }

    // 5. Preflight every resource which commit can consume. Partial huge
    // demotions need one PT page each; writable COW entries need one data page
    // each. The fixed arrays and caps make ENOMEM happen before mutation.
    const end = addr + len;
    var huge_demotions: u32 = 0;
    var block = addr & ~(paging.PAGE_2MB - 1);
    while (block < end) : (block += paging.PAGE_2MB) {
        const pde = paging.getPdEntry(cur.page_table_phys, block) orelse {
            // No page directory here, so none of the next 1 GiB can hold a huge page.
            block = ((block | (1024 * 1024 * 1024 - 1)) + 1) - paging.PAGE_2MB;
            continue;
        };
        if (!pde.huge_page) continue;
        if (!(block >= addr and block + paging.PAGE_2MB <= end)) huge_demotions += 1;
    }

    var cow_copies: u32 = 0;
    if ((prot & PROT_WRITE) != 0) {
        var scan = addr;
        while (scan < end) : (scan += paging.PAGE_SIZE) {
            const pte = paging.getProtectionPageEntry(cur.page_table_phys, scan) orelse {
                scan = @import("mmap.zig").skipHole(cur, scan, false) - paging.PAGE_SIZE;
                continue;
            };
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
    const pt_used = huge_impl.protectHugeOverlapsReserved(
        cur.page_table_phys,
        addr,
        end,
        prot,
        reserved_pt[0..huge_demotions],
    );
    // A huge block straddling the range may already have been demoted, so
    // fewer reserved PT pages than `got_pt` can be consumed — free the rest
    // like the data-page leftover below.
    pmm.freePageBatch(reserved_pt[pt_used..got_pt]);

    var v = addr;
    var data_used: u32 = 0;

    while (v < end) : (v += paging.PAGE_SIZE) {
        const pte_opt = paging.getProtectionPageEntry(cur.page_table_phys, v);
        const pte = pte_opt orelse {
            // Skip unmapped pages, and jump over any stretch with no page table at all.
            v = @import("mmap.zig").skipHole(cur, v, false) - paging.PAGE_SIZE;
            continue;
        };

        // Swap entries (non-present + bit-11 marker; the frame is on disk):
        // the generic rewrite below would set present=1 on the swap slot and
        // leave the marker behind. Only the preserved permission
        // bits (writable at bit 2, NX at bit 63) may move — swap-in then
        // restores the NEW permissions (mprotect_policy.swapEntryUpdate,
        // host-tested; hello96 RED). PROT_NONE reservations (bit-10 marker)
        // are NOT swap entries and take the normal path below.
        if (policy.swapEntryUpdate(@bitCast(pte.*), prot)) |updated| {
            pte.* = @bitCast(updated);
            continue;
        }

        if (prot == PROT_NONE) {
            // Clear present bit — keep physical frame so we can restore later.
            // On x86_64, when present=0 the CPU ignores all other bits except
            // the physical frame field, which we preserve for re-mprotect.
            // Set the bit-10 reservation marker so fault paths can tell this
            // entry apart from a swap entry (bit 11) and SIGSEGV the access
            // instead of "swapping in" the frame number as a disk slot.
            // Only LIVE entries become reservations: a never-faulted page is
            // a zero entry, and marking it would fabricate an occupied
            // address (isPageOccupied) that holds no frame at all.
            if (@as(u64, @bitCast(pte.*)) != 0) pte.os_bits |= 0b010;
            pte.present = false;
        } else if (@as(u64, @bitCast(pte.*)) == 0) {
            // Never-faulted page (file-backed demand entry): no frame and no
            // reservation to re-permit. The first access demand-faults with
            // the region's prot (updated by the metadata pass below), so the
            // entry must stay zero — setting present here would map physical
            // frame 0 into user space.
            continue;
        } else {
            pte.present = true;
            pte.os_bits &= 0b101; // drop any PROT_NONE reservation marker
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
                        // The vm_guard does not cover fault-path COW/fork, so
                        // a concurrent fork may have bumped a sole-owned
                        // frame's refcount 1→2 since preflight — exhausting
                        // the reservation. Deferring leaves the COW bit set
                        // and the PTE non-writable: the next write faults and
                        // unshares via handleCowFault.
                        if (policy.cowCommitAction(got_data, data_used) == .defer_to_fault) continue;
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
    // Must be the ceil page count: a floor count under-covers the last page
    // of a non-page-aligned len (and zero pages skips the PCID generation
    // bump entirely), leaving a stale translation with the old permissions.
    const num_pages: u32 = @intCast(len_pages);
    tlb.shootdownRange(addr, num_pages, cur.page_table_phys);

    pmm.freePageBatch(reserved_data[data_used..got_data]);

    // H1: update the file regions' prot metadata (splitting on partial
    // overlaps) so later demand faults grant the new permissions.
    const new_prot: u8 = @intCast(prot & 7);
    commitAnonymousProt(cur, addr, len_pages, new_prot);
    @import("mmap.zig").coalesceAnonymousAround(cur, addr, len_pages);
    for (cur.vma().regions) |*r| {
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

    return policy.coverageErrno(len_pages, mapped_pages);
}
