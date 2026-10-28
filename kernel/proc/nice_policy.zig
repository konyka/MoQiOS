//! Who may change a process's nice value (setpriority PRIO_PROCESS).
//! Linux rules: the caller must own the target (its effective uid matches the
//! target's real or effective uid) unless it holds CAP_SYS_NICE (root holds it
//! by default; uid 0 without it is an ordinary user), and lowering the nice value (raising priority) always
//! needs CAP_SYS_NICE.

pub const Request = struct {
    caller_euid: u32,
    caller_uid: u32,
    target_uid: u32,
    target_euid: u32,
    cap_sys_nice: bool,
    current_nice: i32,
    new_nice: i32,
};

pub fn maySetNice(r: Request) bool {
    const privileged = r.cap_sys_nice;
    if (privileged) return true;
    if (!owns(r.caller_euid, r.caller_uid, r.target_uid, r.target_euid)) return false;
    return r.new_nice >= r.current_nice;
}

/// Caller owns `target` in the Linux sense used by the scheduler calls: its
/// effective uid matches the target's real or effective uid, or its real uid
/// matches the target's real uid.
pub fn owns(caller_euid: u32, caller_uid: u32, target_uid: u32, target_euid: u32) bool {
    return caller_euid == target_uid or caller_euid == target_euid or caller_uid == target_uid;
}

/// sched_setscheduler / sched_setattr / sched_setaffinity on `target`.
/// Non-owners need CAP_SYS_NICE; switching into a realtime class always does
/// (RLIMIT_RTPRIO is not implemented, so its limit is 0 as on Linux).
pub fn maySetScheduling(caller_euid: u32, caller_uid: u32, target_uid: u32, target_euid: u32, cap_sys_nice: bool, wants_rt: bool) bool {
    if (cap_sys_nice) return true;
    if (!owns(caller_euid, caller_uid, target_uid, target_euid)) return false;
    return !wants_rt;
}

/// kcmp exposes kernel object identity: only for processes the caller owns
/// (stand-in for Linux's PTRACE_MODE_READ check) unless it is privileged.
pub fn mayKcmp(caller_euid: u32, caller_uid: u32, target_uid: u32, target_euid: u32, cap_sys_ptrace: bool) bool {
    if (cap_sys_ptrace) return true;
    return owns(caller_euid, caller_uid, target_uid, target_euid);
}
