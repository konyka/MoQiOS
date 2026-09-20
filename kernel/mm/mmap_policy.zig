//! Pure validation for the mmap syscall's supported ABI bits.

pub const MAP_SHARED: u64 = 0x1;
pub const MAP_PRIVATE: u64 = 0x2;
pub const MAP_FIXED: u64 = 0x10;
pub const MAP_ANONYMOUS: u64 = 0x20;

pub const SUPPORTED_MAP_FLAGS: u64 = MAP_SHARED | MAP_PRIVATE | MAP_FIXED |
    MAP_ANONYMOUS;
pub const SUPPORTED_PROT_FLAGS: u64 = 0x1 | 0x2 | 0x4;

pub fn flagsValid(flags: u64) bool {
    if (flags & ~SUPPORTED_MAP_FLAGS != 0) return false;
    const sharing = flags & (MAP_SHARED | MAP_PRIVATE);
    return sharing == MAP_SHARED or sharing == MAP_PRIVATE;
}

pub fn protValid(prot: u64) bool {
    return prot & ~SUPPORTED_PROT_FLAGS == 0;
}

pub fn anonymousFlagsValid(flags: u64) bool {
    _ = flags;
    return true;
}

pub fn isAnonymous(flags: u64) bool {
    return flags & MAP_ANONYMOUS != 0;
}

test "mmap does not infer anonymous mappings from a sentinel fd" {
    const std = @import("std");
    try std.testing.expect(!isAnonymous(MAP_PRIVATE));
}

test "mmap policy rejects unknown bits and conflicting sharing modes" {
    const std = @import("std");
    try std.testing.expect(flagsValid(MAP_PRIVATE | MAP_ANONYMOUS));
    try std.testing.expect(flagsValid(MAP_SHARED | MAP_FIXED));
    try std.testing.expect(!flagsValid(MAP_PRIVATE | MAP_SHARED));
    try std.testing.expect(!flagsValid(MAP_PRIVATE | (1 << 63)));
    try std.testing.expect(!flagsValid(MAP_PRIVATE | 0x8000));
    try std.testing.expect(protValid(0));
    try std.testing.expect(protValid(0x1 | 0x2 | 0x4));
    try std.testing.expect(!protValid(0x8));
    try std.testing.expect(anonymousFlagsValid(MAP_PRIVATE | MAP_ANONYMOUS));
    try std.testing.expect(anonymousFlagsValid(MAP_SHARED | MAP_ANONYMOUS));
}
