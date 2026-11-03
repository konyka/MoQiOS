//! Reference-counted process address-space handle.
//!
//! Lock order: pin a task/lookup lifetime before pinning Mm.  Hold the Mm VM
//! lock before page-table or VMA mutation.  Never hold the VM lock across a
//! blocking scheduler operation or acquire task_lock while holding it.
//!
//! The single sanctioned task_lock → vm_lock edge is the reap-side
//! userdrv.cleanupTask guard (task.zig teardownResources) when it runs inline
//! because the reaper thread (proc/reaper.zig) is not up yet; the reaper
//! itself takes the guard without task_lock. The guard
//! serialises a dead task's MMIO/DMA PTE unmaps against siblings still
//! sharing the live space. Safe because vm_lock holders never wait on
//! task_lock, and ServicingSpinlock waiters service pending TLB shootdowns
//! while spinning, so the edge cannot close a cycle.
//!
//! Swap reclaim (pmm.allocPage OOM path) enters through
//! beginReclaimCritical: a non-blocking tryAcquire — never waiting — that
//! proceeds unguarded when the current task already owns the lock (the
//! fault → swapIn → allocPage recursion) and skips on contention.
//!
//! Stage 1 deliberately does not select another task's Mm or switch CR3;
//! process_vm remains self-only. Existing raw-root mapping callers are kept
//! for compatibility and must migrate to vmLock in the cross-process stage.

const std = @import("std");
const ServicingSpinlock = @import("../sync/servicing_spinlock.zig").ServicingSpinlock;

pub const Mm = struct {
    /// The terminal value is part of refs, so retain and the last release
    /// agree on one atomic state transition and cannot race through zero.
    pub const TERMINAL_REFS: u32 = std.math.maxInt(u32);
    pub const MAX_LIVE_REFS: u32 = TERMINAL_REFS - 1;

    refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    finalized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    page_table_phys: u64,
    /// Servicing spinlock: waiters spin with IRQs off while manually
    /// servicing pending TLB shootdown broadcasts, because holders
    /// synchronously wait for remote shootdown acks (mprotect/munmap/COW)
    /// and an IRQ-off waiter would otherwise deadlock that protocol into a
    /// `failShootdown` halt.
    vm_lock: ServicingSpinlock = .{},
    vm_owner: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    finalizer: *const fn (*Mm) void,
    /// mseal(2) ranges. Written under vm_lock; a fresh address space (exec)
    /// starts empty, fork copies the parent's (Linux: seals are inherited).
    seals: @import("mseal_policy.zig").Table = .{},
    /// mlock ranges (page numbers). Written under vm_lock; a fresh address space (exec, fork child) starts empty,
    /// like Linux, where VM_LOCKED is not inherited across fork.
    locks: @import("mlock_policy.zig").Table = .{},
    /// mlockall(MCL_FUTURE): every mapping made from now on is locked (and charged to RLIMIT_MEMLOCK). Written under
    /// vm_lock; a fresh address space (exec, fork child) starts without it, like Linux where it is not inherited.
    lock_future: bool = false,
    /// The program break. It belongs to the address space, not to a thread: CLONE_VM siblings share one Mm and so one
    /// break, and a sibling that grew the heap is seen by all the others. Written under vm_lock. brk_start is where the
    /// loader left the break (it may never retreat below it); 0 in both means no heap was set up for this image.
    brk_start: u64 = 0,
    brk_current: u64 = 0,
    /// RLIMIT_AS / RLIMIT_DATA charge of this address space, in bytes (Linux mm->total_vm / data_vm): brk heap pages,
    /// tracked mmap regions and demand-faulted stack pages. One counter per address space, so CLONE_VM threads charge
    /// the same one. Written under vm_lock; a fresh address space (exec) starts at 0, a fork child at the parent's.
    as_used: u64 = 0,
    data_used: u64 = 0,
    /// The tracked mappings (mmap/munmap/mprotect/mlock bookkeeping) of this address space. Written under vm_lock. The
    /// region array is one page allocated with the Mm and freed with it; a fork child gets a copy, exec an empty table.
    vma_tab: @import("vma_table.zig").VmaTable,
    /// Signal dispositions and resource limits of the thread group (mm/group_state.zig); one page, shared by CLONE_VM
    /// threads, allocated with the Mm and freed with it. A fork child gets a copy, exec resets caught signals and carries
    /// the limits over.
    grp: *@import("group_state.zig").GroupState,

    /// A copied address space (fork, clone without CLONE_VM) starts at the parent's RLIMIT_AS / RLIMIT_DATA charge.
    pub fn inheritCharges(mm: *Mm, parent: *const Mm) void {
        mm.as_used = parent.as_used;
        mm.data_used = parent.data_used;
    }

    /// A new address space copied from `parent` (fork, clone without CLONE_VM) starts with the parent's resource limits; exec
    /// carries the old image's limits into the new one. (Signal dispositions are copied separately: exec resets them.)
    pub fn inheritLimits(mm: *Mm, parent: *const Mm) void {
        mm.grp.lim = parent.grp.lim;
    }

    /// Set the initial break of a freshly built address space (loader, exec). Nobody else can see it yet.
    pub fn setBreak(mm: *Mm, brk: u64) void {
        mm.brk_start = brk;
        mm.brk_current = brk;
    }

    /// A new address space copied from `parent` (fork, clone without CLONE_VM) starts with the parent's break.
    pub fn inheritBreak(mm: *Mm, parent: *const Mm) void {
        mm.brk_start = parent.brk_start;
        mm.brk_current = parent.brk_current;
    }

    /// Whether [base, base+len) touches a sealed range (caller holds vm_lock).
    pub fn sealed(mm: ?*Mm, base: u64, len: u64) bool {
        const m = mm orelse return false;
        return m.seals.overlaps(base, len);
    }

    /// Whether new mappings of this address space are locked (mlockall MCL_FUTURE). Caller holds vm_lock.
    pub fn futureLocking(mm: ?*Mm) bool {
        const m = mm orelse return false;
        return m.lock_future;
    }

    /// Whether any page of [base, base+len) is mlocked (caller holds vm_lock, or is the reclaim guard).
    pub fn locked(mm: ?*Mm, base: u64, len: u64) bool {
        const m = mm orelse return false;
        return m.locks.touches(base / 4096, (len + 4095) / 4096);
    }

    pub fn acquire(page_table_phys: u64, finalizer: *const fn (*Mm) void) ?*Mm {
        const slab = @import("slab.zig");
        const ptr = slab.kmalloc(@sizeOf(Mm)) orelse return null;
        const mm: *Mm = @ptrCast(@alignCast(ptr));
        const pmm = @import("pmm.zig");
        const phys = pmm.allocPage() orelse {
            slab.kfree(ptr);
            return null;
        };
        const regions: *[@import("vma_table.zig").MAX_REGIONS]@import("vma_table.zig").MmapRegion = @ptrFromInt(@import("hhdm.zig").physToVirt(phys));
        for (regions) |*r| r.* = .{};
        const grp_phys = pmm.allocPage() orelse {
            pmm.freePage(phys);
            slab.kfree(ptr);
            return null;
        };
        const grp: *@import("group_state.zig").GroupState = @ptrFromInt(@import("hhdm.zig").physToVirt(grp_phys));
        grp.* = @import("group_state.zig").GroupState.initial(@import("group_state.zig").DEFAULT_NOFILE);
        mm.* = .{ .page_table_phys = page_table_phys, .finalizer = finalizer, .vma_tab = .{ .regions = regions }, .grp = grp };
        return mm;
    }

    /// Retain only a live address space. A dying Mm cannot be resurrected.
    pub fn retain(self: *Mm) bool {
        var count = self.refs.load(.acquire);
        while (count != 0 and count < MAX_LIVE_REFS) {
            if (self.refs.cmpxchgWeak(count, count + 1, .acq_rel, .acquire)) |observed| {
                count = observed;
                continue;
            }
            return true;
        }
        return false;
    }

    /// Drop one reference. Only the transition to zero runs final destruction.
    pub fn release(self: *Mm) void {
        var count = self.refs.load(.acquire);
        while (count != 0 and count != TERMINAL_REFS) {
            const next = if (count == 1) TERMINAL_REFS else count - 1;
            if (self.refs.cmpxchgWeak(count, next, .acq_rel, .acquire)) |observed| {
                count = observed;
                continue;
            }
            if (count == 1) {
                self.finalDestroy();
            }
            return;
        }
        // Underflow is rejected; a second release cannot free twice.
    }

    /// Final destruction is idempotent and only valid after the last release.
    pub fn finalDestroy(self: *Mm) void {
        if (self.refs.load(.acquire) != TERMINAL_REFS) return;
        if (self.finalized.swap(true, .acq_rel)) return;
        self.finalizer(self);
        @import("pmm.zig").freePage(@import("hhdm.zig").virtToPhys(@intFromPtr(self.vma_tab.regions)));
        @import("pmm.zig").freePage(@import("hhdm.zig").virtToPhys(@intFromPtr(self.grp)));
        @import("slab.zig").kfree(self);
    }

    /// True while more than one reference pins this address space (a CLONE_VM
    /// sibling, an operation pin, or an in-flight VM guard). Consulted by
    /// exec: replacing a shared address space races its other users.
    pub fn isShared(self: *Mm) bool {
        return self.refs.load(.acquire) > 1;
    }

    pub fn vmLock(self: *Mm) u64 {
        return self.vm_lock.acquire();
    }

    pub fn vmUnlock(self: *Mm, flags: u64) void {
        self.vm_lock.release(flags);
    }

    /// Stage 1 syscall mutation guard. The owner check prevents a same-task
    /// recursive IrqSpinlock deadlock. Fault-side PTE mutations use
    /// beginFaultCritical instead, fork/clone COW page-table cloning is
    /// guarded at its call sites, swap reclaim uses the non-blocking
    /// beginReclaimCritical, and the SysV SHM/user-driver/reap PTE paths are
    /// guarded at their call sites. Full-vm_lock coverage of the remaining
    /// exit/exec teardown walk stays a next prerequisite.
    pub fn beginVmMutation(mm: ?*Mm, owner: *const anyopaque) VmLockGuard.Error!VmLockGuard {
        const policy = @import("vm_lock_policy.zig");
        const address = @intFromPtr(owner);
        const target = mm orelse return .{};
        const already_held = target.vm_owner.load(.acquire) == address;
        switch (policy.decide(true, already_held)) {
            .recursive => return error.Recursive,
            .no_mm => return .{},
            .acquire => {},
        }
        if (!target.retain()) return error.Dying;
        const flags = target.vmLock();
        target.vm_owner.store(address, .release);
        return .{ .mm = target, .flags = flags, .owner = address };
    }

    pub const VmLockGuard = struct {
        mm: ?*Mm = null,
        flags: u64 = 0,
        owner: usize = 0,

        pub const Error = error{ Recursive, Dying };

        pub fn release(self: *VmLockGuard) void {
            const target = self.mm orelse return;
            self.mm = null;
            target.vm_owner.store(0, .release);
            target.vmUnlock(self.flags);
            target.release();
        }
    };

    /// One-shot observability for the owned_by_us fault path.
    var fault_under_guard_logged: bool = false;

    /// Fault-side VM mutation guard for the page-fault handler.
    ///
    /// Unlike beginVmMutation this never fails and never blocks on
    /// task/scheduler locks: the caller passes the CURRENT task's own Mm
    /// (obtained locklessly from the per-CPU current task), which is kept
    /// alive by the running task's own reference, so no retain is needed to
    /// pin it — the retain below only balances VmLockGuard.release.
    ///
    /// If the same task already holds vm_lock (a syscall-side mutation on
    /// this CPU faulted mid-critical-section — a bug per the lock audit),
    /// the fault proceeds WITHOUT acquiring: a recursive IrqSpinlock take
    /// would deadlock. The event is logged once to keep it observable.
    pub fn beginFaultCritical(mm: ?*Mm, owner: *const anyopaque) VmLockGuard {
        const policy = @import("vm_lock_policy.zig");
        const address = @intFromPtr(owner);
        const target = mm orelse return .{};
        const already_held = target.vm_owner.load(.acquire) == address;
        switch (policy.decideFault(true, already_held)) {
            .no_mm => return .{},
            .owned_by_us => {
                if (!fault_under_guard_logged) {
                    fault_under_guard_logged = true;
                    @import("../arch/arch.zig").serial.writeString(
                        "[mm] WARN: page fault under a vm_lock held by the faulting task; proceeding unguarded\n",
                    );
                }
                return .{};
            },
            .acquire => {},
        }
        // A running task's own Mm is live, so retain cannot fail here; if it
        // ever did, proceeding unguarded matches the pre-guard behaviour.
        if (!target.retain()) return .{};
        const flags = target.vmLock();
        target.vm_owner.store(address, .release);
        return .{ .mm = target, .flags = flags, .owner = address };
    }

    /// Reclaim-side VM mutation guard for swap reclaim.
    ///
    /// pmm.allocPage's OOM path reaches reclaim both with and without
    /// vm_lock held, so this guard is recursion-safe and NEVER blocks:
    ///   - vm_owner == owner (the fault → swapIn → allocPage recursion, a
    ///     legitimate re-entry): proceed WITHOUT acquiring — unlike
    ///     beginFaultCritical this is expected, so no WARN.
    ///   - otherwise a single tryAcquire; on contention return null and the
    ///     caller skips reclaim entirely (reclaim is best-effort; all
    ///     callers handle null).
    /// The retain only balances VmLockGuard.release (same argument as
    /// beginFaultCritical): the current task's own reference keeps the Mm
    /// alive for the scan.
    pub fn beginReclaimCritical(mm: ?*Mm, owner: *const anyopaque) ?VmLockGuard {
        const policy = @import("vm_lock_policy.zig");
        const address = @intFromPtr(owner);
        const target = mm orelse return null;
        const owned_by_us = target.vm_owner.load(.acquire) == address;
        const try_flags: ?u64 = if (owned_by_us) null else target.vm_lock.tryAcquire();
        switch (policy.decideReclaim(true, owned_by_us, try_flags != null)) {
            .no_mm => unreachable, // target non-null above
            .owned_by_us => return .{},
            .skip => return null,
            .acquired => {},
        }
        const flags = try_flags.?;
        if (!target.retain()) {
            target.vmUnlock(flags);
            return null;
        }
        target.vm_owner.store(address, .release);
        return .{ .mm = target, .flags = flags, .owner = address };
    }
};

pub const TestRefState = struct {
    pub const TERMINAL_REFS: u32 = std.math.maxInt(u32);
    pub const MAX_LIVE_REFS: u32 = TERMINAL_REFS - 1;

    refs: u32 = 1,
    dying: bool = false,
    finalized: bool = false,

    pub fn retain(self: *TestRefState) bool {
        if (self.refs == 0 or self.refs >= MAX_LIVE_REFS) return false;
        self.refs += 1;
        return true;
    }

    pub fn release(self: *TestRefState) void {
        if (self.refs == 0 or self.refs == TERMINAL_REFS) return;
        if (self.refs == 1) {
            self.refs = TERMINAL_REFS;
            self.dying = true;
            self.finalized = true;
        } else {
            self.refs -= 1;
        }
    }
};

pub const TestVmLockState = struct {
    held: bool = false,

    pub fn acquire(self: *TestVmLockState) bool {
        if (self.held) return false;
        self.held = true;
        return true;
    }

    pub fn release(self: *TestVmLockState) bool {
        if (!self.held) return false;
        self.held = false;
        return true;
    }
};
