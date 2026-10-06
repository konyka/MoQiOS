//! Fair FIFO ticket lock core (arch-neutral, no IRQ handling).
//!
//! A test-and-set lock lets whichever CPU's Xchg reaches the cache line first
//! win, so under contention one CPU can starve another indefinitely and the
//! worst-case acquisition latency is unbounded. A ticket lock bounds it: a
//! waiter is served after exactly the holders queued in front of it.
//!
//! `next` is the next ticket to hand out; `serving` is the ticket that owns
//! the lock. Unlocked ⇔ next == serving. Both are 32-bit wrapping counters, so
//! up to 2^32-1 simultaneous waiters are ordered correctly.
//!
//! IRQ masking, servicing hooks and the cpu-relax instruction are supplied by
//! the wrappers (IrqSpinlock, ServicingSpinlock, TlbLock); this file stays pure
//! so it is host-testable with real threads.

const std = @import("std");

pub const Ticket = struct {
    next: u32 = 0,
    serving: u32 = 0,

    /// Join the queue; the returned ticket owns the lock once `isServing`.
    pub inline fn take(self: *Ticket) u32 {
        return @atomicRmw(u32, &self.next, .Add, 1, .monotonic);
    }

    pub inline fn isServing(self: *const Ticket, ticket: u32) bool {
        return @atomicLoad(u32, &self.serving, .acquire) == ticket;
    }

    pub inline fn lock(self: *Ticket, comptime relax: fn () void) void {
        const me = self.take();
        while (!self.isServing(me)) relax();
    }

    /// Succeeds only when nobody holds or waits for the lock: a free lock has
    /// next == serving, so claiming ticket `serving` is a single CAS on
    /// `next`. A concurrent take()/unlock() moves `next` and fails the CAS,
    /// so tryLock can never overtake a queued waiter.
    pub inline fn tryLock(self: *Ticket) bool {
        const s = @atomicLoad(u32, &self.serving, .acquire);
        return @cmpxchgStrong(u32, &self.next, s, s +% 1, .acquire, .monotonic) == null;
    }

    /// Only the holder writes `serving`, so a plain load + release store is
    /// enough (no RMW, no carry into `next`).
    pub inline fn unlock(self: *Ticket) void {
        std.debug.assert(self.isLocked());
        const s = @atomicLoad(u32, &self.serving, .monotonic);
        @atomicStore(u32, &self.serving, s +% 1, .release);
    }

    pub inline fn isLocked(self: *const Ticket) bool {
        return @atomicLoad(u32, &self.next, .monotonic) != @atomicLoad(u32, &self.serving, .monotonic);
    }

    /// Queued waiters behind the current holder (0 when free or uncontended).
    pub inline fn waiters(self: *const Ticket) u32 {
        const n = @atomicLoad(u32, &self.next, .monotonic);
        const s = @atomicLoad(u32, &self.serving, .monotonic);
        const queued = n -% s;
        return if (queued == 0) 0 else queued - 1;
    }
};
