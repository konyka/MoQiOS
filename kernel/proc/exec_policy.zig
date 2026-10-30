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

pub const Failure = enum { denied, not_found, bad_format, no_memory, fault };

pub fn errno(f: Failure) i64 {
    return switch (f) {
        .denied => -1, // EPERM: threaded exec or live SysV SHM attachments
        .not_found => -2, // ENOENT
        .bad_format => -8, // ENOEXEC
        .no_memory => -12, // ENOMEM
        .fault => -14, // EFAULT
    };
}
