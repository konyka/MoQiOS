//! Pure epoll pool lifetime policy.

pub const State = enum { free, open, closing };

pub const Slot = struct {
    state: State = .free,
    generation: u64 = 0,
    active_ops: u32 = 0,
};

pub fn acquire(slot: *Slot, generation: u64) bool {
    if (slot.state != .open or slot.generation != generation) return false;
    slot.active_ops += 1;
    return true;
}

pub fn release(slot: *Slot) bool {
    if (slot.active_ops == 0) return false;
    slot.active_ops -= 1;
    return true;
}

pub fn beginClose(slot: *Slot, generation: u64) bool {
    if (slot.state != .open or slot.generation != generation) return false;
    slot.state = .closing;
    return true;
}

pub fn recyclable(slot: Slot) bool {
    return slot.state == .closing and slot.active_ops == 0;
}

pub fn recycle(slot: *Slot) bool {
    if (!recyclable(slot.*)) return false;
    slot.state = .free;
    slot.generation +%= 1;
    return true;
}

test "epoll lifetime rejects stale and closing borrows" {
    var slot: Slot = .{ .state = .open, .generation = 4 };
    try @import("std").testing.expect(acquire(&slot, 4));
    try @import("std").testing.expect(!beginClose(&slot, 3));
    try @import("std").testing.expect(beginClose(&slot, 4));
    try @import("std").testing.expect(!recyclable(slot));
    try @import("std").testing.expect(release(&slot));
    try @import("std").testing.expect(recyclable(slot));
    try @import("std").testing.expect(recycle(&slot));
    try @import("std").testing.expectEqual(@as(u64, 5), slot.generation);
}
