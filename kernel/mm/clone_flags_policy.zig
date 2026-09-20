//! Phase-0 strict validation for the implemented clone ABI surface.

pub const CLONE_VM: u64 = 0x100;
pub const CLONE_FS: u64 = 0x200;
pub const CLONE_FILES: u64 = 0x400;
pub const CLONE_SIGHAND: u64 = 0x800;
pub const CLONE_THREAD: u64 = 0x10000;
pub const CLONE_SETTLS: u64 = 0x80000;
pub const CLONE_PARENT_SETTID: u64 = 0x100000;
pub const CLONE_CHILD_CLEARTID: u64 = 0x200000;

// CLONE_FS/CLONE_SIGHAND/CLONE_THREAD do not yet have shared-object
// lifetimes, so accepting them would silently provide copy semantics.
pub const IMPLEMENTED_FLAGS: u64 = CLONE_VM | CLONE_FILES | CLONE_SETTLS;
pub const TID_FLAGS: u64 = CLONE_PARENT_SETTID | CLONE_CHILD_CLEARTID;

pub fn pointerRequired(flags: u64, bit: u64) bool {
    return flags & bit != 0;
}

pub fn valid(flags: u64, has_mm: bool) bool {
    if (flags & ~(IMPLEMENTED_FLAGS | TID_FLAGS) != 0) return false;
    if (flags & TID_FLAGS != 0 and flags & CLONE_VM == 0) return false;
    if (flags & CLONE_VM != 0 and !has_mm) return false;
    return true;
}

test "clone policy rejects ignored TID flags and incoherent thread combinations" {
    const std = @import("std");
    try std.testing.expect(!valid(CLONE_VM | CLONE_THREAD | CLONE_SIGHAND, true));
    try std.testing.expect(!valid(CLONE_THREAD, true));
    try std.testing.expect(!valid(CLONE_SIGHAND, true));
    try std.testing.expect(valid(CLONE_VM | CLONE_PARENT_SETTID, true));
    try std.testing.expect(valid(CLONE_VM | CLONE_CHILD_CLEARTID, true));
    try std.testing.expect(!valid(CLONE_VM, false));
}
