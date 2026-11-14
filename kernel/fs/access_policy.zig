//! Pure rules for access(2) / faccessat(2) / faccessat2(2) on filesystems that
//! keep owner and mode (ext2, tmpfs). The read-only volumes have the same
//! rules in rofs_access_policy.zig; this variant additionally allows W_OK.
//!
//! access() judges the caller by its REAL ids, not the filesystem ones
//! (AT_EACCESS in faccessat2 switches to the filesystem ids). Judged as the
//! real ids, a real root keeps its permitted capabilities and anyone else has
//! none (see credsFor).

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
    /// The filesystem ids (setfsuid/setfsgid): what every other filesystem check uses, and AT_EACCESS too.
    fsuid: u32,
    fsgid: u32,
    /// CAP_DAC_OVERRIDE in the effective set.
    cap_dac_override: bool = false,
    /// CAP_DAC_OVERRIDE in the permitted set.
    permitted_dac_override: bool = false,
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

/// The identity access() is judged as (Linux fs/open.c access_override_creds): by default the real ids, with the permitted
/// capabilities when the real uid is 0 and none otherwise; with AT_EACCESS the caller's own filesystem ids and effective
/// capabilities.
pub fn credsFor(ids: Ids, effective: bool) Creds {
    if (effective) return .{ .euid = ids.fsuid, .egid = ids.fsgid, .cap_dac_override = ids.cap_dac_override, .groups = ids.groups };
    return .{ .euid = ids.uid, .egid = ids.gid, .cap_dac_override = ids.uid == 0 and ids.permitted_dac_override, .groups = ids.groups };
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
