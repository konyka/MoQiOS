/// Pure SysV shared-memory flag, range, and permission policy.
pub const SHM_RDONLY: u64 = 0o10000;
pub const SHM_RND: u64 = 0o20000;
pub const SHM_REMAP: u64 = 0o40000;
pub const SHM_EXEC: u64 = 0o100000;
pub const SUPPORTED_FLAGS: u64 = SHM_RDONLY | SHM_RND | SHM_REMAP | SHM_EXEC;

pub const ExistingLookup = enum {
    allow,
    exists,
    access_denied,
};

pub fn flagsValid(flags: u64) bool {
    return flags & ~SUPPORTED_FLAGS == 0;
}

pub fn rangeEnd(base: u64, size: u64, user_max: u64) ?u64 {
    const result = @addWithOverflow(base, size);
    if (result[1] != 0 or base >= user_max or result[0] > user_max) return null;
    return result[0];
}

/// Return whether `requested` access is granted by the segment mode.
/// `class_bits` is the selected owner/group/other mode triplet.
pub fn modeAllows(mode: u32, class_bits: u5, requested: u5) bool {
    return (mode >> class_bits & requested) == requested;
}

pub fn existingLookup(
    create_exclusive: bool,
    requested_mode: u32,
    segment_mode: u32,
    owner: @import("sysv_policy.zig").Owner,
    credentials: @import("sysv_policy.zig").Credentials,
) ExistingLookup {
    if (create_exclusive) return .exists;
    return if (@import("sysv_policy.zig").modeAllows(
        segment_mode,
        owner,
        credentials,
        requested_mode & 0o400 != 0,
        requested_mode & 0o200 != 0,
    )) .allow else .access_denied;
}

test "shared-memory policy rejects unknown flags and wrapped ranges" {
    const std = @import("std");
    try std.testing.expect(flagsValid(SHM_RDONLY | SHM_EXEC));
    try std.testing.expect(!flagsValid(1));
    try std.testing.expect(rangeEnd(0x7000_0000, 4096, 0x8000_0000_0000) != null);
    try std.testing.expect(rangeEnd(std.math.maxInt(u64) - 4095, 8192, std.math.maxInt(u64)) == null);
    try std.testing.expect(modeAllows(0o640, 6, 0o4));
    try std.testing.expect(!modeAllows(0o640, 6, 0o2));
}

test "existing shmget lookup preserves exclusive and access semantics" {
    const std = @import("std");
    const owner: @import("sysv_policy.zig").Owner = .{ .uid = 10, .gid = 20, .cuid = 10, .cgid = 20 };
    const other: @import("sysv_policy.zig").Credentials = .{ .euid = 99, .egid = 99 };

    try std.testing.expectEqual(ExistingLookup.exists, existingLookup(true, 0, 0o600, owner, other));
    try std.testing.expectEqual(ExistingLookup.allow, existingLookup(false, 0, 0o600, owner, other));
    try std.testing.expectEqual(ExistingLookup.access_denied, existingLookup(false, 0o400, 0o600, owner, other));
    try std.testing.expectEqual(ExistingLookup.allow, existingLookup(false, 0o400, 0o604, owner, other));
    try std.testing.expectEqual(ExistingLookup.allow, existingLookup(false, 0o600, 0, owner, .{ .euid = 0, .egid = 0 }));
}
