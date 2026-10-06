//! Choose the next LAPIC one-shot deadline (pure, TSC units).
//!
//! The periodic 100 Hz tick is the coarsest event: timeslice accounting and
//! slow maintenance still run on that cadence. A wait that expires sooner
//! (futex/epoll/sleep) programs the timer to that instant instead of waiting
//! for the next 10 ms edge.

/// `now_tsc` plus remaining slice ticks (at least one tick if the slice is
/// already 0, so a just-expired slice still gets a tick to reschedule).
pub fn sliceDeadlineTsc(now_tsc: u64, tsc_per_tick: u64, slice_left: u64) u64 {
    const ticks = if (slice_left == 0) 1 else slice_left;
    return now_tsc +| (ticks * tsc_per_tick);
}

/// Earliest of the remaining slice and an optional wait deadline in TSC.
/// A wait in the past arms "now" so the handler runs on the next instruction
/// that restores IF, never a wrapped far-future value.
pub fn nextDeadlineTsc(now_tsc: u64, tsc_per_tick: u64, slice_left: u64, wait_deadline_tsc: ?u64) u64 {
    const slice_at = sliceDeadlineTsc(now_tsc, tsc_per_tick, slice_left);
    const wait_at = wait_deadline_tsc orelse return slice_at;
    const clamped = if (wait_at < now_tsc) now_tsc else wait_at;
    return if (clamped < slice_at) clamped else slice_at;
}
