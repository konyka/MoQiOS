//! Lock-free "earliest deadline" gate for tick-driven timer pools.
//!
//! The hint is always a lower bound of every armed deadline, so the tick may
//! skip the locked pool scan while `!due(now)`. A disarm leaves the hint
//! stale-low, which only costs one scan. Rebuilds never store a computed
//! minimum: `beginScan` resets to NONE and survivors re-`arm`, so an arm that
//! races the scan (e.g. while the pool lock is dropped to wake waiters) is
//! folded in by the same atomic min instead of being overwritten.

pub const NONE: u64 = ~@as(u64, 0);

pub const DeadlineHint = struct {
    next: u64 = NONE,

    pub fn arm(self: *DeadlineHint, deadline: u64) void {
        _ = @atomicRmw(u64, &self.next, .Min, deadline, .acq_rel);
    }

    pub fn due(self: *const DeadlineHint, now: u64) bool {
        const next = @atomicLoad(u64, &self.next, .acquire);
        return next != NONE and now >= next;
    }

    /// Call under the pool lock before the scan; re-`arm` every survivor.
    pub fn beginScan(self: *DeadlineHint) void {
        @atomicStore(u64, &self.next, NONE, .release);
    }
};
