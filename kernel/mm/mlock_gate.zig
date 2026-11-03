//! What mmap, brk and mremap ask before they create locked pages (MAP_LOCKED, mlockall(MCL_FUTURE), growing a
//! mapping whose tail is locked). The rules are in mlock_policy.zig; this file only reads the task's limit,
//! capability and lock table. Every caller holds the address space's vm_lock.

const policy = @import("mlock_policy.zig");
const task_mod = @import("../proc/task.zig");
const Mm = @import("mm.zig").Mm;
const rlimit = @import("../proc/rlimit.zig");

pub const RLIMIT_MEMLOCK: u32 = 8;
const EPERM: i64 = -1;
const ENOMEM: i64 = -12;
const EAGAIN: i64 = -11;

pub fn memlockLimit(task: *const task_mod.Task) u64 {
    const slot = rlimit.recordedSlot(RLIMIT_MEMLOCK) orelse return rlimit.RLIM_INFINITY;
    return task.lim().recorded.get(slot).cur;
}

fn verdict(g: policy.Gate) i64 {
    return switch (g) {
        .ok => 0,
        .eperm => EPERM,
        .eagain => EAGAIN,
    };
}

/// Before a mapping of `pages` pages at page `base_page` is made (a MAP_FIXED replacement included: Linux
/// does not credit the pages it replaces). 0, or -EPERM / -EAGAIN / -ENOMEM (the lock table has no slot for it).
pub fn mapGate(task: *const task_mod.Task, map_locked: bool, base_page: u64, pages: u64) i64 {
    const mm = task.mm orelse return 0;
    const future = Mm.futureLocking(task.mm);
    if (!map_locked and !future) return 0;
    const g = verdict(policy.mapGate(map_locked, future, memlockLimit(task), task.effective_caps.cap_ipc_lock, mm.locks.total(), pages));
    if (g != 0) return g;
    var probe = mm.locks;
    probe.releaseLossy(base_page, pages);
    if (!probe.canLock(base_page, pages)) return ENOMEM;
    return 0;
}

/// Whether a mapping whose last page is `last_page` has a locked tail (the part mremap would extend).
pub fn tailLocked(task: *const task_mod.Task, last_page: u64) bool {
    const mm = task.mm orelse return false;
    return mm.locks.contains(last_page);
}

/// Before a locked mapping grows by `add_pages`: 0 or -EAGAIN.
pub fn growGate(task: *const task_mod.Task, add_pages: u64) i64 {
    const mm = task.mm orelse return 0;
    return verdict(policy.growGate(true, memlockLimit(task), task.effective_caps.cap_ipc_lock, mm.locks.total(), add_pages));
}

/// Record [base_page, +pages) as locked once the mapping exists. The gate checked there was room, so this
/// cannot fail on a well-formed call; if it did, the pages stay unlocked (the safe direction).
pub fn recordLocked(task: *const task_mod.Task, base_page: u64, pages: u64) void {
    const mm = task.mm orelse return;
    _ = mm.locks.lock(base_page, pages);
}

/// brk growth under mlockall(MCL_FUTURE): the new heap pages are locked too.
pub fn recordIfFuture(task: *const task_mod.Task, base_page: u64, pages: u64) void {
    const mm = task.mm orelse return;
    if (Mm.futureLocking(task.mm)) _ = mm.locks.lock(base_page, pages);
}
