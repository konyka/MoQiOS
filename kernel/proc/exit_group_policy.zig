//! exit_group: the whole thread group ends with one status (Linux `signal->group_exit_code`).
//!
//! The caller's status is recorded on every live member before they are sent SIGKILL. Each member then dies through its usual
//! fatal path, and exitTask replaces the 128+SIGKILL code it would have recorded with the group's status, reported as a normal
//! exit. So the leader's waitpid status is the exit_group argument whichever thread made the call. When two threads call
//! exit_group at once, the first status recorded on a member stays.

pub const Final = struct {
    code: i32,
    /// Report as a normal exit (WIFEXITED), not as a signal death.
    via_exit_syscall: bool,
};

/// The status a member keeps when a group exit with `code` reaches it.
pub fn claim(existing: ?u8, code: u8) u8 {
    return existing orelse code;
}

/// What exitTask records for a task whose own path asked for `own_code`.
pub fn finalStatus(group_code: ?u8, own_code: i32, own_via_exit_syscall: bool) Final {
    if (group_code) |g| return .{ .code = g, .via_exit_syscall = true };
    return .{ .code = own_code, .via_exit_syscall = own_via_exit_syscall };
}

const std = @import("std");

test "the first group status recorded on a member stays" {
    try std.testing.expectEqual(@as(u8, 42), claim(null, 42));
    try std.testing.expectEqual(@as(u8, 42), claim(42, 33));
}

test "a member killed by the group exit reports the group status as a normal exit" {
    const f = finalStatus(33, 128 + 9, false);
    try std.testing.expectEqual(@as(i32, 33), f.code);
    try std.testing.expect(f.via_exit_syscall);
}

test "without a group exit the task's own status is kept" {
    const f = finalStatus(null, 128 + 9, false);
    try std.testing.expectEqual(@as(i32, 137), f.code);
    try std.testing.expect(!f.via_exit_syscall);
    try std.testing.expect(finalStatus(null, 5, true).via_exit_syscall);
}
