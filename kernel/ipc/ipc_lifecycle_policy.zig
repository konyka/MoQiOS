//! Pure endpoint lifecycle policy.

pub fn shouldReclaim(owner_task_idx: ?u32, exiting_task_idx: u32) bool {
    return owner_task_idx != null and owner_task_idx.? == exiting_task_idx;
}

pub fn wakeResult(endpoint_invalidated: bool, signal_interrupted: bool) i32 {
    if (endpoint_invalidated) return -1;
    if (signal_interrupted) return -4;
    return 0;
}

pub fn clearsBlockedState(wake_with_message: bool, wake_with_error: bool) bool {
    return wake_with_message or wake_with_error;
}

test "IPC endpoint is reclaimed only by its owner task exit" {
    const std = @import("std");
    try std.testing.expect(shouldReclaim(7, 7));
    try std.testing.expect(!shouldReclaim(7, 8));
    try std.testing.expect(!shouldReclaim(null, 7));
    try std.testing.expectEqual(@as(i32, -1), wakeResult(true, false));
    try std.testing.expectEqual(@as(i32, -4), wakeResult(false, true));
    try std.testing.expectEqual(@as(i32, 0), wakeResult(false, false));
    try std.testing.expect(clearsBlockedState(true, false));
    try std.testing.expect(clearsBlockedState(false, true));
    try std.testing.expect(!clearsBlockedState(false, false));
}
