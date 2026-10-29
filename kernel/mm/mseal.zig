//! mseal(2): seal a mapped range against munmap/mremap/mprotect and
//! MAP_FIXED replacement for the life of the address space.

const policy = @import("mseal_policy.zig");
const sched = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const mm_mod = @import("mm.zig");
const user_space = @import("user_space.zig");
const paging = @import("../arch/x86_64/paging.zig");

pub fn sysMseal(addr: u64, len: u64, flags: u64) i64 {
    const v = policy.validate(addr, len, flags);
    if (v != 0 or len == 0) return v;
    const rounded = policy.roundLen(len);
    if (addr >= user_space.USER_ADDR_MAX or rounded > user_space.USER_ADDR_MAX - addr) return -12; // ENOMEM
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;
    const mm = cur.mm orelse return -1;
    var vm_guard = mm_mod.Mm.beginVmMutation(cur.mm, @ptrCast(cur)) catch return -35;
    defer vm_guard.release();
    // Every page must be part of a mapping (Linux: ENOMEM for a hole).
    var off: u64 = 0;
    while (off < rounded) : (off += user_space.PAGE_SIZE) {
        const page = addr + off;
        if (!paging.isPageOccupied(cur.page_table_phys, page) and
            !@import("mmap.zig").hasMmapOverlap(cur, page, 1)) return -12;
    }
    if (!mm.seals.add(addr, rounded)) return -12;
    return 0;
}
