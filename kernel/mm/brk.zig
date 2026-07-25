/// brk — program break (heap) management.
///
/// Extracted from syscall_entry.zig (v18.9).
const sched_mod = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const user_space = @import("../mm/user_space.zig");
const pmm_mod = @import("../mm/pmm.zig");
const hhdm_mod = @import("../mm/hhdm.zig");
const mmap_mod = @import("mmap.zig");
const paging_mod = @import("../arch/arch.zig").paging;

const PAGE = user_space.PAGE_SIZE;

/// First page index at or above `addr`.
fn pageCeil(addr: u64) u64 {
    return (addr + PAGE - 1) / PAGE;
}

/// Release pages [from_page, to_page) back to the allocator.
fn releasePages(task: *task_mod.Task, from_page: u64, to_page: u64) void {
    if (to_page <= from_page) return;
    mmap_mod.unmapRange(task, from_page * PAGE, to_page - from_page);
}

/// brk(addr) -> new break address, or the unchanged break on failure.
///
/// addr == 0 reports the current break. The break may move anywhere in
/// [brk_start, USER_HEAP_MAX] as long as the pages it claims are free.
pub fn brk(addr: u64) i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return 0;
    const cur = task_mod.getTask(cur_idx) orelse return 0;

    if (addr == 0) return @bitCast(cur.brk_current);

    // No loader has established a heap for this task.
    if (cur.brk_start == 0 or cur.brk_current == 0) return @bitCast(cur.brk_current);

    // The break may not retreat below where the loader left it — those pages
    // hold the loaded image — nor climb past its ceiling. The previous check
    // required the break to sit under USER_STACK_TOP, but ELF images load above
    // the stack, so it rejected every legal break and left brk frozen at its
    // initial value for every C user program.
    if (addr < cur.brk_start) return @bitCast(cur.brk_current);

    // Flat binaries load below the stack and grow the heap up toward it, so they
    // keep the original stack-relative ceiling. ELF images sit above the stack
    // and grow into the heap window instead.
    const ceiling = if (cur.brk_start < user_space.USER_STACK_TOP)
        user_space.USER_STACK_TOP - PAGE
    else
        user_space.USER_HEAP_MAX;
    if (addr > ceiling) return @bitCast(cur.brk_current);

    const old_page = pageCeil(cur.brk_current);
    const new_page = pageCeil(addr);

    if (new_page > old_page) {
        // Refuse to grow across pages that are already mapped. mapPage
        // overwrites a live PTE without complaint, which would strand the old
        // frame and hand the heap a region the process is still using
        // elsewhere (a MAP_FIXED mapping, or the stack in the flat layout).
        for (old_page..new_page) |p| {
            if (paging_mod.isPageMapped(cur.page_table_phys, p * PAGE)) {
                return @bitCast(cur.brk_current);
            }
        }

        const flags = paging_mod.MapFlags{
            .writable = true,
            .user = true,
            .no_execute = true,
            .global = false,
        };

        var p = old_page;
        while (p < new_page) : (p += 1) {
            const virt = p * PAGE;
            const phys = pmm_mod.allocPage() orelse {
                releasePages(cur, old_page, p);
                return @bitCast(cur.brk_current);
            };
            // The physical allocator returns frames as-is, so clear the page
            // before it becomes reachable: otherwise the heap would expose
            // whatever the previous owner left behind.
            const page_ptr: [*]u8 = @ptrFromInt(hhdm_mod.physToVirt(phys));
            @memset(page_ptr[0..PAGE], 0);

            paging_mod.mapPage(cur.page_table_phys, virt, phys, flags) catch {
                pmm_mod.freePage(phys);
                releasePages(cur, old_page, p);
                return @bitCast(cur.brk_current);
            };
        }
    } else if (new_page < old_page) {
        // Give the released pages back. The growth loop used to run
        // `old_page..new_page` unconditionally, so a shrinking break reversed
        // the range and panicked the kernel computing its length.
        releasePages(cur, new_page, old_page);
    }

    cur.brk_current = addr;
    return @bitCast(addr);
}
