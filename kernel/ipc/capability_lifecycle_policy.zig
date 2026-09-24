//! Pure lifecycle policy for task-scoped IPC capabilities.

pub fn clearOnExit(task_idx: u32, valid: bool) bool {
    return valid and task_idx < 64;
}

test "task exit clears capabilities before slot reuse" {
    const std = @import("std");
    try std.testing.expect(clearOnExit(3, true));
    try std.testing.expect(!clearOnExit(3, false));
}
