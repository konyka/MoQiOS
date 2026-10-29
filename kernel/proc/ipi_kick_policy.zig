//! Reschedule-IPI coalescing (pure).
//!
//! A CPU that already has a reschedule IPI in flight does not need another:
//! the pending pass will see every task queued since the last kick. Extra
//! IPIs only cut into the current OTHER task's remaining slice.

/// Send only when no IPI is already on the way (`already_pending` is the
/// previous value of the per-CPU flag).
pub fn shouldSend(already_pending: bool) bool {
    return !already_pending;
}

/// Value stored while an IPI is in flight.
pub fn mark(prev: u8) u8 {
    _ = prev;
    return 1;
}

/// Value stored when the IPI pass starts (further kicks may send again).
pub fn clear() u8 {
    return 0;
}

/// Whether the sender must reset the flag after its send attempt. Only an IPI
/// the LAPIC never accepted (ICR delivery timeout): no pass will run to clear
/// the flag, so every later kick to that CPU would be coalesced away. After a
/// delivered IPI the sender must NOT touch it — the target may already have
/// cleared it, and re-marking would strand it set with nothing in flight.
pub fn resetAfterSend(delivered: bool) bool {
    return !delivered;
}
