//! Pure rules for reporting a live child's stop and continue to its parent (Linux wait_task_stopped / wait_task_continued and
//! do_notify_parent_cldstop).
//!
//!   stopped by sig:  (sig << 8) | 0x7f    WIFSTOPPED, WSTOPSIG     reported once, only with WUNTRACED
//!   continued:       0xffff               WIFCONTINUED             reported once, only with WCONTINUED
//!
//! A stop discards an unreported continue and a continue discards an unreported stop, so a child is never reported as both. The parent
//! gets SIGCHLD (CLD_STOPPED / CLD_CONTINUED) for either change unless its SIGCHLD action has SA_NOCLDSTOP.

pub const WUNTRACED: u32 = 0x2;
pub const WCONTINUED: u32 = 0x8;
pub const SA_NOCLDSTOP: u64 = 0x1;
pub const CONTINUED_STATUS: i32 = 0xffff;

/// What a child has to report besides its exit: the signal that stopped it (0 when none) and whether it was continued.
pub const Pending = struct {
    stop_sig: u8 = 0,
    continued: bool = false,
};

pub const Change = union(enum) {
    stopped: u8,
    continued,
};

/// The pending reports after `change`.
pub fn record(change: Change) Pending {
    return switch (change) {
        .stopped => |sig| .{ .stop_sig = sig },
        .continued => .{ .continued = true },
    };
}

pub fn stoppedStatus(sig: u8) i32 {
    return (@as(i32, sig) << 8) | 0x7f;
}

/// The status waitpid(…, options) reports for a live child with `p` pending, if any.
pub fn report(options: u32, p: Pending) ?i32 {
    if (p.stop_sig != 0 and options & WUNTRACED != 0) return stoppedStatus(p.stop_sig);
    if (p.continued and options & WCONTINUED != 0) return CONTINUED_STATUS;
    return null;
}

/// The pending reports left after `report` returned `status`: each report is consumed by the wait that returns it.
pub fn consume(p: Pending, status: i32) Pending {
    var left = p;
    if (status == CONTINUED_STATUS) left.continued = false else left.stop_sig = 0;
    return left;
}

/// Whether the parent gets SIGCHLD for a stop or continue, given the flags of its SIGCHLD action.
pub fn notifiesParent(parent_sigchld_flags: u64) bool {
    return parent_sigchld_flags & SA_NOCLDSTOP == 0;
}

const std = @import("std");

test "a stop is reported as (sig << 8) | 0x7f and only to WUNTRACED" {
    const p = record(.{ .stopped = 19 });
    try std.testing.expectEqual(@as(?i32, 0x137f), report(WUNTRACED, p));
    try std.testing.expectEqual(@as(?i32, 0x157f), report(WUNTRACED, record(.{ .stopped = 21 })));
    try std.testing.expectEqual(@as(?i32, null), report(0, p));
    try std.testing.expectEqual(@as(?i32, null), report(WCONTINUED, p));
}

test "a continue is reported as 0xffff and only to WCONTINUED" {
    const p = record(.continued);
    try std.testing.expectEqual(@as(?i32, 0xffff), report(WCONTINUED, p));
    try std.testing.expectEqual(@as(?i32, null), report(WUNTRACED, p));
    try std.testing.expectEqual(@as(?i32, 0xffff), report(WUNTRACED | WCONTINUED, p));
}

test "each report is consumed once and a new change replaces the old one" {
    const p = record(.{ .stopped = 19 });
    const after = consume(p, report(WUNTRACED, p).?);
    try std.testing.expectEqual(@as(?i32, null), report(WUNTRACED | WCONTINUED, after));
    const c = record(.continued);
    try std.testing.expectEqual(@as(u8, 0), c.stop_sig);
    try std.testing.expectEqual(@as(?i32, null), report(WCONTINUED, consume(c, CONTINUED_STATUS)));
    try std.testing.expect(!record(.{ .stopped = 19 }).continued);
}

test "SA_NOCLDSTOP suppresses the SIGCHLD for stops and continues" {
    try std.testing.expect(notifiesParent(0));
    try std.testing.expect(notifiesParent(0x10000000));
    try std.testing.expect(!notifiesParent(SA_NOCLDSTOP));
    try std.testing.expect(!notifiesParent(SA_NOCLDSTOP | 0x4));
}
