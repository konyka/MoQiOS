//! Per-CPU magazine layer for the slab allocator (K2).
//!
//! A magazine is a small fixed-capacity LIFO stack of free object pointers,
//! one per (CPU, size class). It sits in front of the locked SlabPool free
//! lists to keep the kmalloc/kfree hot path lock-free:
//!
//!   alloc: IRQ-off -> pop from this CPU's magazine -> if empty, batch-refill
//!          REFILL_BATCH objects from the pool (under the pool lock), retry.
//!   free:  IRQ-off -> push to this CPU's magazine -> if full, batch-flush
//!          FLUSH_BATCH objects to the pool (under the pool lock), retry.
//!
//! Ownership invariant: an object is at any moment in exactly one of
//!   (a) a pool free list, (b) exactly one CPU's magazine, (c) user hands.
//! `refill` only receives objects the backing store has already removed from
//! its free list; `flush` hands objects to the backing store only after
//! removing them from the magazine. Objects held in magazines are therefore
//! *allocated* from the pool's point of view — the pool must never hand them
//! out a second time.
//!
//! This file is pure bookkeeping: no arch imports, no locks, no allocation.
//! The caller (kernel/mm/slab.zig) supplies the IRQ-off window, the CPU
//! index, and the pool lock scoping. Host tests (tests/main.zig, "slab
//! magazine (K2)" block) exercise it with a mock backing store.
//!
//! Backing-store protocol: `pool.popFree() ?*anyopaque` removes and returns
//! one object (null = empty); `pool.pushFree(obj)` returns one object. Both
//! are invoked with the caller's pool lock held, so the store need not be
//! internally synchronised.

/// Objects per magazine. Small enough that a full flush cannot strand much
/// memory per CPU, large enough to absorb typical alloc/free bursts.
pub const MAG_SIZE: u8 = 8;
/// Objects moved pool -> magazine on an empty-magazine alloc.
pub const REFILL_BATCH: u8 = MAG_SIZE / 2;
/// Objects moved magazine -> pool on a full-magazine free. Kept below
/// MAG_SIZE so the push that triggered the flush always fits afterwards.
pub const FLUSH_BATCH: u8 = MAG_SIZE / 2;

comptime {
    if (REFILL_BATCH == 0 or REFILL_BATCH > MAG_SIZE)
        @compileError("REFILL_BATCH must be in 1..MAG_SIZE");
    if (FLUSH_BATCH == 0 or FLUSH_BATCH >= MAG_SIZE)
        @compileError("FLUSH_BATCH must be in 1..MAG_SIZE-1 (post-flush push must fit)");
}

pub const Magazine = struct {
    /// Slot base pointers; only slots[0..count] are valid.
    slots: [MAG_SIZE]?*anyopaque = [_]?*anyopaque{null} ** MAG_SIZE,
    count: u8 = 0,

    pub fn len(self: *const Magazine) u8 {
        return self.count;
    }

    pub fn isEmpty(self: *const Magazine) bool {
        return self.count == 0;
    }

    pub fn isFull(self: *const Magazine) bool {
        return self.count >= MAG_SIZE;
    }

    /// Local pop — no backing-store interaction. Null when empty.
    pub fn pop(self: *Magazine) ?*anyopaque {
        if (self.count == 0) return null;
        self.count -= 1;
        const obj = self.slots[self.count];
        self.slots[self.count] = null;
        return obj;
    }

    /// Local push — no backing-store interaction. False when full (the
    /// object stays with the caller; nothing is overwritten).
    pub fn push(self: *Magazine, obj: *anyopaque) bool {
        if (self.count >= MAG_SIZE) return false;
        self.slots[self.count] = obj;
        self.count += 1;
        return true;
    }

    /// Move up to REFILL_BATCH objects from `pool` into the magazine.
    /// Returns the number moved (less than REFILL_BATCH iff the pool ran
    /// dry or the magazine had fewer free slots). Caller's pool lock held.
    pub fn refill(self: *Magazine, pool: anytype) u8 {
        var moved: u8 = 0;
        while (moved < REFILL_BATCH and self.count < MAG_SIZE) {
            const obj = pool.popFree() orelse break;
            self.slots[self.count] = obj;
            self.count += 1;
            moved += 1;
        }
        return moved;
    }

    /// Move up to FLUSH_BATCH objects from the magazine back to `pool`.
    /// Returns the number moved. Caller's pool lock held.
    pub fn flush(self: *Magazine, pool: anytype) u8 {
        var moved: u8 = 0;
        while (moved < FLUSH_BATCH and self.count > 0) {
            self.count -= 1;
            const obj = self.slots[self.count].?;
            self.slots[self.count] = null;
            pool.pushFree(obj);
            moved += 1;
        }
        return moved;
    }
};
