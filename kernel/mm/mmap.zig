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
        ) void {
            const span_pages = @as(u32, @intCast((last_virt - first_virt) / 4096 + 1));
            tlb_mod.shootdownRange(first_virt, span_pages);
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
                    flushBatch(batch_first_virt, batch_last_virt, free_buf[0..free_count]);
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
                flushBatch(batch_first_virt, batch_last_virt, free_buf[0..128]);
                free_count = 0;
            }
        }
    }

    // Final batch: shootdown the remaining pages, then free.
    if (free_count > 0) {
        flushBatch(batch_first_virt, batch_last_virt, free_buf[0..free_count]);
    }
}

/// Whether adding a disjoint range can be represented without dropping metadata.
fn canTrackMmapRegion(task: *task_mod.Task, base: u64, num_pages: u64) bool {
    for (task.mmap_regions) |r| {
        if (!r.active) return true;
        if (r.base + r.num_pages * user_space.PAGE_SIZE == base or
            base + num_pages * user_space.PAGE_SIZE == r.base) return true;
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

/// Track an mmap region in the task's mmap_regions table.
fn trackMmapRegion(task: *task_mod.Task, base: u64, num_pages: u64) void {
    // Try to merge with an adjacent existing region
    for (&task.mmap_regions) |*r| {
        if (r.active and r.base + r.num_pages * 4096 == base) {
            r.num_pages += num_pages;
            return;
        }
        if (r.active and base + num_pages * 4096 == r.base) {
            r.base = base;
            r.num_pages += num_pages;
            return;
        }
    }
    // Find a free slot
    for (&task.mmap_regions) |*r| {
        if (!r.active) {
            r.* = .{ .base = base, .num_pages = num_pages, .active = true };
            task.mmap_count += 1;
            return;
        }
    }
    unreachable; // Capacity is checked before any pages are mapped.
}

fn untrackMmapRange(task: *task_mod.Task, base: u64, num_pages: u64) void {
    const page = user_space.PAGE_SIZE;
    const end = base + num_pages * page;

    for (&task.mmap_regions) |*r| {
        if (!r.active) continue;
        const r_end = r.base + r.num_pages * page;
        if (r.base >= end or r_end <= base) continue; // no overlap

        if (base <= r.base and end >= r_end) {
            r.active = false;
            if (task.mmap_count > 0) task.mmap_count -= 1;
        } else if (base <= r.base and end < r_end) {
            const removed = (end - r.base) / page;
            r.base = end;
            r.num_pages -= removed;
        } else if (base > r.base and end >= r_end) {
            r.num_pages = (base - r.base) / page;
        } else {
            const tail_base = end;
            const tail_pages = (r_end - end) / page;
            r.num_pages = (base - r.base) / page;
            for (&task.mmap_regions) |*r2| {
                if (!r2.active) {
                    r2.* = .{
                        .base = tail_base,
                        .num_pages = tail_pages,
                        .active = true,
                        .locked = r.locked,
                    };
                    task.mmap_count += 1;
                    break;
                }
            }
        }
    }
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
    const new_base = if ((mflags & MREMAP_FIXED) != 0)
        new_addr_hint
    else
        (findFreeMmapRange(task, new_pages, region.base) orelse return -12);
    if (rangesOverlap(region.base, old_pages, new_base, new_pages)) return -22; // EINVAL
    if (!rangeAvailable(task, new_base, new_pages, region.base)) return -12;
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

    // v53.2: reject overflow-inducing length values
    if (length > 0xFFFFFFFF_FFFFF000) return -12; // ENOMEM
    const num_pages = (length + user_space.PAGE_SIZE - 1) / user_space.PAGE_SIZE;

    // Determine base address
    var base: u64 = undefined;
    if (is_fixed and addr_hint != 0) {
        base = addr_hint / user_space.PAGE_SIZE * user_space.PAGE_SIZE;
        if (base < user_space.PAGE_SIZE) return -22; // EINVAL
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
            base = findFreeRangeFrom(cur, hint, num_pages, null) orelse
                findFreeRangeFrom(cur, user_space.USER_MMAP_BASE, num_pages, null) orelse
                return -12; // ENOMEM
        }
    }

    if (!is_fixed and !canTrackMmapRegion(cur, base, num_pages)) return -12;

    // Allocate and map pages
    const writable = (prot & 2) != 0;
    const executable = (prot & 4) != 0;
    const map_flags = paging_mod.MapFlags{
        .writable = writable,
        .user = true,
        .no_execute = !executable,
        .global = false,
    };

    var mapped: u64 = 0;
    while (mapped < num_pages) : (mapped += 1) {
        const virt = base + mapped * user_space.PAGE_SIZE;
        const phys = pmm_mod.allocPage() orelse {
            unmapRange(cur, base, mapped);
            return -12;
        };
        // Zero the page (security: don't leak kernel data)
        const page_ptr: [*]u8 = @ptrFromInt(hhdm_mod.physToVirt(phys));
        @memset(page_ptr[0..user_space.PAGE_SIZE], 0);

        // For file-backed mappings, read file content into the page
        if (!is_anonymous) {
            const file_offset = offset + mapped * user_space.PAGE_SIZE;
            const remaining: u64 = if (offset + length > file_offset) (offset + length - file_offset) else 0;
            if (remaining > 0) {
                const to_read: usize = @intCast(@min(remaining, user_space.PAGE_SIZE));
                const fd_u32: u32 = @intCast(fd);
                if (fd_u32 < cur.fd_table.fds.len) {
                    const saved_off = cur.fd_table.fds[fd_u32].offset;
                    cur.fd_table.fds[fd_u32].offset = file_offset;
                    _ = cur.fd_table.read(fd_u32, page_ptr, to_read);
                    cur.fd_table.fds[fd_u32].offset = saved_off;
                }
            }
        }

        paging_mod.mapPage(cur.page_table_phys, virt, phys, map_flags) catch {
            pmm_mod.freePage(phys);
            unmapRange(cur, base, mapped);
            return -12;
        };
    }

    // Track the mapping region for munmap
    trackMmapRegion(cur, base, num_pages);

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

    const old_pages = (old_size + PAGE - 1) / PAGE;
    const new_pages = (new_size + PAGE - 1) / PAGE;
    if (new_pages == 0) return -22; // EINVAL

    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    // Find the mapping region
    for (&cur.mmap_regions) |*r| {
        if (r.active and r.base == old_addr and r.num_pages >= old_pages) {
            if (new_pages <= old_pages) {
                // Shrink: unmap pages beyond new_size
                if (new_pages < r.num_pages) {
                    unmapRange(cur, old_addr + new_pages * PAGE, r.num_pages - new_pages);
                }
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
        return moveOrNoMem(cur, r, old_pages, new_pages, mflags, new_addr_hint);
    }
    return -22; // EINVAL: old_addr not found
}
