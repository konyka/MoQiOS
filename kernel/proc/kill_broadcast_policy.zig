//! Pure kill(-1, sig) rules (Linux kill_something_info).
//!
//! The broadcast reaches every user process except init and the caller's
//! own thread group, once per process (thread-group leaders only). Targets
//! the caller may not signal are skipped. The result is -ESRCH only when no
//! candidate exists at all; a refusal (EPERM) does not override success, so
//! when every candidate refuses the call still returns 0, as on Linux.

pub const ESRCH: i64 = -3;

pub const Candidate = struct {
    is_user: bool,
    is_thread: bool,
    zombie: bool,
    is_init: bool,
    same_thread_group: bool,
};

pub fn isTarget(c: Candidate) bool {
    return c.is_user and !c.is_thread and !c.zombie and !c.is_init and !c.same_thread_group;
}

pub fn result(candidates: u32) i64 {
    return if (candidates == 0) ESRCH else 0;
}
