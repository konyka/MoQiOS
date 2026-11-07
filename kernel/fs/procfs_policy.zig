//! Who may open which /proc/<pid>/ file. Linux (as an unprivileged user, measured): the memory map of another user's process is EACCES,
//! because reading it needs ptrace access to that process; status, stat and cmdline of other users' processes open. A process always
//! reaches its own files, and CAP_SYS_PTRACE reaches everyone's.
const std = @import("std");

pub const Verdict = enum { allow, deny };

/// `names_maps`: the file is the memory map. `same_user`: the caller's effective uid equals the target's. `ptrace_cap`: the caller holds
/// CAP_SYS_PTRACE.
pub fn pidFile(names_maps: bool, same_user: bool, ptrace_cap: bool) Verdict {
    if (!names_maps) return .allow;
    if (same_user or ptrace_cap) return .allow;
    return .deny;
}

test "procfs policy: only another user's maps is refused, and CAP_SYS_PTRACE or the same user lifts it" {
    try std.testing.expectEqual(Verdict.allow, pidFile(false, false, false));
    try std.testing.expectEqual(Verdict.allow, pidFile(true, true, false));
    try std.testing.expectEqual(Verdict.allow, pidFile(true, false, true));
    try std.testing.expectEqual(Verdict.deny, pidFile(true, false, false));
}
