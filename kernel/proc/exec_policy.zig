//! Pure rules for execve/execveat: which resolved names can be executed,
//! the execveat flag set, and the errno for each failure.
//!
//! Programs are only loaded from the boot ramdisk, which is a flat archive of
//! bare names. A name resolved against the cwd or a directory fd is therefore
//! executable when it is a single component, with or without a leading "/";
//! anything deeper is not on the ramdisk (ENOENT).

pub const RAMDISK_NAME_MAX: usize = 63;

pub const AT_SYMLINK_NOFOLLOW: u32 = 0x100;
pub const AT_EMPTY_PATH: u32 = 0x1000;

pub fn programName(path: []const u8) union(enum) { ok: []const u8, err: i64 } {
    const name = if (path.len > 0 and path[0] == '/') path[1..] else path;
    if (name.len == 0) return .{ .err = -2 };
    for (name) |c| if (c == '/') return .{ .err = -2 };
    if (name.len > RAMDISK_NAME_MAX) return .{ .err = -36 };
    return .{ .ok = name };
}

pub fn checkAtFlags(flags: u32) i64 {
    return if ((flags & ~(AT_SYMLINK_NOFOLLOW | AT_EMPTY_PATH)) != 0) -22 else 0;
}

/// Bytes all execve argument and environment strings may take together, NULs included. They share the one 4 KiB page of the new
/// program's initial stack (user_stack.fits decides whether the pointer part fits next to them), so there is no limit per string:
/// one argument may use the whole pool. A list that does not fit is E2BIG; silently cutting a string would run the program with a
/// different argument than the caller gave.
pub const ARG_POOL_BYTES: usize = 4096;

/// True when a string of `len` bytes plus its NUL still fits in a pool that has `used` bytes taken.
pub fn argFits(used: usize, len: usize) bool {
    return used <= ARG_POOL_BYTES and len < ARG_POOL_BYTES - used;
}

pub const Failure = enum { denied, not_found, bad_format, no_memory, fault, too_big };

pub fn errno(f: Failure) i64 {
    return switch (f) {
        .denied => -1, // EPERM: threaded exec or live SysV SHM attachments
        .not_found => -2, // ENOENT
        .bad_format => -8, // ENOEXEC
        .no_memory => -12, // ENOMEM
        .fault => -14, // EFAULT
        .too_big => -7, // E2BIG: the argument and environment strings do not fit ARG_POOL_BYTES / the stack page
    };
}

const testing = @import("std").testing;

test "one exec string may use the whole pool, and the strings share it" {
    try testing.expect(argFits(0, 0));
    try testing.expect(argFits(0, 128));
    try testing.expect(argFits(0, 4095));
    try testing.expect(!argFits(0, 4096));
    try testing.expect(argFits(4000, 95));
    try testing.expect(!argFits(4000, 96));
    try testing.expect(!argFits(4096, 0));
    try testing.expect(!argFits(5000, 0));
}

test "too_big is E2BIG" {
    try testing.expectEqual(@as(i64, -7), errno(.too_big));
}
