const std = @import("std");
const mb = @import("kernel_shared").nvme_mailbox;

/// Run every ordering of the events that can follow the doorbell: the device
/// completing the command, the interrupt handler running (any number of times,
/// including before the device completes, which is spurious), and the
/// submitter entering its wait. Returns how many orderings leave the submitter
/// asleep with nobody able to wake it.
fn stuckOrderings(reset_before_doorbell: bool, legacy_clear: bool) !u32 {
    var stuck_count: u32 = 0;
    const Ev = enum { device, isr, wait };
    // permutations of {device, isr, wait} with isr allowed to appear 1 or 2 times
    const seqs = [_][]const Ev{
        &.{ .device, .isr, .wait },
        &.{ .device, .wait, .isr },
        &.{ .wait, .device, .isr },
        &.{ .device, .isr, .isr, .wait },
        &.{ .isr, .device, .isr, .wait },
        &.{ .isr, .device, .wait, .isr },
        &.{ .device, .isr, .wait, .isr },
        &.{ .wait, .isr, .device, .isr },
    };
    for (seqs) |seq| {
        var s: mb.State = .{};
        mb.submit(&s, reset_before_doorbell);
        for (seq) |ev| switch (ev) {
            .device => mb.deviceCompletes(&s),
            .isr => _ = mb.isr(&s),
            .wait => mb.enterWait(&s, legacy_clear),
        };
        mb.afterWake(&s);
        if (mb.stuck(s)) stuck_count += 1;
    }
    return stuck_count;
}

test "the old protocol can leave the submitter asleep forever" {
    // Clearing the mailbox when the wait starts erases a completion the handler
    // already delivered: this is the captured hang.
    try std.testing.expect(try stuckOrderings(false, true) > 0);
}

test "resetting at submit and taking a delivered result never gets stuck" {
    try std.testing.expectEqual(@as(u32, 0), try stuckOrderings(true, false));
}

test "each half of the fix is needed on its own" {
    // Reset at submit but still clear on entering the wait: the clear is the bug.
    try std.testing.expect(try stuckOrderings(true, true) > 0);
    // Do not reset at submit: a previous command's stale flag would be taken
    // for this command's completion.
    var s: mb.State = .{ .done = true, .has_result = true };
    mb.submit(&s, false);
    mb.enterWait(&s, false);
    try std.testing.expect(s.got); // wrongly satisfied by the stale flag
    var t: mb.State = .{ .done = true, .has_result = true };
    mb.submit(&t, true);
    mb.enterWait(&t, false);
    try std.testing.expect(!t.got); // the reset removed the stale flag
    try std.testing.expect(t.linked);
}

test "a woken submitter always finds its result" {
    var s: mb.State = .{};
    mb.submit(&s, true);
    mb.enterWait(&s, false); // sleeps
    mb.deviceCompletes(&s);
    try std.testing.expect(mb.isr(&s));
    mb.afterWake(&s);
    try std.testing.expect(s.got);
    try std.testing.expect(!mb.stuck(s));
}

test "a spurious interrupt neither wakes nor loses anything" {
    var s: mb.State = .{};
    mb.submit(&s, true);
    try std.testing.expect(!mb.isr(&s)); // nothing completed yet
    mb.enterWait(&s, false);
    try std.testing.expect(s.linked and !s.woken and !s.got);
    mb.deviceCompletes(&s);
    _ = mb.isr(&s);
    mb.afterWake(&s);
    try std.testing.expect(s.got);
}
