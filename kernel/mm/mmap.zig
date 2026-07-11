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
pub fn unmapRange(task: *task_mod.Task, base: u64, num_pages: u64) void {
    if (num_pages == 0) return;
    for (0..num_pages) |p| {
        const virt = base + p * 4096;
        if (paging_mod.unmapPage(task.page_table_phys, virt)) |phys| {
            pmm_mod.freePage(phys);
        }
    }
    // M8-6: broadcast a single ranged shootdown for the whole unmap. The
    // per-page `unmapPage` already invalidated the local TLB; this call also
    // hits remote CPUs that may share the same page table (CLONE_VM threads).
    tlb_mod.shootdownRange(base, @intCast(num_pages));
}

/// Track an mmap region in the task's mmap_regions table.
pub fn trackMmapRegion(task: *task_mod.Task, base: u64, num_pages: u64) void {
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
    // Table full — region leaked (will be freed on process exit via destroyUserSpace)
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

fn rangeAvailable(task: *task_mod.Task, base: u64, num_pages: u64, ignore_base: ?u64) bool {
    const stack_base = user_space.USER_STACK_TOP - user_space.PAGE_SIZE;
    if (num_pages == 0) return false;
    if (base % user_space.PAGE_SIZE != 0) return false;
    if (base >= stack_base) return false;
    if (num_pages > (stack_base - base) / user_space.PAGE_SIZE) return false;

    for (task.mmap_regions) |r| {
        if (!r.active) continue;
        if (ignore_base != null and r.base == ignore_base.?) continue;
        if (rangesOverlap(base, num_pages, r.base, r.num_pages)) return false;
    }
    return true;
}

fn findFreeMmapRange(task: *task_mod.Task, num_pages: u64, ignore_base: u64) ?u64 {
    const page = user_space.PAGE_SIZE;
    const stack_base = user_space.USER_STACK_TOP - page;
    var base = (task.brk_current + page - 1) / page * page;
    if (base < user_space.USER_CODE_BASE + page) base = user_space.USER_CODE_BASE + page;

    while (base < stack_base and num_pages <= (stack_base - base) / page) : (base += page) {
        if (rangeAvailable(task, base, num_pages, ignore_base)) return base;
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
        unmapRange(cur, base, num_pages);
        untrackMmapRange(cur, base, num_pages);
    } else if (addr_hint != 0 and addr_hint >= user_space.PAGE_SIZE) {
        base = (addr_hint + user_space.PAGE_SIZE - 1) / user_space.PAGE_SIZE * user_space.PAGE_SIZE;
    } else {
        base = (cur.brk_current + user_space.PAGE_SIZE - 1) / user_space.PAGE_SIZE * user_space.PAGE_SIZE;
    }

    // Validate: don't overflow into kernel space or stack
    const stack_base = user_space.USER_STACK_TOP - user_space.PAGE_SIZE;
    if (base + num_pages * user_space.PAGE_SIZE >= stack_base) return -12; // ENOMEM

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

    // Advance brk if we allocated above it (non-fixed mappings)
    if (!is_fixed) {
        const end = base + num_pages * user_space.PAGE_SIZE;
        if (end > cur.brk_current) {
            cur.brk_current = end;
        }
    }
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
