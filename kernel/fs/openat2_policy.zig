//! Pure validation policy for the subset of Linux openat2 supported by MoQiOS.

const errno = @import("../lib/errno.zig");

pub const SIZE: u64 = 24;
pub const AT_FDCWD: i64 = -100;

pub const O_WRONLY: u64 = 0x01;
pub const O_RDWR: u64 = 0x02;
pub const O_CREAT: u64 = 0x40;
pub const O_EXCL: u64 = 0x80;
pub const O_TRUNC: u64 = 0x200;
pub const O_APPEND: u64 = 0x400;
pub const O_NONBLOCK: u64 = 0x800;
pub const O_DIRECTORY: u64 = 0x10000;

/// These are the flags understood by FdTable.openWithCreationCredentials.
pub const SUPPORTED_FLAGS: u64 = O_WRONLY | O_RDWR | O_CREAT | O_EXCL |
    O_TRUNC | O_APPEND | O_NONBLOCK | O_DIRECTORY;

pub const OpenHow = struct {
    flags: u64,
    mode: u64,
    resolve: u64,
};

/// Return zero when the request can be passed to the existing open path, or
/// the exact negative errno that openat2 should return before opening anything.
pub fn validate(dirfd: i64, how: OpenHow, size: u64) i64 {
    if (size != SIZE) return errno.EINVAL;
    if (dirfd != AT_FDCWD and dirfd != 0) return errno.EBADF;
    if ((how.flags & ~SUPPORTED_FLAGS) != 0) return errno.EINVAL;
    if ((how.mode & ~@as(u64, 0o777)) != 0) return errno.EINVAL;
    if (how.resolve != 0) return errno.EINVAL;

    // The kernel only consumes mode when creating a new object. Matching the
    // openat2 ABI here prevents silently accepting an otherwise meaningless
    // mode value.
    if (how.mode != 0 and (how.flags & O_CREAT) == 0) return errno.EINVAL;
    return 0;
}
