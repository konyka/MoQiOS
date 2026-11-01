//! Pure validation for the mmap syscall's supported ABI bits.

pub const MAP_SHARED: u64 = 0x1;
pub const MAP_PRIVATE: u64 = 0x2;
pub const MAP_FIXED: u64 = 0x10;
pub const MAP_ANONYMOUS: u64 = 0x20;
pub const MAP_GROWSDOWN: u64 = 0x100;
pub const MAP_DENYWRITE: u64 = 0x800;
pub const MAP_EXECUTABLE: u64 = 0x1000;
pub const MAP_NORESERVE: u64 = 0x4000;
pub const MAP_POPULATE: u64 = 0x8000;
pub const MAP_NONBLOCK: u64 = 0x10000;
pub const MAP_STACK: u64 = 0x20000;
pub const MAP_FIXED_NOREPLACE: u64 = 0x100000;

/// Flags that are pure hints here (Linux itself ignores several of them): accepted and not acted on.
/// MAP_GROWSDOWN is accepted but the mapping does not grow downwards on a fault below it.
pub const HINT_FLAGS: u64 = MAP_GROWSDOWN | MAP_DENYWRITE | MAP_EXECUTABLE | MAP_NORESERVE | MAP_POPULATE | MAP_NONBLOCK | MAP_STACK;

pub const SUPPORTED_MAP_FLAGS: u64 = MAP_SHARED | MAP_PRIVATE | MAP_FIXED |
    MAP_ANONYMOUS | MAP_FIXED_NOREPLACE | HINT_FLAGS;
pub const SUPPORTED_PROT_FLAGS: u64 = 0x1 | 0x2 | 0x4;

pub fn flagsValid(flags: u64) bool {
    if (flags & ~SUPPORTED_MAP_FLAGS != 0) return false;
    const sharing = flags & (MAP_SHARED | MAP_PRIVATE);
    return sharing == MAP_SHARED or sharing == MAP_PRIVATE;
}

/// Linux ignores protection bits it does not know (PROT_GROWSDOWN and the like); only the three
/// access bits take effect.
pub fn normalizeProt(prot: u64) u64 {
    return prot & SUPPORTED_PROT_FLAGS;
}

/// Largest file offset a mapping may reach (MAX_LFS_FILESIZE).
pub const MAX_FILE_BYTES: u64 = 0x7fff_ffff_ffff_ffff;

/// A file mapping whose end offset would pass the largest file size is EOVERFLOW. `length` is the
/// caller's length, rounded up here; a length that wraps when rounded is the caller's ENOMEM.
pub fn fileOffsetOverflows(offset: u64, length: u64) bool {
    const r = @addWithOverflow(length, 4095);
    if (r[1] != 0) return false;
    const up = r[0] & ~@as(u64, 4095);
    return up > MAX_FILE_BYTES or offset > MAX_FILE_BYTES - up;
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

test "mmap policy rejects unknown flag bits and conflicting sharing modes, ignores unknown prot bits" {
    const std = @import("std");
    try std.testing.expect(flagsValid(MAP_PRIVATE | MAP_ANONYMOUS));
    try std.testing.expect(flagsValid(MAP_SHARED | MAP_FIXED));
    try std.testing.expect(flagsValid(MAP_PRIVATE | MAP_ANONYMOUS | MAP_STACK | MAP_POPULATE | MAP_NORESERVE));
    try std.testing.expect(flagsValid(MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE));
    try std.testing.expect(!flagsValid(MAP_PRIVATE | MAP_SHARED));
    try std.testing.expect(!flagsValid(MAP_PRIVATE | (1 << 63)));
    try std.testing.expect(!flagsValid(MAP_PRIVATE | 0x2000)); // MAP_LOCKED: pinning is not implemented
    try std.testing.expect(flagsValid(MAP_PRIVATE | MAP_ANONYMOUS | MAP_GROWSDOWN)); // accepted as a hint
    try std.testing.expectEqual(@as(u64, 0), normalizeProt(0));
    try std.testing.expectEqual(@as(u64, 7), normalizeProt(0x1 | 0x2 | 0x4));
    try std.testing.expectEqual(@as(u64, 3), normalizeProt(3 | 0x01000000));
    try std.testing.expectEqual(@as(u64, 0), normalizeProt(0x100));
    try std.testing.expect(anonymousFlagsValid(MAP_PRIVATE | MAP_ANONYMOUS));
    try std.testing.expect(anonymousFlagsValid(MAP_SHARED | MAP_ANONYMOUS));
}

test "mmap file offsets past the largest file size are EOVERFLOW" {
    const std = @import("std");
    try std.testing.expect(!fileOffsetOverflows(0, 4096));
    try std.testing.expect(!fileOffsetOverflows(1 << 40, 1 << 20));
    try std.testing.expect(fileOffsetOverflows(0xffff_ffff_ffff_f000, 4096)); // offset -4096
    try std.testing.expect(fileOffsetOverflows(MAX_FILE_BYTES - 4095, 8192));
    try std.testing.expect(!fileOffsetOverflows(MAX_FILE_BYTES - 8191, 4096));
    try std.testing.expect(!fileOffsetOverflows(0, 0xffff_ffff_ffff_ffff)); // wraps: the caller reports ENOMEM
}
