// kernel/proc/group_policy.zig — supplementary groups (getgroups(2)/setgroups(2)).

/// Per-task capacity. Linux allows 65536; a small fixed table keeps the task
/// struct bounded. setgroups beyond it is EINVAL, as Linux does past its own
/// NGROUPS_MAX.
pub const NGROUPS_MAX: u32 = 32;

/// Does a caller with effective group `egid` and supplementary `groups`
/// belong to `gid` for permission checks (the group class of a mode)?
pub fn member(egid: u32, groups: []const u32, gid: u32) bool {
    if (egid == gid) return true;
    for (groups) |g| {
        if (g == gid) return true;
    }
    return false;
}

pub const GetResult = union(enum) {
    /// size == 0: report the count, copy nothing.
    count: u32,
    /// copy this many entries.
    copy: u32,
    einval,
};

/// getgroups(size, list): size 0 asks for the count; otherwise the buffer
/// must hold every group (EINVAL when it is too small).
pub fn get(size: i64, ngroups: u32) GetResult {
    if (size < 0) return .einval;
    if (size == 0) return .{ .count = ngroups };
    if (@as(u64, @intCast(size)) < ngroups) return .einval;
    return .{ .copy = ngroups };
}

pub const SetCheck = enum { ok, eperm, einval };

/// setgroups(size, list): replacing the list needs CAP_SETGID.
pub fn checkSet(size: i64, cap_setgid: bool) SetCheck {
    if (!cap_setgid) return .eperm;
    if (size < 0 or size > NGROUPS_MAX) return .einval;
    return .ok;
}
