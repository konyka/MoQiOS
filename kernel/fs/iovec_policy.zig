/// The checks Linux's import_iovec makes on a readv/writev iovec array before any data moves (measured on Linux 7.2, hello517).
const USER_LIMIT: u64 = 0x0000_8000_0000_0000;

pub const EINVAL: i64 = -22;
pub const EFAULT: i64 = -14;

/// What one iovec does to the whole call, before anything is read or written: a negative length (as ssize_t) is EINVAL, a range that
/// leaves user space is EFAULT (access_ok; this holds for a zero length too). A NULL base is not refused here: it is inside user
/// space, so the call only faults when the copy reaches it, and an earlier iovec is still a short transfer.
pub fn entryError(base: u64, len: u64) ?i64 {
    if (len > @as(u64, @intCast(std_max_isize))) return EINVAL;
    if (base > USER_LIMIT or len > USER_LIMIT - base) return EFAULT;
    return null;
}

const std_max_isize: i64 = 0x7FFF_FFFF_FFFF_FFFF;
