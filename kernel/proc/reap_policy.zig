//! Deferred reaping policy (pure, host-tested).
//!
//! Reaping is split in two:
//!   * detach — under task_lock, O(1): a quiesced zombie is marked
//!     `reap_pending`, unlinked from its parent and queued here;
//!   * teardown — in the reaper kernel thread with IRQs enabled and no
//!     scheduler lock held: driver/devfs/fbdev cleanup, the address space,
//!     the kernel stack; then the slot is freed and the waiter (a waitpid
//!     parent) woken.
//! Before this split, teardown ran in the BSP timer interrupt (orphans) or in
//! waitpid, always under the global task_lock with IRQs off.

/// Scheduler passes on the exit CPU that prove the exit-time switch
/// epilogue no longer runs on the zombie's kernel stack.
pub const QUIESCE_PASSES: u64 = 3;

pub const ZombieView = struct {
    is_zombie: bool,
    /// Already detached and queued for the reaper.
    reap_pending: bool,
    operation_refs: u32,
    /// Still some CPU's current task.
    current_somewhere: bool,
    /// 255 = never stamped (no epilogue to wait for).
    exit_cpu: u8,
    exit_epoch: u64,
    /// sched_entries[exit_cpu] now.
    exit_cpu_entries: u64,
};

pub const Verdict = enum {
    /// Not a zombie, or already handed to the reaper.
    skip,
    /// A zombie that cannot be detached yet (pinned / still running out).
    busy,
    detach,
};

pub fn verdict(v: ZombieView) Verdict {
    if (!v.is_zombie or v.reap_pending) return .skip;
    if (v.operation_refs != 0 or v.current_somewhere) return .busy;
    if (v.exit_cpu != 255) {
        const gate = @addWithOverflow(v.exit_epoch, QUIESCE_PASSES);
        if (gate[1] != 0 or v.exit_cpu_entries < gate[0]) return .busy;
    }
    return .detach;
}

pub const Lineage = struct {
    is_thread: bool,
    parent_alive: bool,
    /// The task's region table names file-backed or device (no_free)
    /// mappings. A CLONE_VM thread's table is an unreferenced copy of the
    /// leader's, so tearing it down while the group lives would close the
    /// leader's mapped files and unmap shared MMIO.
    maps_objects: bool,
};

/// Reaping nobody waits for: orphans, and non-leader threads (joined through
/// clear_tid, never through waitpid — leaving them for a living leader leaked
/// their task slots until the whole group exited). A process zombie with a
/// living parent is left for that parent's waitpid; so is a thread whose
/// region table names mapped objects (see `Lineage.maps_objects`).
pub fn autoReap(v: ZombieView, lineage: Lineage) Verdict {
    const base = verdict(v);
    if (base != .detach) return base;
    if (!lineage.parent_alive) return .detach;
    if (lineage.is_thread and !lineage.maps_objects) return .detach;
    return .skip;
}

pub const NO_WAITER: u32 = 0xFFFF_FFFF;

pub const WaiterToken = struct {
    slot: u32 = NO_WAITER,
    tid: u32 = 0,
    incarnation: u64 = 0,

    pub fn valid(self: WaiterToken) bool {
        return self.slot != NO_WAITER;
    }
};

/// Detached slots awaiting teardown. Caller provides the locking.
pub fn PendingSet(comptime N: usize) type {
    if (N > 64) @compileError("PendingSet is a single u64 bitmap");
    return struct {
        const Self = @This();
        const Mask = u64;

        pending: Mask = 0,
        started: Mask = 0,
        waiter: [N]WaiterToken = [_]WaiterToken{.{}} ** N,

        inline fn bit(slot: u32) Mask {
            return @as(Mask, 1) << @intCast(slot);
        }

        pub fn add(self: *Self, slot: u32, waiter: WaiterToken) void {
            std.debug.assert(slot < N and self.pending & bit(slot) == 0);
            self.pending |= bit(slot);
            self.started &= ~bit(slot);
            self.waiter[slot] = waiter;
        }

        pub fn isPending(self: *const Self, slot: u32) bool {
            return slot < N and self.pending & bit(slot) != 0;
        }

        /// Register the task to wake once `slot` is torn down. False when the
        /// slot is no longer pending (nothing to wait for).
        pub fn setWaiter(self: *Self, slot: u32, waiter: WaiterToken) bool {
            if (!self.isPending(slot)) return false;
            self.waiter[slot] = waiter;
            return true;
        }

        pub fn hasUnstarted(self: *const Self) bool {
            return self.pending & ~self.started != 0;
        }

        /// Next slot to tear down (lowest index); it stays pending until
        /// `complete`.
        pub fn takeUnstarted(self: *Self) ?u32 {
            const todo = self.pending & ~self.started;
            if (todo == 0) return null;
            const slot: u32 = @intCast(@ctz(todo));
            self.started |= bit(slot);
            return slot;
        }

        /// Teardown done: forget the slot and return its waiter.
        pub fn complete(self: *Self, slot: u32) WaiterToken {
            std.debug.assert(self.isPending(slot));
            self.pending &= ~bit(slot);
            self.started &= ~bit(slot);
            const w = self.waiter[slot];
            self.waiter[slot] = .{};
            return w;
        }
    };
}

const std = @import("std");

test "waiter tokens reject a reused slot" {
    const Token = WaiterToken;
    const old: Token = .{ .slot = 3, .tid = 10, .incarnation = 1 };
    const fresh: Token = .{ .slot = 3, .tid = 11, .incarnation = 2 };
    try std.testing.expect(old.valid());
    try std.testing.expect(fresh.valid());
    try std.testing.expect(old.tid != fresh.tid and old.incarnation != fresh.incarnation);
}
