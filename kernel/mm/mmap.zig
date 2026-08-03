// kernel/mm/mmap.zig — Memory mapping subsystem (mmap/munmap)
//
// Implements mmap() and munmap() syscalls: anonymous and file-backed mappings,
// MAP_FIXED support, region tracking/untracking.

const sched = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const user_space = @import("user_space.zig");
const pmm_mod = @import("pmm.zig");
const hhdm_mod = @import("hhdm.zig");
const paging_mod = @import("../arch/arch.zig").paging;
const tlb_mod = @import("../arch/arch.zig").tlb;
const filemap = @import("filemap.zig");
const vfs = @import("../fs/vfs.zig");
const ext2 = @import("../fs/ext2.zig");
const tmpfs = @import("../fs/tmpfs.zig");
const huge_user = @import("huge_user.zig");
const huge_impl = @import("huge_user_impl.zig");

/// I1: compile-time gate for user 2MiB huge pages on anonymous mappings.
/// Set to false to disable the feature entirely (the demote paths stay —
/// they are no-ops when no huge page was ever created). Effective only on
/// x86_64 (huge_impl.enable); other backends never create huge pages.
pub const huge_user_enable: bool = true;
const huge_on = huge_user_enable and huge_impl.enable;

const MAP_ANONYMOUS: u64 = 0x20;
const MAP_PRIVATE: u64 = 0x2;
const MAP_SHARED: u64 = 0x1;
const MAP_FIXED: u64 = 0x10;
const MAP_POPULATE: u64 = 0x8000;
const MREMAP_MAYMOVE: u32 = 0x1;
const MREMAP_FIXED: u32 = 0x2;

/// Unmap pages in a range and free physical memory.
/// TLB safety: collects physical frames during unmapping, performs the
/// synchronous shootdown, then frees frames — ensures no remote CPU can
/// reference a freed frame via stale TLB entries.
pub fn unmapRange(task: *task_mod.Task, base: u64, num_pages: u64) void {
    if (num_pages == 0) return;

    // I1: free huge blocks fully inside the range directly, and demote
    // partially-overlapped ones first — the 4K pass below cannot touch huge
    // entries (unmapPage refuses them).
    huge_impl.prescanHuge(task.page_table_phys, base, num_pages);

    // Bounded collection using 128-element stack buffer. Flush when either the
    // buffer is full OR the virtual span would exceed MAX_BATCH_SPAN pages.
    // This prevents both stack overflow and inefficient sparse-range shootdowns.
    const MAX_BATCH_SPAN: u32 = 32; // Stay below TLB flush threshold for efficiency
    var free_buf: [128]u64 = undefined;
    var free_count: u32 = 0;
    var batch_first_virt: u64 = 0;
    var batch_last_virt: u64 = 0;

    // Internal flush helper: shoots down the collected range, then frees.
    const flushBatch = struct {
        fn call(
            first_virt: u64,
            last_virt: u64,
            buf: []const u64,
            target_cr3: u64,
        ) void {
            const span_pages = @as(u32, @intCast((last_virt - first_virt) / 4096 + 1));
            tlb_mod.shootdownRange(first_virt, span_pages, target_cr3);
            pmm_mod.freePageBatch(buf);
        }
    }.call;

    for (0..num_pages) |p| {
        const virt = base + p * 4096;
        if (paging_mod.unmapPage(task.page_table_phys, virt)) |phys| {
            // Start new batch if this is the first frame.
            if (free_count == 0) {
                batch_first_virt = virt;
                batch_last_virt = virt;
            } else {
                // Check if adding this frame would exceed the span limit.
                const span_pages = (virt - batch_first_virt) / 4096 + 1;
                if (span_pages > MAX_BATCH_SPAN) {
                    // Flush current batch before starting a new one.
                    flushBatch(batch_first_virt, batch_last_virt, free_buf[0..free_count], task.page_table_phys);
                    free_count = 0;
                    batch_first_virt = virt;
                    batch_last_virt = virt;
                } else {
                    batch_last_virt = virt;
                }
            }

            free_buf[free_count] = phys;
            free_count += 1;

            // Flush when buffer is full.
            if (free_count == 128) {
                flushBatch(batch_first_virt, batch_last_virt, free_buf[0..128], task.page_table_phys);
                free_count = 0;
            }
        }
    }

    // Final batch: shootdown the remaining pages, then free.
    if (free_count > 0) {
        flushBatch(batch_first_virt, batch_last_virt, free_buf[0..free_count], task.page_table_phys);
    }
}

/// Whether adding a disjoint range can be represented without dropping metadata.
/// `anonymous` because only anonymous regions merge with neighbours (G2):
/// a file region always needs a free slot of its own.
fn canTrackMmapRegion(task: *task_mod.Task, base: u64, num_pages: u64, anonymous: bool) bool {
    for (task.mmap_regions) |r| {
        if (!r.active) return true;
        if (anonymous and r.file_kind == 0 and
            (r.base + r.num_pages * user_space.PAGE_SIZE == base or
            base + num_pages * user_space.PAGE_SIZE == r.base)) return true;
    }
    return false;
}

/// Check the metadata capacity for MAP_FIXED before destroying old mappings.
fn canTrackReplacement(task: *task_mod.Task, base: u64, num_pages: u64) bool {
    const page = user_space.PAGE_SIZE;
    const end = base + num_pages * page;
    var pieces: usize = 0;
    for (task.mmap_regions) |r| {
        if (!r.active) continue;
        const r_end = r.base + r.num_pages * page;
        if (r.base >= end or r_end <= base) {
            pieces += 1;
            continue;
        }
        if (r.base < base) {
            pieces += 1;
        }
        if (r_end > end) {
            pieces += 1;
        }
    }
    // This is intentionally conservative: trackMmapRegion may merge an
    // adjacent piece, but reserving the unmerged upper bound keeps MAP_FIXED
    // from destroying mappings before discovering an unrepresentable layout.
    return pieces + 1 <= task.mmap_regions.len;
}

/// File-backing metadata recorded for a file region at track time (G2).
pub const RegionFileMeta = struct {
    kind: filemap.FsKind,
    /// H1: MAP_SHARED — faults map the backing frame writable (no COW) and
    /// ext2/fat32 regions flush dirty cache pages on release.
    shared: bool,
    prot: u8,
    offset: u64,
    size: u64,
    idx: u32,
    data: u64,
    inode: u64,
};

/// Track an mmap region in the task's mmap_regions table.
/// `meta` is null for anonymous regions. File regions never merge with
/// neighbours — a merge would silently drop one side's backing metadata.
/// I1: regions with huge blocks never merge either way — a merge would
/// break the invariant that a region's huge blocks are its FIRST
/// huge_pages*512 pages.
fn trackMmapRegion(task: *task_mod.Task, base: u64, num_pages: u64, meta: ?RegionFileMeta, huge_pages: u32) void {
    const new_kind: u8 = if (meta) |m| @intFromEnum(m.kind) else 0;
    // Try to merge with an adjacent existing region (anonymous only)
    if (meta == null and huge_pages == 0) {
        for (&task.mmap_regions) |*r| {
            if (!r.active or r.huge_pages != 0 or !filemap.canMergeAnon(r.file_kind, new_kind)) continue;
            if (r.base + r.num_pages * 4096 == base) {
                r.num_pages += num_pages;
                return;
            }
            if (base + num_pages * 4096 == r.base) {
                r.base = base;
                r.num_pages += num_pages;
                return;
            }
        }
    }
    // Find a free slot
    for (&task.mmap_regions) |*r| {
        if (!r.active) {
            r.* = .{ .base = base, .num_pages = num_pages, .active = true, .huge_pages = huge_pages };
            if (meta) |m| {
                r.file_kind = @intFromEnum(m.kind);
                r.shared = m.shared;
                r.prot = m.prot;
                r.file_offset = m.offset;
                r.file_size = m.size;
                r.file_idx = m.idx;
                r.file_data = m.data;
                r.inode_id = m.inode;
            }
            task.mmap_count += 1;
            return;
        }
    }
    unreachable; // Capacity is checked before any pages are mapped.
}

/// G2: drop the backing-store reference held by a file region piece.
/// ext2 regions retain their open slot at mmap time so faults survive
/// close(fd); every deactivation must balance that retain.
/// H1: a MAP_SHARED ext2/fat32 region flushes its dirty mmap-owned cache
/// pages first — after release nothing references the mapping, and the dirty
/// pages would sit in the cache (unevictable) until an unrelated syncAll.
fn releaseRegionBacking(r: *task_mod.MmapRegion) void {
    if (r.shared and
        (r.file_kind == @intFromEnum(filemap.FsKind.ext2) or
            r.file_kind == @intFromEnum(filemap.FsKind.fat32)))
    {
        vfs.flushMappedInode(r.inode_id);
    }
    if (r.file_kind == @intFromEnum(filemap.FsKind.ext2)) {
        ext2.closeFile(r.file_idx);
    }
    r.file_kind = 0;
    r.shared = false;
}

fn untrackMmapRange(task: *task_mod.Task, base: u64, num_pages: u64) void {
    const page = user_space.PAGE_SIZE;
    const end = base + num_pages * page;

    for (&task.mmap_regions) |*r| {
        if (!r.active) continue;
        const r_end = r.base + r.num_pages * page;
        if (r.base >= end or r_end <= base) continue; // no overlap

        // H1: unmapping any part of a MAP_SHARED ext2/fat32 region flushes
        // the inode's dirty mmap-owned cache pages first (cheap no-op when
        // clean) — the unmapped part's writes must not outlive the mapping
        // only in an unevictable dirty cache page.
        if (r.shared and
            (r.file_kind == @intFromEnum(filemap.FsKind.ext2) or
                r.file_kind == @intFromEnum(filemap.FsKind.fat32)))
        {
            vfs.flushMappedInode(r.inode_id);
        }

        if (base <= r.base and end >= r_end) {
            releaseRegionBacking(r);
            r.active = false;
            if (task.mmap_count > 0) task.mmap_count -= 1;
        } else if (base <= r.base and end < r_end) {
            const removed = (end - r.base) / page;
            r.base = end;
            r.num_pages -= removed;
            // I1: huge blocks fully below the new base were freed by
            // unmapRange; a straddling block was demoted first. The
            // huge-first invariant only survives a block-aligned cut —
            // otherwise drop the count (page-table-driven paths still
            // handle any huge block that remains mapped).
            if (r.huge_pages != 0) {
                if (removed % huge_user.HUGE_PAGES == 0) {
                    r.huge_pages -|= @intCast(@min(r.huge_pages, removed / huge_user.HUGE_PAGES));
                } else {
                    r.huge_pages = 0;
                }
            }
            // G2: the base moved up, so the file offset tracked at the base
            // advances with it (the piece keeps its backing reference).
            r.file_offset = filemap.advanceFileOffset(r.file_offset, removed);
        } else if (base > r.base and end >= r_end) {
            r.num_pages = (base - r.base) / page;
            // I1: keep only the huge blocks fully below the cut.
            r.huge_pages = @intCast(@min(r.huge_pages, r.num_pages / huge_user.HUGE_PAGES));
        } else {
            const tail_base = end;
            const tail_pages = (r_end - end) / page;
            const tail_offset = filemap.advanceFileOffset(r.file_offset, (end - r.base) / page);
            // I1: the head keeps the huge blocks fully below `base`; the
            // tail keeps the ones fully past `end`, but only a block-aligned
            // cut preserves the tail's huge-first invariant.
            const head_huge: u32 = @intCast(@min(r.huge_pages, ((base - r.base) / page) / huge_user.HUGE_PAGES));
            const end_off_pages = (end - r.base) / page;
            const tail_huge: u32 = if (end_off_pages % huge_user.HUGE_PAGES == 0)
                r.huge_pages -| @as(u32, @intCast(@min(r.huge_pages, end_off_pages / huge_user.HUGE_PAGES)))
            else
                0;
            r.num_pages = (base - r.base) / page;
            r.huge_pages = head_huge;
            for (&task.mmap_regions) |*r2| {
                if (!r2.active) {
                    r2.* = .{
                        .base = tail_base,
                        .num_pages = tail_pages,
                        .active = true,
                        .locked = r.locked,
                        .huge_pages = tail_huge,
                        // G2: the tail piece keeps the same backing; it needs
                        // its own reference so either piece can be unmapped
                        // independently.
                        .file_kind = r.file_kind,
                        .shared = r.shared,
                        .prot = r.prot,
                        .file_offset = tail_offset,
                        .file_size = r.file_size,
                        .file_idx = r.file_idx,
                        .file_data = r.file_data,
                        .inode_id = r.inode_id,
                    };
                    if (r.file_kind == @intFromEnum(filemap.FsKind.ext2)) {
                        ext2.retainFile(r.file_idx);
                    }
                    task.mmap_count += 1;
                    break;
                }
            }
        }
    }
}

/// G2: release every file-region backing reference held by a task and clear
/// its region table. Called by the task teardown paths (reap/exec) right
/// before destroyUserSpace, which only walks page tables and never consults
/// the region metadata.
pub fn releaseFileRefs(task: *task_mod.Task) void {
    for (&task.mmap_regions) |*r| {
        if (!r.active) continue;
        releaseRegionBacking(r);
        r.active = false;
    }
    task.mmap_count = 0;
}

fn rangesOverlap(a_base: u64, a_pages: u64, b_base: u64, b_pages: u64) bool {
    const page = user_space.PAGE_SIZE;
    const a_end = a_base + a_pages * page;
    const b_end = b_base + b_pages * page;
    return a_base < b_end and b_base < a_end;
}

/// Offset of the first mapped page in the range, or null when every page is
/// free. Catches everything the mmap_regions table does not know about — the
/// loaded image, the stack, break pages — so a placement search cannot land on a
/// live mapping, and lets the search skip straight past a conflict.
fn firstMappedPage(task: *task_mod.Task, base: u64, num_pages: u64) ?u64 {
    for (0..num_pages) |p| {
        if (paging_mod.isPageMapped(task.page_table_phys, base + p * user_space.PAGE_SIZE)) {
            return p;
        }
    }
    return null;
}

fn pagesFree(task: *task_mod.Task, base: u64, num_pages: u64) bool {
    return firstMappedPage(task, base, num_pages) == null;
}

fn rangeAvailable(task: *task_mod.Task, base: u64, num_pages: u64, ignore_base: ?u64) bool {
    if (num_pages == 0) return false;
    if (base % user_space.PAGE_SIZE != 0) return false;
    if (base < user_space.PAGE_SIZE) return false;
    // Bound against the top of the user half rather than the stack: ELF images
    // load above USER_STACK_TOP, so a stack-relative ceiling declared every
    // address they use unavailable.
    if (base >= user_space.USER_ADDR_MAX) return false;
    if (num_pages > (user_space.USER_ADDR_MAX - base) / user_space.PAGE_SIZE) return false;

    for (task.mmap_regions) |r| {
        if (!r.active) continue;
        if (ignore_base != null and r.base == ignore_base.?) continue;
        if (rangesOverlap(base, num_pages, r.base, r.num_pages)) return false;
    }
    return true;
}

/// Scan the mmap window for `num_pages` free pages, starting at `start`.
/// `ignore_base` exempts one tracked region (mremap moving a mapping).
fn findFreeRangeFrom(task: *task_mod.Task, start: u64, num_pages: u64, ignore_base: ?u64) ?u64 {
    const page = user_space.PAGE_SIZE;
    if (num_pages == 0) return null;

    var base = if (start < user_space.USER_MMAP_BASE) user_space.USER_MMAP_BASE else start;
    base = (base + page - 1) / page * page;

    while (base < user_space.USER_MMAP_MAX and num_pages <= (user_space.USER_MMAP_MAX - base) / page) {
        if (firstMappedPage(task, base, num_pages)) |p| {
            base += (p + 1) * page; // resume past the page in the way
            continue;
        }
        if (rangeAvailable(task, base, num_pages, ignore_base)) return base;
        base += page;
    }
    return null;
}

fn findFreeMmapRange(task: *task_mod.Task, num_pages: u64, ignore_base: u64) ?u64 {
    return findFreeRangeFrom(task, user_space.USER_MMAP_BASE, num_pages, ignore_base);
}

/// I1: 2MiB-aligned variant of findFreeRangeFrom — huge-block mappings need
/// an aligned base. Returns null when no aligned slot fits; the caller then
/// falls back to the generic (4K-granular) search and a 4K-only mapping.
fn findFreeRangeAligned2M(task: *task_mod.Task, start: u64, num_pages: u64) ?u64 {
    const page = user_space.PAGE_SIZE;
    const huge = huge_user.HUGE_BYTES;
    if (num_pages == 0) return null;

    var base = if (start < user_space.USER_MMAP_BASE) user_space.USER_MMAP_BASE else start;
    base = (base + huge - 1) / huge * huge;

    while (base < user_space.USER_MMAP_MAX and num_pages <= (user_space.USER_MMAP_MAX - base) / page) {
        if (firstMappedPage(task, base, num_pages)) |p| {
            base = (base + (p + 1) * page + huge - 1) / huge * huge; // next aligned slot past the conflict
            continue;
        }
        if (rangeAvailable(task, base, num_pages, null)) return base;
        base += huge;
    }
    return null;
}

fn allocZeroedPage() ?u64 {
    const phys = pmm_mod.allocPage() orelse return null;
    const page_ptr: [*]u8 = @ptrFromInt(hhdm_mod.physToVirt(phys));
    @memset(page_ptr[0..user_space.PAGE_SIZE], 0);
    return phys;
}

fn mapZeroedPage(task: *task_mod.Task, virt: u64, flags: paging_mod.MapFlags) bool {
    const phys = allocZeroedPage() orelse return false;
    paging_mod.mapPage(task.page_table_phys, virt, phys, flags) catch {
        pmm_mod.freePage(phys);
        return false;
    };
    return true;
}

fn moveMapping(task: *task_mod.Task, region: *task_mod.MmapRegion, new_base: u64, old_pages: u64, new_pages: u64) i64 {
    const page = user_space.PAGE_SIZE;
    const default_flags = paging_mod.MapFlags{ .writable = true, .user = true, .no_execute = true };
    const old_base = region.base;
    if (rangesOverlap(old_base, old_pages, new_base, new_pages)) return -22;
    var mapped: u64 = 0;

    // I1: the 4K copy loop below cannot read huge PDEs (getPageEntry
    // refuses them and would substitute zero pages, silently losing the
    // block's contents) — demote every huge block in the source range.
    huge_impl.demoteRange(task.page_table_phys, old_base, old_pages) catch return -12;
    region.huge_pages = 0;

    while (mapped < new_pages) : (mapped += 1) {
        const dst_virt = new_base + mapped * page;
        if (mapped < old_pages) {
            const src_virt = old_base + mapped * page;
            if (paging_mod.getPageEntry(task.page_table_phys, src_virt)) |src_pte| {
                const src_pte_val: u64 = @bitCast(src_pte.*);
                const src_phys = src_pte.getPhysAddr();
                const new_phys = pmm_mod.allocPage() orelse {
                    unmapRange(task, new_base, mapped);
                    return -12;
                };
                const src: [*]const u8 = @ptrFromInt(hhdm_mod.physToVirt(src_phys));
                const dst: [*]u8 = @ptrFromInt(hhdm_mod.physToVirt(new_phys));
                @memcpy(dst[0..page], src[0..page]);

                const new_pte_val = (src_pte_val & ~paging_mod.ADDR_MASK) | new_phys;
                paging_mod.mapPage(task.page_table_phys, dst_virt, new_phys, .{
                    .writable = (new_pte_val & paging_mod.WRITABLE) != 0,
                    .user = (new_pte_val & paging_mod.USER) != 0,
                    .no_execute = (new_pte_val & (1 << 63)) != 0,
                    .global = false,
                }) catch {
                    pmm_mod.freePage(new_phys);
                    unmapRange(task, new_base, mapped);
                    return -12;
                };
                paging_mod.setPageEntryRaw(task.page_table_phys, dst_virt, new_pte_val);
                paging_mod.invlpg(dst_virt);
            } else if (!mapZeroedPage(task, dst_virt, default_flags)) {
                unmapRange(task, new_base, mapped);
                return -12;
            }
        } else if (!mapZeroedPage(task, dst_virt, default_flags)) {
            unmapRange(task, new_base, mapped);
            return -12;
        }
    }

    unmapRange(task, old_base, old_pages);
    region.base = new_base;
    region.num_pages = new_pages;
    return @bitCast(new_base);
}

fn moveOrNoMem(task: *task_mod.Task, region: *task_mod.MmapRegion, old_pages: u64, new_pages: u64, mflags: u32, new_addr_hint: u64) i64 {
    if ((mflags & MREMAP_MAYMOVE) == 0) return -12; // ENOMEM
    // Moving a sub-range would strand the region tail: the bookkeeping tracks
    // a single base/num_pages pair, so refuse old_sizes that do not cover the
    // whole tracked region.
    if (old_pages != region.num_pages) return -22; // EINVAL
    const new_base = if ((mflags & MREMAP_FIXED) != 0)
        new_addr_hint
    else
        (findFreeMmapRange(task, new_pages, region.base) orelse return -12);
    if (rangesOverlap(region.base, old_pages, new_base, new_pages)) return -22; // EINVAL
    if (!rangeAvailable(task, new_base, new_pages, region.base)) return -12;
    // rangeAvailable only consults the tracked region list; MREMAP_FIXED may
    // target untracked live pages (image, stack, brk) and mapPage overwrites a
    // live PTE silently, so gate on the actual page tables too.
    if (!pagesFree(task, new_base, new_pages)) return -12; // ENOMEM
    return moveMapping(task, region, new_base, old_pages, new_pages);
}

/// Core mmap implementation. Returns mapped base address or -errno.
pub fn mmap(addr_hint: u64, length: u64, prot: u64, flags: u64, fd: i64, offset: u64) i64 {
    _ = MAP_POPULATE;

    if (flags & MAP_PRIVATE == 0 and flags & MAP_SHARED == 0) return -22; // EINVAL
    if (length == 0) return -22; // EINVAL

    const is_anonymous = (flags & MAP_ANONYMOUS != 0) or (fd == -1);
    const is_fixed = (flags & MAP_FIXED != 0);

    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    // ─── G2: file-backed validation and backing metadata ───
    // File mappings are demand-paged: nothing is mapped here, the region
    // metadata below drives the page-fault path (handleFileFault in idt.zig).
    var meta: ?RegionFileMeta = null;
    if (!is_anonymous) {
        // Linux: the offset must be page-aligned.
        if (!filemap.offsetValid(offset)) return -22; // EINVAL
        if (fd < 0 or fd >= vfs.MAX_FDS) return -9; // EBADF
        const desc = &cur.fd_table.fds[@intCast(fd)];
        const kind: filemap.FsKind = switch (desc.fd_type) {
            .ramdisk_file => .ramdisk,
            .tmpfs_file => .tmpfs,
            .ext2_file => .ext2,
            .fat32_file => .fat32,
            // Pipes, sockets and special files are not mappable.
            else => return -19, // ENODEV
        };
        // The fd must be readable (status_flags & 3 == 1 is O_WRONLY).
        if ((desc.status_flags & 0x03) == 1) return -9; // EBADF
        const shared = (flags & MAP_SHARED) != 0;
        if (shared and (prot & 2) != 0) {
            // The ramdisk is immutable Limine module memory — writable shared
            // mappings have nowhere to write back to. Checked first: ramdisk
            // files cannot be opened writable, so the EACCES branch below
            // would make EROFS unreachable.
            if (kind == .ramdisk) return -30; // EROFS
            // Linux: MAP_SHARED|PROT_WRITE on a read-only fd → EACCES.
            if ((desc.status_flags & 0x03) == 0) return -13; // EACCES
        }

        var m = RegionFileMeta{
            .kind = kind,
            .shared = shared,
            .prot = @intCast(prot & 7),
            .offset = offset,
            .size = desc.file_size,
            .idx = 0,
            .data = 0,
            .inode = 0,
        };
        switch (kind) {
            .ramdisk => {
                // Kernel-virtual pointer to the immutable blob contents.
                m.data = desc.file_data;
            },
            .tmpfs => {
                m.idx = desc.tmpfs_idx;
                // ctime doubles as a generation tag: after unlink+close the
                // entry is freed and a recycled slot gets a fresh ctime, so a
                // stale region can never be served the wrong file's pages.
                m.data = tmpfs.tmpfsGetCtime(@intCast(desc.tmpfs_idx));
            },
            .ext2 => {
                m.idx = desc.ext2_file_idx;
                m.inode = desc.inode_id;
                // Refresh the size like the read path does — another fd may
                // have grown the file through a different ext2 open slot.
                m.size = ext2.refreshSize(desc.ext2_file_idx);
                // NOTE: the open slot is retained only once the mapping is
                // known to succeed (see below), so early ENOMEM returns do
                // not leak the reference.
            },
            .fat32 => {
                // fat32 open slots are never freed on close (vfs.close only
                // invalidates readahead), so the index stays valid for the
                // life of the mapping without a retain.
                m.idx = desc.fat32_file_idx;
                m.inode = desc.inode_id;
            },
            .none => unreachable,
        }
        meta = m;
    }

    // v53.2: reject overflow-inducing length values
    if (length > 0xFFFFFFFF_FFFFF000) return -12; // ENOMEM
    const num_pages = (length + user_space.PAGE_SIZE - 1) / user_space.PAGE_SIZE;

    // Determine base address
    var base: u64 = undefined;
    if (is_fixed and addr_hint != 0) {
        base = addr_hint / user_space.PAGE_SIZE * user_space.PAGE_SIZE;
        if (base < user_space.PAGE_SIZE) return -22; // EINVAL
        // A kernel-half base would underflow USER_ADDR_MAX - base below
        // (panic in safe builds) or unmap kernel pages in ReleaseFast.
        if (base >= user_space.USER_ADDR_MAX) return -22; // EINVAL
        if (num_pages > (user_space.USER_ADDR_MAX - base) / user_space.PAGE_SIZE) return -12; // ENOMEM
        if (!canTrackReplacement(cur, base, num_pages)) return -12;
        // MAP_FIXED replaces whatever is there, so drop the old pages first.
        unmapRange(cur, base, num_pages);
        untrackMmapRange(cur, base, num_pages);
    } else {
        // Without MAP_FIXED the address is advisory. Honour it only when the
        // range is free: mapPage overwrites a live PTE silently, so taking the
        // hint unconditionally stranded the old frames and tore down mappings
        // the caller was still using.
        const hint = if (addr_hint >= user_space.PAGE_SIZE)
            (addr_hint + user_space.PAGE_SIZE - 1) / user_space.PAGE_SIZE * user_space.PAGE_SIZE
        else
            0;

        if (hint != 0 and hint < user_space.USER_ADDR_MAX and
            num_pages <= (user_space.USER_ADDR_MAX - hint) / user_space.PAGE_SIZE and
            rangeAvailable(cur, hint, num_pages, null) and pagesFree(cur, hint, num_pages))
        {
            base = hint;
        } else {
            // I1: a huge-eligible anonymous mapping tries a 2MiB-aligned
            // slot first — the generic search steps by 4K and would almost
            // never pick one. Falls back to a 4K-only mapping when no
            // aligned slot fits.
            base = if (meta == null and huge_on and num_pages >= huge_user.HUGE_PAGES)
                (findFreeRangeAligned2M(cur, hint, num_pages) orelse
                    findFreeRangeFrom(cur, hint, num_pages, null) orelse
                    findFreeRangeFrom(cur, user_space.USER_MMAP_BASE, num_pages, null) orelse
                    return -12) // ENOMEM
            else
                (findFreeRangeFrom(cur, hint, num_pages, null) orelse
                    findFreeRangeFrom(cur, user_space.USER_MMAP_BASE, num_pages, null) orelse
                    return -12); // ENOMEM
        }
    }

    // I1: huge blocks are only attempted for anonymous mappings whose final
    // base is 2MiB-aligned with at least one full block. A huge region never
    // merges with neighbours (the huge-first invariant), so the capacity
    // check must not count a merge as available space.
    const huge_attempt = meta == null and huge_on and
        huge_user.eligible(base, num_pages);

    if (!is_fixed and !canTrackMmapRegion(cur, base, num_pages, meta == null and !huge_attempt)) return -12;

    var huge_count: u32 = 0;
    if (meta == null) {
        // Anonymous: allocate and map zeroed pages eagerly (unchanged).
        const writable = (prot & 2) != 0;
        const executable = (prot & 4) != 0;
        const map_flags = paging_mod.MapFlags{
            .writable = writable,
            .user = true,
            .no_execute = !executable,
            .global = false, // user mappings must never be global (PCID)
        };

        var mapped: u64 = 0;
        var huge_ok = huge_attempt;
        while (mapped < num_pages) {
            // I1: map the region's leading full 2MiB blocks as huge pages.
            // Once a block falls back to 4K the rest of the region stays 4K,
            // so a region's huge blocks are always its first pages.
            if (huge_ok and num_pages - mapped >= huge_user.HUGE_PAGES) {
                const virt = base + mapped * user_space.PAGE_SIZE;
                if (huge_impl.mapHugeBlock(cur.page_table_phys, virt, map_flags)) {
                    huge_count += 1;
                    mapped += huge_user.HUGE_PAGES;
                    continue;
                }
                huge_ok = false;
            }
            const virt = base + mapped * user_space.PAGE_SIZE;
            const phys = pmm_mod.allocPage() orelse {
                unmapRange(cur, base, mapped);
                return -12;
            };
            // Zero the page (security: don't leak kernel data)
            const page_ptr: [*]u8 = @ptrFromInt(hhdm_mod.physToVirt(phys));
            @memset(page_ptr[0..user_space.PAGE_SIZE], 0);

            paging_mod.mapPage(cur.page_table_phys, virt, phys, map_flags) catch {
                pmm_mod.freePage(phys);
                unmapRange(cur, base, mapped);
                return -12;
            };
            mapped += 1;
        }
    } else if (meta.?.kind == .ext2) {
        // The mapping is known to succeed: retain the ext2 open slot so the
        // fault path can read after close(fd). Balanced by
        // releaseRegionBacking on untrack and releaseFileRefs on exit/exec.
        ext2.retainFile(meta.?.idx);
    }

    // Track the mapping region for munmap (records backing metadata for G2).
    trackMmapRegion(cur, base, num_pages, meta, huge_count);

    // The break is deliberately left alone. Dragging it up to cover mmap
    // placements made brk(2) report a break spanning memory it does not own, and
    // a later shrink would then hand those mmap pages back to the allocator.
    return @bitCast(base);
}

/// Core munmap implementation. Returns 0 or -errno.
pub fn munmap(addr: u64, length: u64) i64 {
    if (length == 0) return -22; // EINVAL

    const PAGE: u64 = 4096;
    // v53.3: reject kernel-space addresses and overflow
    const USER_SPACE_MAX = 0x0000_8000_0000_0000;
    if (addr >= USER_SPACE_MAX) return -22; // EINVAL — kernel address
    if (length > USER_SPACE_MAX) return -22; // EINVAL — length overflow
    if (addr + length > USER_SPACE_MAX) return -22; // EINVAL — range overflow

    const base = addr / PAGE * PAGE;
    const end = (addr + length + PAGE - 1) / PAGE * PAGE;
    const num_pages = (end - base) / PAGE;

    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    // Unmap pages and free physical memory
    unmapRange(cur, base, num_pages);
    untrackMmapRange(cur, base, num_pages);

    return 0;
}

/// Core mremap implementation. Returns new base address or -errno.
/// v53.5: properly operate on page tables (map new pages, unmap shrunk pages).
pub fn mremap(old_addr: u64, old_size: u64, new_size: u64, mflags: u32, new_addr_hint: u64) i64 {
    const PAGE: u64 = 4096;
    if (old_size == 0 and new_size == 0) return -22; // EINVAL
    if ((mflags & ~(MREMAP_MAYMOVE | MREMAP_FIXED)) != 0) return -22; // EINVAL
    if ((mflags & MREMAP_FIXED) != 0 and (mflags & MREMAP_MAYMOVE) == 0) return -22; // EINVAL
    if ((mflags & MREMAP_FIXED) != 0 and new_addr_hint % PAGE != 0) return -22; // EINVAL

    // Same cap as mmap(): larger sizes wrap the page-count computation,
    // which would process a grow as a shrink.
    if (old_size > 0xFFFFFFFF_FFFFF000 or new_size > 0xFFFFFFFF_FFFFF000) return -12; // ENOMEM

    const old_pages = (old_size + PAGE - 1) / PAGE;
    const new_pages = (new_size + PAGE - 1) / PAGE;
    if (new_pages == 0) return -22; // EINVAL

    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    // Find the mapping region
    for (&cur.mmap_regions) |*r| {
        if (r.active and r.base == old_addr and r.num_pages >= old_pages) {
            if (new_pages <= old_pages) {
                // Shrink: unmap only the validated old range, not the whole
                // tracked region — a tail beyond old_size stays mapped.
                // untrackMmapRange splits the region bookkeeping to match.
                if (new_pages < old_pages) {
                    unmapRange(cur, old_addr + new_pages * PAGE, old_pages - new_pages);
                    untrackMmapRange(cur, old_addr + new_pages * PAGE, old_pages - new_pages);
                }
                return @bitCast(old_addr);
            }
            // H1: in-place growth of a file-backed region is allowed. The
            // grown tail is deliberately left unmapped — it demand-faults
            // through planFault like the rest of the region: pages inside
            // the recorded file size are served from the backing store,
            // pages wholly past it SIGSEGV (Linux allows growing a file
            // mapping past EOF and faults on access). Moving a file region
            // stays unsupported: moveMapping would substitute freshly
            // allocated private pages for never-faulted shared/zero-copy
            // frames, silently unsharing a MAP_SHARED mapping.
            if (r.file_kind != 0) {
                const g = filemap.fileGrowRange(old_addr, old_pages, new_pages);
                var file_can_grow = true;
                for (&cur.mmap_regions) |r2| {
                    if (r2.active and r2.base != old_addr) {
                        const r2_end = r2.base + r2.num_pages * PAGE;
                        if (r2.base < g.start + g.pages * PAGE and r2_end > g.start) {
                            file_can_grow = false;
                            break;
                        }
                    }
                }
                if (!file_can_grow) return -12; // ENOMEM
                // The region list does not know about untracked live pages
                // (image, stack, brk) — gate on the actual page tables too.
                if (!pagesFree(cur, g.start, g.pages)) return -12; // ENOMEM
                r.num_pages = new_pages;
                return @bitCast(old_addr);
            }
            if ((mflags & MREMAP_FIXED) != 0) return moveOrNoMem(cur, r, old_pages, new_pages, mflags, new_addr_hint);

            // Grow: map new pages in the virtual range [old_addr + old_pages*PAGE, ...)
            // Check that the virtual range is available (no other region overlaps)
            const grow_base = old_addr + old_pages * PAGE;
            const grow_pages = new_pages - old_pages;
            var can_grow = true;
            for (&cur.mmap_regions) |r2| {
                if (r2.active and r2.base != old_addr) {
                    const r2_end = r2.base + r2.num_pages * PAGE;
                    if (r2.base < grow_base + grow_pages * PAGE and r2_end > grow_base) {
                        can_grow = false;
                        break;
                    }
                }
            }
            if (!can_grow) return moveOrNoMem(cur, r, old_pages, new_pages, mflags, new_addr_hint);
            // The region list does not know about untracked live pages
            // (loaded image, stack, brk) — gate on the actual page tables so
            // mapPage never silently overwrites a live PTE.
            if (!pagesFree(cur, grow_base, grow_pages))
                return moveOrNoMem(cur, r, old_pages, new_pages, mflags, new_addr_hint);

            // Map new pages
            for (0..grow_pages) |p| {
                const virt = grow_base + p * PAGE;
                const phys = pmm_mod.allocPage() orelse {
                    // Rollback: unmap any pages we already mapped in this grow
                    unmapRange(cur, grow_base, p);
                    return -12; // ENOMEM
                };
                const map_flags = paging_mod.MapFlags{
                    .writable = true,
                    .user = true,
                    .no_execute = true, // v53.6: W^X — grown pages non-executable by default
                };
                paging_mod.mapPage(cur.page_table_phys, virt, phys, map_flags) catch {
                    pmm_mod.freePage(phys);
                    unmapRange(cur, grow_base, p);
                    return -12; // ENOMEM
                };
                // Zero-fill new page (security: prevent data leaks)
                const dst: [*]u8 = @ptrFromInt(hhdm_mod.physToVirt(phys));
                @memset(dst[0..PAGE], 0);
            }
            r.num_pages = new_pages;
            return @bitCast(old_addr);
        } else if (r.active and r.base == old_addr and r.num_pages < old_pages) {
            return -22; // EINVAL: old_size exceeds mapping
        }
    }

    for (&cur.mmap_regions) |*r| {
        if (!r.active or r.base != old_addr) continue;
        // G2: see the grow/move guard in the main loop above.
        if (r.file_kind != 0) return -12; // ENOMEM
        return moveOrNoMem(cur, r, old_pages, new_pages, mflags, new_addr_hint);
    }
    return -22; // EINVAL: old_addr not found
}
