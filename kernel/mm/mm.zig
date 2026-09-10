//! Reference-counted process address-space handle.
//!
//! Lock order: pin a task/lookup lifetime before pinning Mm.  Hold the Mm VM
//! lock before page-table or VMA mutation.  Never hold the VM lock across a
//! blocking scheduler operation or acquire task_lock while holding it.
//!
//! Stage 1 deliberately does not select another task's Mm or switch CR3;
//! process_vm remains self-only. Existing raw-root mapping callers are kept
//! for compatibility and must migrate to vmLock in the cross-process stage.

const std = @import("std");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

pub const Mm = struct {
    /// The terminal value is part of refs, so retain and the last release
    /// agree on one atomic state transition and cannot race through zero.
    pub const TERMINAL_REFS: u32 = std.math.maxInt(u32);
    pub const MAX_LIVE_REFS: u32 = TERMINAL_REFS - 1;

    refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    finalized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    page_table_phys: u64,
    vm_lock: IrqSpinlock = .{},
    vm_owner: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    finalizer: *const fn (*Mm) void,

    pub fn acquire(page_table_phys: u64, finalizer: *const fn (*Mm) void) ?*Mm {
        const slab = @import("slab.zig");
        const ptr = slab.kmalloc(@sizeOf(Mm)) orelse return null;
        const mm: *Mm = @ptrCast(@alignCast(ptr));
        mm.* = .{ .page_table_phys = page_table_phys, .finalizer = finalizer };
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
        @import("slab.zig").kfree(self);
    }

    pub fn vmLock(self: *Mm) u64 {
        return self.vm_lock.acquire();
    }

    pub fn vmUnlock(self: *Mm, flags: u64) void {
        self.vm_lock.release(flags);
    }

    /// Stage 1 syscall mutation guard. The owner check prevents a same-task
    /// recursive IrqSpinlock deadlock; page faults/COW/fork/clone/exec teardown
    /// remain next prerequisites for full Mm.vmLock migration.
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
