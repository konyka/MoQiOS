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

pub const PROT_NONE: u64 = 0;
pub const PROT_READ: u64 = 1;
pub const PROT_WRITE: u64 = 2;
pub const PROT_EXEC: u64 = 4;

const errno = @import("../lib/errno.zig");
const EINVAL = errno.EINVAL;
const ENOMEM = errno.ENOMEM;
const EACCES = errno.EACCES;

/// sysMprotect(addr, len, prot) → 0 on success, negative errno on failure.
pub fn sysMprotect(addr: u64, len: u64, prot: u64) i64 {
    // 1. Validate addr is page-aligned
    if (addr % paging.PAGE_SIZE != 0) return EINVAL;
    if (len == 0) return EINVAL;

    // 2. Validate prot — valid bits are 0..7 (NONE|READ|WRITE|EXEC)
    if (prot & ~@as(u64, 7) != 0) return EINVAL;

    // 3. Get current task
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = task.getTask(cur_idx) orelse return -1;
    if (cur.page_table_phys == 0) return EINVAL; // kernel thread — not allowed

    // 4. Walk page tables for [addr, addr+len) and modify PTE permissions
    var v = addr;
    const end = addr + len;

    // Guard against overflow
    if (end < addr) return EINVAL;

    while (v < end) : (v += paging.PAGE_SIZE) {
        const pte_opt = paging.getPageEntry(cur.page_table_phys, v);
        const pte = pte_opt orelse continue; // skip unmapped pages

        if (prot == PROT_NONE) {
            // Clear present bit — keep physical frame so we can restore later.
            // On x86_64, when present=0 the CPU ignores all other bits except
            // the physical frame field, which we preserve for re-mprotect.
            pte.present = false;
        } else {
            pte.present = true;
            pte.writable = (prot & PROT_WRITE) != 0;
            // PROT_EXEC → clear no_execute; no EXEC → set no_execute
            pte.no_execute = (prot & PROT_EXEC) == 0;
            // Always user-accessible for user-space mprotect
            pte.user = true;
        }
    }

    // M8-6: one ranged TLB shootdown covers the whole rewrite — cheaper than
    // per-page invlpg on the local CPU and crucial for cross-CPU correctness
    // when the same address space is mapped on another core (CLONE_VM thread).
    const num_pages: u32 = @intCast((end - addr) / paging.PAGE_SIZE);
    tlb.shootdownRange(addr, num_pages);

    return 0;
}
