// kernel/mm/mmap.zig — Memory mapping subsystem (mmap/munmap)
//
// Implements mmap() and munmap() syscalls: anonymous and file-backed mappings,
// MAP_FIXED support, region tracking/untracking.

const sched = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const user_space = @import("user_space.zig");
const pmm_mod = @import("pmm.zig");
const hhdm_mod = @import("hhdm.zig");
const paging_mod = @import("../arch/x86_64/paging.zig");

const MAP_ANONYMOUS: u64 = 0x20;
const MAP_PRIVATE: u64 = 0x2;
const MAP_SHARED: u64 = 0x1;
const MAP_FIXED: u64 = 0x10;
const MAP_POPULATE: u64 = 0x8000;

/// Unmap pages in a range and free physical memory.
pub fn unmapRange(task: *task_mod.Task, base: u64, num_pages: u64) void {
    for (0..num_pages) |p| {
        const virt = base + p * 4096;
        if (paging_mod.unmapPage(task.page_table_phys, virt)) |phys| {
            pmm_mod.freePage(phys);
        }
    }
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

/// Core mmap implementation. Returns mapped base address or -errno.
pub fn mmap(addr_hint: u64, length: u64, prot: u64, flags: u64, fd: i64, offset: u64) i64 {
    _ = MAP_POPULATE;

    if (flags & MAP_PRIVATE == 0 and flags & MAP_SHARED == 0) return -22; // EINVAL
    if (length == 0) return -22; // EINVAL

    const is_anonymous = (flags & MAP_ANONYMOUS != 0) or (fd == -1);
    const is_fixed = (flags & MAP_FIXED != 0);

    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    const num_pages = (length + user_space.PAGE_SIZE - 1) / user_space.PAGE_SIZE;

    // Determine base address
    var base: u64 = undefined;
    if (is_fixed and addr_hint != 0) {
        base = addr_hint / user_space.PAGE_SIZE * user_space.PAGE_SIZE;
        unmapRange(cur, base, num_pages);
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
    const base = addr / PAGE * PAGE;
    const end = (addr + length + PAGE - 1) / PAGE * PAGE;
    const num_pages = (end - base) / PAGE;

    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    // Unmap pages and free physical memory
    unmapRange(cur, base, num_pages);

    // Remove or split tracking regions that overlap [base, end)
    for (&cur.mmap_regions) |*r| {
        if (!r.active) continue;
        const r_end = r.base + r.num_pages * PAGE;
        if (r.base >= end or r_end <= base) continue; // no overlap

        if (base <= r.base and end >= r_end) {
            // Fully covered — remove
            r.active = false;
            if (cur.mmap_count > 0) cur.mmap_count -= 1;
        } else if (base <= r.base and end < r_end) {
            // Overlaps start — shrink from front
            const removed = (end - r.base) / PAGE;
            r.base = end;
            r.num_pages -= removed;
        } else if (base > r.base and end >= r_end) {
            // Overlaps end — shrink from back
            r.num_pages = (base - r.base) / PAGE;
        } else {
            // Split: middle removed, leaving head and tail
            const tail_base = end;
            const tail_pages = (r_end - end) / PAGE;
            r.num_pages = (base - r.base) / PAGE;
            // Try to store tail in a free slot
            for (&cur.mmap_regions) |*r2| {
                if (!r2.active) {
                    r2.* = .{ .base = tail_base, .num_pages = tail_pages, .active = true };
                    cur.mmap_count += 1;
                    break;
                }
            }
        }
    }

    return 0;
}
