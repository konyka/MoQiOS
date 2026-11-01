//! Process-wide CPU time. Every thread of a group counts toward the process,
//! the time of exited threads is kept by the group leader, and the time of a
//! child that was waited for flows up to the waiter (getrusage(RUSAGE_CHILDREN),
//! wait4's rusage).

const rusage_policy = @import("rusage_policy.zig");

pub const Times = struct {
    user_us: u64 = 0,
    sys_us: u64 = 0,
    child_user_us: u64 = 0,
    child_sys_us: u64 = 0,

    pub fn selfUs(a: Times) u64 {
        return a.user_us +| a.sys_us;
    }
};

/// One task slot of a thread group, as the scan sees it.
pub const Member = struct {
    user_us: u64,
    sys_us: u64,
    running: bool,
    is_user: bool,
    sched_in_tsc: u64,
};

/// Add a member's time (plus the slice it is executing right now, which the
/// context-switch accounting has not folded in yet) to the group total.
pub fn addMember(total: Times, m: Member, now_tsc: u64, tsc_mhz: u64) Times {
    var t = total;
    t.user_us +|= m.user_us;
    t.sys_us +|= m.sys_us;
    if (m.running) {
        const slice = rusage_policy.runtimeUs(0, m.sched_in_tsc, now_tsc, tsc_mhz);
        if (m.is_user) t.user_us +|= slice else t.sys_us +|= slice;
    }
    return t;
}

/// The group leader keeps the time of threads that were reclaimed.
pub fn foldDeadThread(leader_dead: Times, thread_user_us: u64, thread_sys_us: u64) Times {
    var t = leader_dead;
    t.user_us +|= thread_user_us;
    t.sys_us +|= thread_sys_us;
    return t;
}

pub const Usage = struct { user_us: u64 = 0, sys_us: u64 = 0 };

/// What wait4 reports for a reaped child: its own group plus the children it
/// had itself waited for.
pub fn reapedUsage(group: Times) Usage {
    return .{ .user_us = group.user_us +| group.child_user_us, .sys_us = group.sys_us +| group.child_sys_us };
}

pub fn inheritFromChild(waiter: Times, usage: Usage) Times {
    var t = waiter;
    t.child_user_us +|= usage.user_us;
    t.child_sys_us +|= usage.sys_us;
    return t;
}
