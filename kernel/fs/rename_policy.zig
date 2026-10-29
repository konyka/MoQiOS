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

/// links_count changes when a directory moves from `old_parent` to
/// `new_parent`: its ".." stops counting as a link to the old parent and
/// starts counting toward the new one. Same parent: nothing changes.
pub const LinkDelta = struct { old_parent: i32, new_parent: i32 };

pub fn dirMoveLinkDelta(old_parent: u32, new_parent: u32) LinkDelta {
    if (old_parent == new_parent) return .{ .old_parent = 0, .new_parent = 0 };
    return .{ .old_parent = -1, .new_parent = 1 };
}

/// `dest_chain`: the destination parent and its ancestors up to the root,
/// nearest first. Moving `moved` there makes a loop if `moved` is on that
/// chain (into itself or into one of its descendants): EINVAL.
pub fn dirMoveCreatesCycle(moved: u32, dest_chain: []const u32) bool {
    for (dest_chain) |ino| if (ino == moved) return true;
    return false;
}

/// links_count changes when a directory replaces an existing empty
/// directory in `new_parent`: the victim's ".." link on the new parent goes
/// away while the moved directory's ".." takes its place, and the old
/// parent loses the moved directory's link. Applied to one inode when the
/// parents are the same (sum: -1).
pub fn dirReplaceLinkDelta(old_parent: u32, new_parent: u32) LinkDelta {
    _ = old_parent;
    _ = new_parent;
    return .{ .old_parent = -1, .new_parent = 0 };
}

/// links_count changes for RENAME_EXCHANGE of `a` (in `old_parent`) and
/// `b` (in `new_parent`): each parent gains a link for every directory that
/// arrives and loses one for every directory that leaves. Same parent: none.
pub fn exchangeLinkDelta(old_parent: u32, new_parent: u32, a_is_dir: bool, b_is_dir: bool) LinkDelta {
    if (old_parent == new_parent) return .{ .old_parent = 0, .new_parent = 0 };
    const a: i32 = @intFromBool(a_is_dir);
    const b: i32 = @intFromBool(b_is_dir);
    return .{ .old_parent = b - a, .new_parent = a - b };
}
