//! mlock(2) / munlock(2) / mlockall(2) / munlockall(2) on the current address space.
//!
//! Locked pages are recorded in `Mm.locks` (mlock_policy.zig). They are eagerly populated already for anonymous
//! mappings; what "locked" adds is: swap reclaim skips them, MADV_DONTNEED/MADV_FREE refuse them, and they are
//! charged against RLIMIT_MEMLOCK. mlockall(MCL_FUTURE) sets Mm.lock_future, which mmap, brk and mremap growth
//! consult through mlock_gate.zig.

const policy = @import("mlock_policy.zig");
const range_policy = @import("range_policy.zig");
const sched = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const mm_mod = @import("mm.zig");
const mmap_mod = @import("mmap.zig");
const gate = @import("mlock_gate.zig");

pub const RLIMIT_MEMLOCK: u32 = gate.RLIMIT_MEMLOCK;
const PAGE: u64 = 4096;

fn memlockLimit(task: *const task_mod.Task) u64 {
    return gate.memlockLimit(task);
}

/// mlock2(addr, len, flags) -> 0 or -errno. The flags (an unsigned int in the kernel's ABI, so only the low
/// 32 bits of the register count) are validated first, then it is mlock.
pub fn mlock2(addr: u64, len: u64, flags: u64) i64 {
    if (!policy.mlock2FlagsValid(@truncate(flags))) return -22;
    return mlock(addr, len);
}

/// mlock(addr, len) -> 0 or -errno. Linux order: privilege/limit gate (EPERM), the range (ENOMEM), then the
/// per-address-space quota (ENOMEM). Nothing is recorded unless the whole request succeeds.
pub fn mlock(addr: u64, len: u64) i64 {
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;
    const cap = cur.effective_caps.cap_ipc_lock;
    const limit = memlockLimit(cur);
    if (!policy.mayAttempt(limit, cap)) return -1; // EPERM

    const pages: u64 = switch (range_policy.lockSpan(addr, len)) {
        .err => |e| return e,
        .empty => return 0,
        .pages => |n| n,
    };
    const mm = cur.mm orelse return -12;
    var guard = mm_mod.Mm.beginVmMutation(cur.mm, @ptrCast(cur)) catch return -35;
    defer guard.release();

    const start = addr & ~(PAGE - 1);
    if (!mmap_mod.rangeMapped(start, pages * PAGE)) return -12; // ENOMEM: a hole
    // Linux does not lock PROT_NONE pages and reports ENOMEM for them; so does a range with such a page.
    if (mmap_mod.hasReservedPage(cur, start, pages)) return -12;

    const first = start / PAGE;
    const already = mm.locks.overlapPages(first, pages);
    if (!policy.fitsLimit(limit, cap, mm.locks.total(), pages, already)) return -12;
    if (!mm.locks.lock(first, pages)) return -12;
    return 0;
}

/// munlock(addr, len) -> 0 or -errno. No privilege needed. Unlocking pages that are not locked succeeds.
pub fn munlock(addr: u64, len: u64) i64 {
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;
    const pages: u64 = switch (range_policy.lockSpan(addr, len)) {
        .err => |e| return e,
        .empty => return 0,
        .pages => |n| n,
    };
    const mm = cur.mm orelse return -12;
    var guard = mm_mod.Mm.beginVmMutation(cur.mm, @ptrCast(cur)) catch return -35;
    defer guard.release();

    const start = addr & ~(PAGE - 1);
    if (!mmap_mod.rangeMapped(start, pages * PAGE)) return -12; // ENOMEM
    if (!mm.locks.release(start / PAGE, pages)) return -12; // no slot for the split piece
    return 0;
}

/// mlockall(flags) -> 0 or -errno. Linux order: flags (EINVAL), privilege/limit gate (EPERM), then MCL_CURRENT
/// needs everything the address space holds to fit RLIMIT_MEMLOCK (ENOMEM) unless CAP_IPC_LOCK. MCL_CURRENT
/// locks every present, swapped or tracked-but-not-yet-faulted page (device mappings excepted); MCL_FUTURE only
/// records the flag. A call without MCL_FUTURE clears an earlier MCL_FUTURE (Linux: def_flags is rewritten), and
/// nothing is changed when the call fails. MCL_ONFAULT is accepted: pages here are never populated lazily by
/// the lock, so it cannot be told apart.
pub fn mlockall(flags: u32) i64 {
    if (!range_policy.mlockallFlagsValid(flags)) return -22;
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;
    const cap = cur.effective_caps.cap_ipc_lock;
    const limit = memlockLimit(cur);
    if (!policy.mayAttempt(limit, cap)) return -1; // EPERM
    const mm = cur.mm orelse return -12;
    var guard = mm_mod.Mm.beginVmMutation(cur.mm, @ptrCast(cur)) catch return -35;
    defer guard.release();

    if (flags & range_policy.MCL_CURRENT != 0) {
        var next = mm.locks;
        if (!mmap_mod.lockEverything(cur, &next)) return -12; // more separate ranges than the table holds
        if (!policy.currentFits(limit, cap, next.total())) return -12;
        mm.locks = next;
    }
    mm.lock_future = flags & range_policy.MCL_FUTURE != 0;
    return 0;
}

/// munlockall() -> 0. Drops every lock and also MCL_FUTURE.
pub fn munlockall() i64 {
    const cur_idx = sched.currentTaskIndex() orelse return 0;
    const cur = task_mod.getTask(cur_idx) orelse return 0;
    const mm = cur.mm orelse return 0;
    var guard = mm_mod.Mm.beginVmMutation(cur.mm, @ptrCast(cur)) catch return -35;
    defer guard.release();
    mm.locks.clear();
    mm.lock_future = false;
    return 0;
}
