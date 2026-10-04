//! Pure model for task slot incarnation and generic lifetime references.

const std = @import("std");

pub const Slot = struct {
    incarnation: u64 = 0,
    live: bool = false,
    zombie: bool = false,
    refs: u32 = 0,
};

pub const Ref = struct {
    slot: u32,
    incarnation: u64,
    released: bool = false,
};

pub fn beginSlot(slot: *Slot) void {
    slot.incarnation +%= 1;
    if (slot.incarnation == 0) slot.incarnation = 1;
    slot.live = true;
    slot.zombie = false;
    slot.refs = 0;
}

pub fn pin(slot: *Slot) ?Ref {
    if (!slot.live or slot.zombie) return null;
    if (slot.refs == std.math.maxInt(u32)) return null;
    slot.refs += 1;
    return .{ .slot = 0, .incarnation = slot.incarnation };
}

pub fn markZombie(slot: *Slot) bool {
    if (!slot.live or slot.zombie) return false;
    slot.zombie = true;
    return true;
}

pub fn reap(slot: *Slot) bool {
    if (!slot.zombie or slot.refs != 0) return false;
    slot.live = false;
    return true;
}

pub fn release(slot: *Slot, reference: *Ref) bool {
    if (reference.released or reference.incarnation != slot.incarnation or slot.refs == 0) {
        reference.released = true;
        return false;
    }
    slot.refs -= 1;
    reference.released = true;
    return true;
}

test "task lifetime refs block reap and reject stale release" {
    var slot = Slot{};
    beginSlot(&slot);
    var reference = pin(&slot).?;
    try std.testing.expect(markZombie(&slot));
    try std.testing.expect(!reap(&slot));
    try std.testing.expect(release(&slot, &reference));
    try std.testing.expect(!release(&slot, &reference));
    try std.testing.expect(reap(&slot));
    beginSlot(&slot);
    try std.testing.expect(slot.incarnation != reference.incarnation);
    try std.testing.expect(!release(&slot, &reference));
}
