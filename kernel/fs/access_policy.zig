//! Pure rules for access(2) / faccessat(2) / faccessat2(2) on filesystems that
//! keep owner and mode (ext2, tmpfs). The read-only volumes have the same
//! rules in rofs_access_policy.zig; this variant additionally allows W_OK.
//!
//! access() judges the caller by its REAL ids, not the effective ones
//! (AT_EACCESS in faccessat2 switches to the effective ids). Privilege comes
//! from the effective identity, so judging as the real ids drops it unless
//! the two agree.

pub const R: u32 = 4;
pub const W: u32 = 2;
pub const X: u32 = 1;

pub const AT_SYMLINK_NOFOLLOW: u32 = 0x100;
pub const AT_EACCESS: u32 = 0x200;
pub const AT_EMPTY_PATH: u32 = 0x1000;

pub const Meta = struct { mode: u32, uid: u32, gid: u32 };

pub const Creds = struct {
    euid: u32,
    egid: u32,
    cap_dac_override: bool = false,
    groups: []const u32 = &.{},
};

pub const Ids = struct {
    uid: u32,
    gid: u32,
    euid: u32,
    egid: u32,
    cap_dac_override: bool = false,
    groups: []const u32 = &.{},
};

pub const Verdict = enum { ok, invalid, denied };

const S_IFMT: u32 = 0o170000;
const S_IFDIR: u32 = 0o040000;

fn member(egid: u32, groups: []const u32, g: u32) bool {
    if (egid == g) return true;
    for (groups) |x| if (x == g) return true;
    return false;
}

pub fn verdict(m: Meta, c: Creds, mode: u32) Verdict {
    if ((mode & ~(R | W | X)) != 0) return .invalid;
    if (mode == 0) return .ok;
    if (c.cap_dac_override) {
        if ((mode & X) != 0 and (m.mode & S_IFMT) != S_IFDIR and (m.mode & 0o111) == 0) return .denied;
        return .ok;
    }
    const shift: u5 = if (c.euid == m.uid) 6 else if (member(c.egid, c.groups, m.gid)) 3 else 0;
    return if (((m.mode >> shift) & 0o7 & mode) == mode) .ok else .denied;
}

/// The identity access() is judged as: real ids by default, effective ones
/// with AT_EACCESS. Dropping to the real ids drops privilege unless they match.
pub fn credsFor(ids: Ids, effective: bool) Creds {
    if (effective or (ids.uid == ids.euid and ids.gid == ids.egid)) {
        return .{ .euid = ids.euid, .egid = ids.egid, .cap_dac_override = ids.cap_dac_override, .groups = ids.groups };
    }
    return .{ .euid = ids.uid, .egid = ids.gid, .cap_dac_override = false, .groups = ids.groups };
}

pub const Flags = struct {
    err: i64 = 0,
    effective: bool = false,
    follow: bool = true,
    empty_path: bool = false,

    pub fn err_or_zero(self: Flags) i64 {
        return self.err;
    }
};

pub fn checkFlags(flags: u32) Flags {
    if ((flags & ~(AT_SYMLINK_NOFOLLOW | AT_EACCESS | AT_EMPTY_PATH)) != 0) return .{ .err = -22 };
    return .{ .effective = (flags & AT_EACCESS) != 0, .follow = (flags & AT_SYMLINK_NOFOLLOW) == 0, .empty_path = (flags & AT_EMPTY_PATH) != 0 };
}
