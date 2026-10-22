//! Pure signal-send permission rules shared by every signal entry point
//! (kill, tkill, rt_sigqueueinfo, rt_tgsigqueueinfo, pidfd_send_signal).
//!
//! Current rule: signalling yourself is always allowed; anything else needs
//! cap_kill. Same-uid relaxation is intentionally not part of this policy.

/// May `sender_tid` send a signal to the single task `target_tid`?
pub fn maySignalTask(sender_tid: u32, target_tid: u32, has_cap_kill: bool) bool {
    return has_cap_kill or sender_tid == target_tid;
}

/// May `sender_tid` issue kill(pid, ...)? `pid` is the raw signed syscall
/// argument: > 0 targets one task (compared at full width, so a value whose
/// low 32 bits alias the sender is not "self"); < 0 targets a process group
/// or everyone and always needs cap_kill; 0 is left to kill() itself, which
/// has no target for it.
pub fn mayKill(sender_tid: u32, pid: i64, has_cap_kill: bool) bool {
    if (has_cap_kill) return true;
    if (pid == 0) return true;
    if (pid > 0) return pid == @as(i64, sender_tid);
    return false;
}
