//! Which process-directed signals act on every thread of the target process (Linux: stops, continues and SIGKILL are group-wide).
//!
//! kill(pid, sig) names a process. SIGKILL ends every thread, SIGCONT resumes every thread, and a stop that takes its default action
//! (SIGSTOP always; SIGTSTP/SIGTTIN/SIGTTOU when no handler is installed) stops every thread, so the spinning thread of a stopped
//! process makes no progress. Any other signal, or a stop signal with a handler, is delivered once, to the process's leader.

pub const SIGKILL: u32 = 9;
pub const SIGCONT: u32 = 18;
pub const SIGSTOP: u32 = 19;
pub const SIGTSTP: u32 = 20;
pub const SIGTTIN: u32 = 21;
pub const SIGTTOU: u32 = 22;

/// Whether `signum`, sent to a process whose action for it is `handler` (0 = SIG_DFL, 1 = SIG_IGN), acts on every thread.
pub fn actsOnEveryThread(signum: u32, handler: u64) bool {
    return switch (signum) {
        SIGKILL, SIGCONT, SIGSTOP => true,
        SIGTSTP, SIGTTIN, SIGTTOU => handler == 0,
        else => false,
    };
}

/// How far one member's stop takes the group. The parent's WUNTRACED report waits for the last live member: a spinning thread must already
/// be stopped by the time waitpid returns, not merely have a pending stop bit.
pub const StopProgress = enum { already, partial, group_complete };

/// `was_stopped` is the member's flag before this stop. `others_running` is true when any other live member is not yet stopped.
pub fn completesStop(was_stopped: bool, others_running: bool) StopProgress {
    if (was_stopped) return .already;
    return if (others_running) .partial else .group_complete;
}

/// A member exits through exit() while a group stop is in progress: it will never stop, so if every other live member is already
/// stopped its exit completes the stop and the parent is told now (Linux: the exiting task drops group_stop_count). `exiting_stopped`
/// is the member's own flag (true: the group stop already completed and was reported). `live_others` / `stopped_others` count the
/// other members that have not exited, and those of them that are stopped.
pub fn exitCompletesStop(exiting_stopped: bool, live_others: u32, stopped_others: u32) bool {
    if (exiting_stopped or live_others == 0) return false;
    return stopped_others == live_others;
}

const std = @import("std");

test "SIGKILL, SIGCONT and SIGSTOP reach every thread whatever the action" {
    try std.testing.expect(actsOnEveryThread(SIGKILL, 0));
    try std.testing.expect(actsOnEveryThread(SIGCONT, 0x1234));
    try std.testing.expect(actsOnEveryThread(SIGSTOP, 0));
}

test "a terminal stop reaches every thread only when it takes its default action" {
    try std.testing.expect(actsOnEveryThread(SIGTSTP, 0));
    try std.testing.expect(!actsOnEveryThread(SIGTSTP, 0x4000)); // a handler runs once, in one thread
    try std.testing.expect(!actsOnEveryThread(SIGTTIN, 1)); // ignored
    try std.testing.expect(actsOnEveryThread(SIGTTOU, 0));
}

test "the parent's stop report waits for the last live member" {
    try std.testing.expect(completesStop(false, true) == .partial);
    try std.testing.expect(completesStop(false, false) == .group_complete);
    try std.testing.expect(completesStop(true, false) == .already);
    try std.testing.expect(completesStop(true, true) == .already);
}

test "a member that exits instead of stopping completes a group stop in progress" {
    try std.testing.expect(exitCompletesStop(false, 2, 2));
    try std.testing.expect(!exitCompletesStop(false, 2, 1)); // another member still runs: its own stop reports
    try std.testing.expect(!exitCompletesStop(true, 2, 2)); // already reported
    try std.testing.expect(!exitCompletesStop(false, 0, 0)); // nobody left: the process exits instead
}

test "other signals are delivered once" {
    try std.testing.expect(!actsOnEveryThread(15, 0));
    try std.testing.expect(!actsOnEveryThread(10, 0x4000));
    try std.testing.expect(!actsOnEveryThread(17, 0));
}
