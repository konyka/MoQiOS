//! Who may change a process's nice value (setpriority PRIO_PROCESS).
//! Linux rules: the caller must own the target (its effective uid matches the
//! target's real or effective uid) unless it holds CAP_SYS_NICE (uid 0 counts
//! as holding it), and lowering the nice value (raising priority) always
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
    const privileged = r.caller_euid == 0 or r.cap_sys_nice;
    if (privileged) return true;
    const owns = r.caller_euid == r.target_uid or r.caller_euid == r.target_euid or r.caller_uid == r.target_uid;
    if (!owns) return false;
    return r.new_nice >= r.current_nice;
}
