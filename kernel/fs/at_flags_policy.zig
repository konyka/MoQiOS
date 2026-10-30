//! Pure flag and routing rules for linkat / fchownat / symlinkat.

pub const AT_SYMLINK_NOFOLLOW: u32 = 0x100;
pub const AT_SYMLINK_FOLLOW: u32 = 0x400;
pub const AT_EMPTY_PATH: u32 = 0x1000;

/// linkat: whether a final symlink in oldpath is followed. AT_EMPTY_PATH
/// links an open file and needs CAP_DAC_READ_SEARCH, which nothing holds here.
pub fn linkFlags(flags: u32) union(enum) { ok: bool, err: i64 } {
    if ((flags & ~(AT_SYMLINK_FOLLOW | AT_EMPTY_PATH)) != 0) return .{ .err = -22 };
    if ((flags & AT_EMPTY_PATH) != 0) return .{ .err = -2 };
    return .{ .ok = (flags & AT_SYMLINK_FOLLOW) != 0 };
}

pub const ChownFlags = struct { follow: bool, empty_path: bool };

pub fn chownFlags(flags: u32) union(enum) { ok: ChownFlags, err: i64 } {
    if ((flags & ~(AT_SYMLINK_NOFOLLOW | AT_EMPTY_PATH)) != 0) return .{ .err = -22 };
    return .{ .ok = .{ .follow = (flags & AT_SYMLINK_NOFOLLOW) == 0, .empty_path = (flags & AT_EMPTY_PATH) != 0 } };
}

fn inTmp(p: []const u8) bool {
    return p.len >= 4 and p[0] == '/' and p[1] == 't' and p[2] == 'm' and p[3] == 'p' and (p.len == 4 or p[4] == '/');
}

/// Hard links: ext2 only. Across /tmp is EXDEV; inside tmpfs the filesystem
/// has no link support (EPERM, Linux's answer for such a filesystem).
pub fn linkRoute(old: []const u8, new: []const u8) i64 {
    const a = inTmp(old);
    const b = inTmp(new);
    if (a != b) return -18;
    return if (a) -1 else 0;
}

pub fn symlinkRoute(linkpath: []const u8) i64 {
    return if (inTmp(linkpath)) -1 else 0;
}
