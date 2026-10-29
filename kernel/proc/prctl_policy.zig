//! Pure prctl(2) argument rules (host-tested).

/// Highest signal number the kernel delivers (standard signals 1..31; no
/// real-time signals).
pub const NSIG: u64 = 31;

/// PR_SET_PDEATHSIG: 0 (clear) or a deliverable signal number.
pub fn pdeathsigValid(sig: u64) bool {
    return sig <= NSIG;
}

pub const NnpSet = enum { set, einval };

/// PR_SET_NO_NEW_PRIVS(1, 0, 0, 0): the flag can only be set, never cleared.
pub fn setNoNewPrivs(arg2: u64, arg3: u64, arg4: u64, arg5: u64) NnpSet {
    if (arg2 != 1 or arg3 != 0 or arg4 != 0 or arg5 != 0) return .einval;
    return .set;
}

/// PR_GET_NO_NEW_PRIVS takes no arguments.
pub fn getNoNewPrivsArgsValid(arg2: u64, arg3: u64, arg4: u64, arg5: u64) bool {
    return arg2 == 0 and arg3 == 0 and arg4 == 0 and arg5 == 0;
}

/// Children to notify when a task exits: live user processes whose parent is
/// the exiting task and that asked for a parent-death signal. Threads of the
/// exiting task are not "children" here (they share its fate).
pub fn deathSignalFor(child_parent_tid: u32, exiting_tid: u32, child_is_thread: bool, child_pdeathsig: u32) ?u32 {
    if (child_parent_tid != exiting_tid or child_is_thread or child_pdeathsig == 0) return null;
    return child_pdeathsig;
}
