//! fcntl() flag rules, kept free of kernel state so the host tests can check them.
//!
//! Linux splits a descriptor's flags in two: FD_CLOEXEC lives on the descriptor, everything else
//! (the "status flags" F_GETFL reports) on the open file description.

pub const O_ACCMODE: u32 = 0x3;
pub const O_APPEND: u32 = 0x400;
pub const O_NONBLOCK: u32 = 0x800;
pub const O_DSYNC: u32 = 0x1000;
pub const O_DIRECT: u32 = 0x4000;
pub const O_DIRECTORY: u32 = 0x10000;
pub const O_NOFOLLOW: u32 = 0x20000;
pub const O_NOATIME: u32 = 0x40000;
pub const O_CLOEXEC: u32 = 0x80000;
/// O_SYNC includes the O_DSYNC bit.
pub const O_SYNC: u32 = 0x101000;

pub const FD_CLOEXEC: u32 = 1;

/// The open() flags that stay visible through F_GETFL (creation-time flags such as O_CREAT, O_TRUNC,
/// O_EXCL and O_CLOEXEC do not).
pub const OPEN_STATUS_MASK: u32 = O_ACCMODE | O_APPEND | O_NONBLOCK | O_SYNC | O_DIRECT | O_DIRECTORY | O_NOFOLLOW | O_NOATIME;

/// The flags F_SETFL may change; the access mode, creation flags and the rest are left alone.
pub const SETFL_MASK: u32 = O_APPEND | O_NONBLOCK | O_DIRECT | O_NOATIME;

/// F_SETFD: only FD_CLOEXEC exists; any other bit is ignored.
pub fn fdFlagsFromSetfd(arg: u64) u32 {
    return @as(u32, @truncate(arg)) & FD_CLOEXEC;
}

/// The status flags after F_SETFL(arg): the settable bits come from `arg`, everything else is kept.
pub fn applySetfl(current: u32, arg: u64) u32 {
    return (current & ~SETFL_MASK) | (@as(u32, @truncate(arg)) & SETFL_MASK);
}

/// Descriptor kinds that Linux reports as O_RDWR although the kernel stores no access mode for them.
pub fn alwaysReadWrite(tag: []const u8) bool {
    const names = [_][]const u8{ "tcp_socket", "udp_socket", "unix_socket", "raw_socket", "epoll", "eventfd", "timerfd" };
    for (names) |n| {
        if (eql(n, tag)) return true;
    }
    return false;
}

/// What F_GETFL reports for a descriptor of kind `tag` whose stored status flags are `stored`.
pub fn reportedFlags(tag: []const u8, stored: u32) u32 {
    if (alwaysReadWrite(tag)) return (stored & ~O_ACCMODE) | 2;
    return stored;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

/// A pipe here has one fixed buffer page.
pub const PIPE_SIZE: u32 = 4096;
pub const F_UNLCK: i64 = 2;

/// F_SETPIPE_SZ: the buffer cannot grow, so anything above one page fails (ENOMEM); a request for
/// that page or less is rounded up to it, as Linux rounds up to a page.
pub fn setPipeSize(requested: u64) i64 {
    if (requested > PIPE_SIZE) return -12; // ENOMEM
    return PIPE_SIZE;
}
