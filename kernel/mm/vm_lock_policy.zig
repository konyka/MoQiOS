//! Pure decisions for the current-task VM mutation guard.

pub const Decision = enum {
    no_mm,
    acquire,
    recursive,
};

pub fn decide(has_mm: bool, already_held: bool) Decision {
    if (!has_mm) return .no_mm;
    if (already_held) return .recursive;
    return .acquire;
}

pub const FaultDecision = enum {
    no_mm,
    acquire,
    /// The lock is already held by the current (faulting) task: proceed
    /// WITHOUT acquiring. Unlike the syscall-side `.recursive` error, a page
    /// fault cannot bail out mid-mutation, and re-acquiring an IrqSpinlock
    /// held by ourselves would deadlock.
    owned_by_us,
};

pub fn decideFault(has_mm: bool, already_held_by_us: bool) FaultDecision {
    if (!has_mm) return .no_mm;
    if (already_held_by_us) return .owned_by_us;
    return .acquire;
}

pub const ReclaimDecision = enum {
    no_mm,
    /// The lock is already held by the current task (fault → swapIn →
    /// allocPage → reclaim recursion): proceed WITHOUT re-acquiring. Unlike
    /// the fault side this is a legitimate recursion, not a bug — no WARN.
    owned_by_us,
    /// The non-blocking try succeeded: the caller holds vm_lock.
    acquired,
    /// Contention: skip reclaim. Reclaim is best-effort and must never wait
    /// on vm_lock (pmm.allocPage reaches it both with and without vm_lock).
    skip,
};

pub fn decideReclaim(has_mm: bool, owned_by_us: bool, try_acquired: bool) ReclaimDecision {
    if (!has_mm) return .no_mm;
    if (owned_by_us) return .owned_by_us;
    return if (try_acquired) .acquired else .skip;
}
