//! Pure lifecycle policy for guarded SysV SHM detach.

pub fn detachAllowed(has_mm: bool, vm_guard_acquired: bool) bool {
    return has_mm and vm_guard_acquired;
}

pub fn unmapOnExit(mm_shared_before_guard: bool) bool {
    return !mm_shared_before_guard;
}

test "SHM exit detach requires a VM mutation guard" {
    const std = @import("std");
    try std.testing.expect(detachAllowed(true, true));
    try std.testing.expect(!detachAllowed(false, true));
    try std.testing.expect(!detachAllowed(true, false));
    try std.testing.expect(unmapOnExit(false));
    try std.testing.expect(!unmapOnExit(true));
}
