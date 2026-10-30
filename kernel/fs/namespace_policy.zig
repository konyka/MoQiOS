//! Pure errno rules for the namespace calls on a filesystem that has
//! directories, files and symlinks (ext2, tmpfs): what unlink, rmdir, mkdir
//! and open answer for an object that exists, or does not.

pub const Kind = enum { missing, file, directory, symlink };

const O_ACCMODE: u32 = 0x3;
const O_CREAT: u32 = 0x40;
const O_EXCL: u32 = 0x80;
const O_TRUNC: u32 = 0x200;
const O_DIRECTORY: u32 = 0x10000;
const O_NOFOLLOW: u32 = 0x20000;

pub fn unlink(k: Kind) i64 {
    return switch (k) {
        .missing => -2, // ENOENT
        .directory => -21, // EISDIR
        .file, .symlink => 0,
    };
}

pub fn rmdir(k: Kind, empty: bool) i64 {
    return switch (k) {
        .missing => -2,
        .file, .symlink => -20, // ENOTDIR
        .directory => if (empty) 0 else -39, // ENOTEMPTY
    };
}

pub fn mkdir(k: Kind) i64 {
    return if (k == .missing) 0 else -17; // EEXIST
}

/// open() of an object that exists. Order follows Linux: O_CREAT|O_EXCL first,
/// then O_NOFOLLOW on a symlink, then the directory rules.
pub fn openExisting(k: Kind, flags: u32) i64 {
    if ((flags & O_CREAT) != 0 and (flags & O_EXCL) != 0) return -17;
    if (k == .symlink and (flags & O_NOFOLLOW) != 0) {
        return if ((flags & O_DIRECTORY) != 0) -20 else -40; // ENOTDIR / ELOOP
    }
    switch (k) {
        .directory => {
            if ((flags & O_ACCMODE) != 0 or (flags & O_TRUNC) != 0) return -21; // EISDIR
            return 0;
        },
        .file => return if ((flags & O_DIRECTORY) != 0) -20 else 0,
        else => return 0,
    }
}

pub fn openMissing(flags: u32) i64 {
    return if ((flags & O_CREAT) != 0) 0 else -2;
}

/// read(2) on a descriptor: the errno the descriptor kind alone decides, or 0
/// when the read may proceed to the filesystem.
pub fn readGate(is_directory: bool) i64 {
    return if (is_directory) -21 else 0; // EISDIR
}

/// write(2)/pwrite(2): a descriptor not open for writing is EBADF (a
/// directory is never open for writing, so it is EBADF too on Linux when
/// opened read-only; opening one for writing already failed with EISDIR).
pub fn writeGate(writable: bool) i64 {
    return if (writable) 0 else -9; // EBADF
}

/// Classify the result of `copyPathFromUser(buf, ptr, max)`: it returns the
/// bytes copied including the NUL, `max` when no NUL appeared within `max`
/// bytes, and 0 when the string ran into unreadable memory. A full window with
/// no terminator means the path is longer than the kernel accepts (ENAMETOOLONG)
/// rather than something to truncate and act on.
pub fn pathCopyErrno(buf: []const u8, copied: usize, max: usize) i64 {
    if (copied == 0) return -14; // EFAULT
    if (copied < max) return 0;
    // copied == max: fits only if the last copied byte is the terminator
    return if (buf[copied - 1] == 0) 0 else -36;
}

pub const PathCopy = union(enum) { ok: []const u8, err: i64 };

/// The NUL-terminated name inside `buf` after a `copyPathFromUser(buf, ptr, max)`
/// that returned `copied`, or EFAULT / ENAMETOOLONG (see pathCopyErrno).
pub fn pathFromCopy(buf: []const u8, copied: usize, max: usize) PathCopy {
    const rc = pathCopyErrno(buf, copied, max);
    if (rc != 0) return .{ .err = rc };
    var n: usize = 0;
    while (n < copied and buf[n] != 0) : (n += 1) {}
    return .{ .ok = buf[0..n] };
}
