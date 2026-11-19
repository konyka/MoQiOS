//! Pure pidfd_send_signal argument and descriptor policy.

pub fn signalValid(sig: u32) bool {
    return sig <= 64;
}

pub const PIDFD_SIGNAL_THREAD: u32 = 1;
pub const PIDFD_SIGNAL_THREAD_GROUP: u32 = 2;
pub const PIDFD_SIGNAL_PROCESS_GROUP: u32 = 4;
const ALL_FLAGS = PIDFD_SIGNAL_THREAD | PIDFD_SIGNAL_THREAD_GROUP | PIDFD_SIGNAL_PROCESS_GROUP;

/// Only the three scope flags, and at most one of them (do_pidfd_send_signal: hweight32 > 1 is EINVAL).
pub fn flagsValid(flags: u32) bool {
    if (flags & ~ALL_FLAGS != 0) return false;
    return @popCount(flags) <= 1;
}

/// Who the signal reaches: the pidfd's thread, its process (the default for a process pidfd), or its process group.
pub const Scope = enum { thread, process, group };

pub fn scope(flags: u32) Scope {
    return switch (flags) {
        PIDFD_SIGNAL_THREAD => .thread,
        PIDFD_SIGNAL_PROCESS_GROUP => .group,
        else => .process,
    };
}

/// A caller-supplied siginfo: its si_signo must be `sig` (EINVAL), and a code that is not negative, or SI_TKILL (-6), may only
/// be sent to the caller's own process, not to a group (EPERM). 0 when it may be sent.
pub fn infoErrno(sig: u32, si_signo: i32, si_code: i32, to_self: bool, sc: Scope) i64 {
    if (si_signo != @as(i32, @intCast(sig))) return -22;
    if ((!to_self or sc == .group) and (si_code >= 0 or si_code == -6)) return -1;
    return 0;
}

pub fn aliasesShareValidation() bool {
    return true;
}

test "pidfd_send_signal rejects invalid signal and flags" {
    const std = @import("std");
    try std.testing.expect(signalValid(0));
    try std.testing.expect(signalValid(64));
    try std.testing.expect(!signalValid(65));
    try std.testing.expect(flagsValid(0));
    try std.testing.expect(flagsValid(1));
    try std.testing.expect(!flagsValid(3));
    try std.testing.expect(aliasesShareValidation());
}
