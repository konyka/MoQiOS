//! Pure POSIX message-queue priority selection.

pub const Slot = struct {
    used: bool = false,
    priority: u32 = 0,
};

pub fn selectHighest(slots: []const Slot, head: u32) ?u32 {
    if (slots.len == 0) return null;
    var selected: ?u32 = null;
    var selected_priority: u32 = 0;
    for (0..slots.len) |offset| {
        const index: u32 = @intCast((@as(usize, @intCast(head)) + offset) % slots.len);
        const slot = slots[index];
        if (!slot.used) continue;
        if (selected == null or slot.priority > selected_priority) {
            selected = index;
            selected_priority = slot.priority;
        }
    }
    return selected;
}

pub fn nextFree(slots: []const Slot, start: u32) ?u32 {
    if (slots.len == 0) return null;
    for (0..slots.len) |offset| {
        const index: u32 = @intCast((@as(usize, @intCast(start)) + offset) % slots.len);
        if (!slots[index].used) return index;
    }
    return null;
}

test "priority selection returns highest priority and preserves FIFO ties" {
    const std = @import("std");
    const slots = [_]Slot{
        .{ .used = true, .priority = 2 },
        .{ .used = true, .priority = 7 },
        .{ .used = true, .priority = 7 },
        .{},
    };
    try std.testing.expectEqual(@as(?u32, 1), selectHighest(&slots, 0));
    try std.testing.expectEqual(@as(?u32, 2), selectHighest(&slots, 2));
    try std.testing.expect(selectHighest(&[_]Slot{.{}}, 0) == null);
    try std.testing.expectEqual(@as(?u32, 3), nextFree(&slots, 3));
    try std.testing.expectEqual(@as(?u32, 3), nextFree(&slots, 0));
}
