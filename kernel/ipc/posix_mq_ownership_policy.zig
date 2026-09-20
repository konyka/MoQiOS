//! Pure per-task reference accounting for POSIX message-queue descriptors.

pub const State = struct {
    refs: u32 = 0,
};

pub fn acquire(state: *State) void {
    state.refs += 1;
}

pub fn release(state: *State) bool {
    if (state.refs == 0) return false;
    state.refs -= 1;
    return true;
}

pub fn inheritedReferences(parent_refs: u32) u32 {
    return parent_refs;
}

test "MQ ownership rejects a close without an owned reference" {
    const std = @import("std");
    var state = State{};
    try std.testing.expect(!release(&state));
    acquire(&state);
    acquire(&state);
    try std.testing.expect(release(&state));
    try std.testing.expectEqual(@as(u32, 1), state.refs);
    try std.testing.expectEqual(@as(u32, 3), inheritedReferences(3));
}
