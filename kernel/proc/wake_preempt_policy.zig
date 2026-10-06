//! Wake-time preemption decision (pure; keys are `sched_policy.rankKey`,
//! lower = better).
//!
//! `target_cur_key` is the rank of the task running on the woken task's
//! target CPU, or null when that CPU has no running current (switching,
//! blocking, early boot). The read is a lock-free hint: a stale value costs
//! at most one redundant pass or one quantum of latency, never correctness.

pub const Action = enum { none, preempt_local, kick_remote };

pub fn decide(woken_key: u16, target_cur_key: ?u16, local: bool) Action {
    if (local) {
        // Equal rank waits for the quantum: preempting would ping-pong
        // waker and wakee. A null current is already on its way out.
        const cur = target_cur_key orelse return .none;
        return if (woken_key < cur) .preempt_local else .none;
    }
    // Equal rank still kicks: the woken task may be the remote current
    // itself (signal delivery), and a blocked current needs a fresh pick.
    const cur = target_cur_key orelse return .kick_remote;
    return if (woken_key <= cur) .kick_remote else .none;
}
