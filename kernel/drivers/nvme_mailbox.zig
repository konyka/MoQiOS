//! The completion mailbox between an NVMe submitter and the interrupt handler,
//! as pure state transitions so every interleaving can be enumerated on the host.
//!
//! One command is in flight per queue (the submitter owns the channel). The
//! submitter publishes the command with the doorbell and then waits; the
//! interrupt may run at any point after the doorbell, including before the
//! submitter has started waiting. The handler consumes the completion queue
//! entry, stores the result in the mailbox and wakes a waiter if one is linked.
//!
//! The bug this module exists to rule out: if the waiter clears the mailbox
//! *after* the doorbell, an interrupt that already ran has its result erased,
//! the waiter finds the completion queue empty (the handler consumed the
//! entry), and parks with nobody left to wake it.

pub const State = struct {
    /// The device has produced a completion entry nobody consumed yet.
    cq_pending: bool = false,
    /// The mailbox flag the handler sets.
    done: bool = false,
    /// A result is in the mailbox.
    has_result: bool = false,
    /// The submitter is linked on the wait list and will be woken by the handler.
    linked: bool = false,
    /// The submitter has been told to run (woken, or never slept).
    woken: bool = false,
    /// The submitter obtained its completion.
    got: bool = false,
};

/// Submitter, before the doorbell. The current protocol resets the mailbox here.
pub fn submit(s: *State, reset_before_doorbell: bool) void {
    if (reset_before_doorbell) {
        s.done = false;
        s.has_result = false;
    }
}

/// The device completes the command (some time after the doorbell).
pub fn deviceCompletes(s: *State) void {
    s.cq_pending = true;
}

/// Interrupt handler: consume the entry, publish the result, wake a linked waiter.
/// Returns false when there was nothing to do (spurious).
pub fn isr(s: *State) bool {
    if (!s.cq_pending) return false;
    s.cq_pending = false;
    s.has_result = true;
    s.done = true;
    if (s.linked) {
        s.linked = false;
        s.woken = true;
    }
    return true;
}

/// Submitter, entering the wait (one atomic step: it holds the queue lock).
/// `legacy_clear` reproduces the old code, which cleared the mailbox here.
pub fn enterWait(s: *State, legacy_clear: bool) void {
    if (s.cq_pending) { // harvest the entry ourselves
        s.cq_pending = false;
        s.got = true;
        return;
    }
    if (!legacy_clear and s.done) { // the handler already delivered: take it
        s.got = true;
        return;
    }
    if (legacy_clear) {
        s.done = false;
        s.has_result = false;
    }
    s.linked = true; // sleep until the handler wakes us
}

/// True if the submitter is asleep with no way to be woken: it is linked,
/// the handler has nothing left to do, and the device has nothing outstanding.
pub fn stuck(s: State) bool {
    return s.linked and !s.cq_pending and !s.woken and !s.got;
}

/// After a wake the submitter reads the mailbox.
pub fn afterWake(s: *State) void {
    if (s.woken and s.done) s.got = true;
}
