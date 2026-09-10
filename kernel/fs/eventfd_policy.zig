//! Pure counter/wake decisions for eventfd read/write (Linux eventfd2
//! semantics).
//!
//! eventfd wake-ups are a broadcast: every blocked reader/writer is woken
//! and re-checks its own condition; the first reader to run drains (or
//! decrements) the counter. The writer-side question is whether a write is
//! admitted without blocking — the counter may never exceed 2^64-2 — and
//! whether the write made the instance readable: a no-op write (val == 0
//! onto a zero counter) must NOT broadcast, or blocked readers would spin
//! through spurious wake/re-block cycles.

/// Highest legal counter value: a write may never push past 2^64-2
/// (0xFFFFFFFFFFFFFFFE); 2^64-1 is reserved as the invalid write value.
pub const COUNTER_MAX: u64 = 0xFFFF_FFFF_FFFF_FFFE;

/// Outcome of a successful 8-byte read (caller guarantees counter > 0):
/// the u64 returned to user space and the counter value left behind.
pub const ReadResult = struct {
    value: u64,
    counter_after: u64,
};

/// Default mode drains the counter to 0 and returns the pre-read value;
/// EFD_SEMAPHORE mode decrements by 1 and returns 1.
pub fn readResult(counter: u64, semaphore: bool) ReadResult {
    if (semaphore) return .{ .value = 1, .counter_after = counter - 1 };
    return .{ .value = counter, .counter_after = 0 };
}

/// A write value of 0xFFFFFFFFFFFFFFFF is invalid (Linux: -EINVAL).
pub fn writeValValid(val: u64) bool {
    return val != 0xFFFF_FFFF_FFFF_FFFF;
}

/// A write of `val` is admitted without blocking iff the sum stays
/// ≤ COUNTER_MAX. val is assumed valid (see writeValValid); the subtraction
/// cannot underflow because counter ≤ COUNTER_MAX by invariant.
pub fn writeAdmitted(counter: u64, val: u64) bool {
    return val <= COUNTER_MAX - counter;
}

/// A write wakes blocked readers iff the counter is readable afterwards.
/// val == 0 onto a zero counter leaves it unreadable → no wake.
pub fn writeWakesReaders(counter_after: u64) bool {
    return counter_after > 0;
}
