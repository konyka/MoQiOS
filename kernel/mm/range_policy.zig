//! Argument rules shared by the address-range system calls (madvise, msync, mincore, mlock family,
//! munmap), following Linux's order of checks. No kernel state, so the host tests can run it.

pub const PAGE: u64 = 4096;
pub const USER_LIMIT: u64 = 0x0000_8000_0000_0000;

pub const EINVAL: i64 = -22;
pub const ENOMEM: i64 = -12;

/// `len` rounded up to whole pages, or null when that overflows (Linux: PAGE_ALIGN wraps to 0).
pub fn alignUp(len: u64) ?u64 {
    const r = @addWithOverflow(len, PAGE - 1);
    if (r[1] != 0) return null;
    return r[0] & ~(PAGE - 1);
}

/// Whether `pages` pages starting at the page-aligned `addr` lie wholly in user space.
pub fn inUserSpace(addr: u64, pages: u64) bool {
    if (addr >= USER_LIMIT) return false;
    if (pages > (USER_LIMIT - addr) / PAGE) return false;
    return true;
}

pub const Span = union(enum) {
    /// Fail with this errno.
    err: i64,
    /// Nothing to do; the call succeeds.
    empty,
    /// This many pages from the (aligned) start.
    pages: u64,
};

/// madvise's preamble: the start must be page aligned (EINVAL), a length that wraps when rounded up is
/// EINVAL, a zero length succeeds, and a range that leaves user space is ENOMEM (the hole is found
/// when the mappings are walked).
pub fn madviseSpan(addr: u64, len: u64) Span {
    if (addr % PAGE != 0) return .{ .err = EINVAL };
    const up = alignUp(len) orelse return .{ .err = EINVAL };
    if (len == 0) return .empty;
    const pages = up / PAGE;
    if (!inUserSpace(addr, pages)) return .{ .err = ENOMEM };
    return .{ .pages = pages };
}

/// The advice values madvise acts on (or may validly ignore). MADV_FREE is only a hint that the kernel
/// is free to ignore; the fork-inheritance advice (DONTFORK/DOFORK) and the rest are not implemented
/// and stay EINVAL rather than pretending to take effect.
pub fn madviseSupported(advice: u32) bool {
    return switch (advice) {
        0, 1, 2, 3, 4, 8 => true,
        else => false,
    };
}

/// mincore: the start must be page aligned (EINVAL); a range outside user space is ENOMEM. The vector
/// holds one byte per page of the rounded-up length.
pub fn mincoreSpan(addr: u64, len: u64) Span {
    if (addr % PAGE != 0) return .{ .err = EINVAL };
    const up = alignUp(len) orelse return .{ .err = ENOMEM };
    const pages = up / PAGE;
    if (!inUserSpace(addr, pages)) return .{ .err = ENOMEM };
    if (pages == 0) return .empty;
    return .{ .pages = pages };
}

/// mlock/munlock: the start is rounded down and the length grows by the part of a page it started in;
/// a zero length does nothing; the range must be in user space (ENOMEM) and mapped (ENOMEM).
pub fn lockSpan(addr: u64, len: u64) Span {
    if (len == 0) return .empty;
    const start = addr & ~(PAGE - 1);
    const total = @addWithOverflow(len, addr - start);
    if (total[1] != 0) return .{ .err = ENOMEM };
    const up = alignUp(total[0]) orelse return .{ .err = ENOMEM };
    const pages = up / PAGE;
    if (!inUserSpace(start, pages)) return .{ .err = ENOMEM };
    return .{ .pages = pages };
}

pub const MCL_CURRENT: u32 = 1;
pub const MCL_FUTURE: u32 = 2;
pub const MCL_ONFAULT: u32 = 4;

/// mlockall flags: only the three known bits, and MCL_ONFAULT needs CURRENT or FUTURE with it.
pub fn mlockallFlagsValid(flags: u32) bool {
    if (flags & ~(MCL_CURRENT | MCL_FUTURE | MCL_ONFAULT) != 0) return false;
    if (flags & (MCL_CURRENT | MCL_FUTURE) == 0) return false;
    return true;
}
