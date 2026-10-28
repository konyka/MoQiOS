// kernel/proc/current_groups.zig — the calling task's supplementary groups,
// for credential structs built from (euid, egid, caps) arguments that were
// copied out of the current task. Kernel-internal callers pass synthetic
// credentials; those get no groups.

const sched = @import("sched.zig");

pub fn forCaller(euid: u32, egid: u32) []const u32 {
    const cur = sched.currentTask() orelse return &.{};
    if (!cur.is_user or cur.euid != euid or cur.egid != egid) return &.{};
    return cur.groups[0..cur.ngroups];
}
