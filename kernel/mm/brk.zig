/// brk — program break (heap) management.
///
/// Extracted from syscall_entry.zig (v18.9).
const sched_mod = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const user_space = @import("../mm/user_space.zig");
const pmm_mod = @import("../mm/pmm.zig");
const paging_mod = @import("../arch/x86_64/paging.zig");

/// brk(addr) -> new break address.
/// addr == 0 returns current break. addr below code or above stack returns current break.
pub fn brk(addr: u64) i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return 0;
    const cur = task_mod.getTask(cur_idx) orelse return 0;

    if (addr == 0) return @bitCast(cur.brk_current);

    // Validate: addr must be above code region and below user stack
    const code_end = user_space.USER_CODE_BASE + paging_mod.PAGE_SIZE;
    if (addr < code_end) return @bitCast(cur.brk_current);
    const stack_base = user_space.USER_STACK_TOP - user_space.PAGE_SIZE;
    if (addr >= stack_base) return @bitCast(cur.brk_current);

    // Allocate pages between current brk and new addr
    const old_page = (cur.brk_current + user_space.PAGE_SIZE - 1) / user_space.PAGE_SIZE;
    const new_page = (addr + user_space.PAGE_SIZE - 1) / user_space.PAGE_SIZE;

    for (old_page..new_page) |p| {
        const virt = p * user_space.PAGE_SIZE;
        const phys = pmm_mod.allocPage() orelse return @bitCast(cur.brk_current); // OOM
        const flags = paging_mod.MapFlags{
            .writable = true,
            .user = true,
            .no_execute = true,
            .global = false,
        };
        paging_mod.mapPage(cur.page_table_phys, virt, phys, flags) catch {
            pmm_mod.freePage(phys);
            return @bitCast(cur.brk_current);
        };
    }

    cur.brk_current = addr;
    return @bitCast(addr);
}
