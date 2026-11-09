//! Pure decoding of the preadv2/pwritev2 `flags` argument (Linux uapi RWF_*): which flags are known, and whether a write appends.
//! Host-testable. Hint-only flags (HIPRI, DSYNC, SYNC, NOWAIT) are accepted; RWF_APPEND / RWF_NOAPPEND choose the append behaviour.

pub const RWF_HIPRI: u32 = 0x01;
pub const RWF_DSYNC: u32 = 0x02;
pub const RWF_SYNC: u32 = 0x04;
pub const RWF_NOWAIT: u32 = 0x08;
pub const RWF_APPEND: u32 = 0x10;
pub const RWF_NOAPPEND: u32 = 0x20;
pub const SUPPORTED: u32 = RWF_HIPRI | RWF_DSYNC | RWF_SYNC | RWF_NOWAIT | RWF_APPEND | RWF_NOAPPEND;

pub const EOPNOTSUPP: i64 = -95;
pub const EINVAL: i64 = -22;

pub const Append = enum { descriptor, append, no_append };

/// The append behaviour a pwritev2 asks for, or an errno: unknown bits are EOPNOTSUPP, RWF_APPEND with RWF_NOAPPEND is EINVAL.
pub fn writeMode(flags: u32) union(enum) { ok: Append, err: i64 } {
    if (flags & ~SUPPORTED != 0) return .{ .err = EOPNOTSUPP };
    const a = flags & RWF_APPEND != 0;
    const na = flags & RWF_NOAPPEND != 0;
    if (a and na) return .{ .err = EINVAL };
    if (a) return .{ .ok = .append };
    if (na) return .{ .ok = .no_append };
    return .{ .ok = .descriptor };
}

/// preadv2 rejects only unknown bits; the append flags are accepted and ignored for a read (measured on Linux).
pub fn readFlagsValid(flags: u32) ?i64 {
    if (flags & ~SUPPORTED != 0) return EOPNOTSUPP;
    return null;
}

/// An offset of -1 means "use and advance the descriptor's current position" (Linux preadv2/pwritev2); any other negative offset is EINVAL.
pub fn offsetKind(offset: i64) enum { current, explicit, invalid } {
    if (offset == -1) return .current;
    if (offset < 0) return .invalid;
    return .explicit;
}

/// RWF_DSYNC / RWF_SYNC: the written data must be on disk before the call returns (Linux runs the equivalent of fdatasync / fsync).
pub fn wantsSync(flags: u32) bool {
    return flags & (RWF_DSYNC | RWF_SYNC) != 0;
}

/// RWF_NOWAIT: fail with EAGAIN instead of blocking. Only stream descriptors (pipes, sockets) can block here; on a regular file this kernel
/// answers EOPNOTSUPP like Linux's tmpfs (which has no non-blocking file I/O).
pub fn wantsNowait(flags: u32) bool {
    return flags & RWF_NOWAIT != 0;
}

