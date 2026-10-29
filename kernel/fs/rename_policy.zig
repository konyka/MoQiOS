//! Pure rename(2)/renameat2(2) rules shared by the filesystems.

pub const RENAME_NOREPLACE: u32 = 0x1;
pub const RENAME_EXCHANGE: u32 = 0x2;
pub const RENAME_WHITEOUT: u32 = 0x4;

pub const Mode = enum { replace, noreplace, exchange };

/// renameat2 flags → mode, or a negative errno. Unknown bits and
/// NOREPLACE|EXCHANGE are EINVAL (Linux). RENAME_WHITEOUT needs overlayfs
/// whiteout support that no filesystem here has: EINVAL.
pub fn mode(flags: u32) union(enum) { ok: Mode, err: i64 } {
    if (flags & ~(RENAME_NOREPLACE | RENAME_EXCHANGE | RENAME_WHITEOUT) != 0) return .{ .err = -22 };
    if (flags & RENAME_WHITEOUT != 0) return .{ .err = -22 };
    if (flags & RENAME_NOREPLACE != 0 and flags & RENAME_EXCHANGE != 0) return .{ .err = -22 };
    if (flags & RENAME_EXCHANGE != 0) return .{ .ok = .exchange };
    if (flags & RENAME_NOREPLACE != 0) return .{ .ok = .noreplace };
    return .{ .ok = .replace };
}

pub const Route = enum { tmpfs, other, cross };

fn isTmp(path: []const u8) bool {
    if (path.len < 4) return false;
    if (path[0] != '/' or path[1] != 't' or path[2] != 'm' or path[3] != 'p') return false;
    return path.len == 4 or path[4] == '/';
}

/// Which filesystem handles the rename. A rename between /tmp and anything
/// else crosses filesystems: EXDEV.
pub fn route(old_path: []const u8, new_path: []const u8) Route {
    const a = isTmp(old_path);
    const b = isTmp(new_path);
    if (a and b) return .tmpfs;
    if (!a and !b) return .other;
    return .cross;
}

pub const Target = struct {
    exists: bool,
    is_dir: bool = false,
    empty: bool = true,
};

/// Whether a source of kind `src_is_dir` may land on `target` (0 or a
/// negative errno), for a plain or NOREPLACE rename. EXCHANGE only needs
/// both names to exist.
pub fn checkTarget(m: Mode, src_is_dir: bool, target: Target) i64 {
    switch (m) {
        .exchange => return if (target.exists) 0 else -2, // ENOENT
        .noreplace => return if (target.exists) -17 else 0, // EEXIST
        .replace => {},
    }
    if (!target.exists) return 0;
    if (src_is_dir and !target.is_dir) return -20; // ENOTDIR
    if (!src_is_dir and target.is_dir) return -21; // EISDIR
    if (target.is_dir and !target.empty) return -39; // ENOTEMPTY
    return 0;
}
