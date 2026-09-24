//! Pure authorization policy for native IPC endpoint destruction.

pub fn canDestroy(owner_task_idx: ?u32, caller_task_idx: u32) bool {
    return owner_task_idx != null and owner_task_idx.? == caller_task_idx;
}

test "only the endpoint owner may destroy it" {
    const std = @import("std");
    try std.testing.expect(canDestroy(4, 4));
    try std.testing.expect(!canDestroy(4, 5));
    try std.testing.expect(!canDestroy(null, 4));
}
