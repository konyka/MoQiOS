//! POSIX permission checks for the read-only volumes. Pure: the caller
//! supplies the file's owner/mode and the caller's credentials.
//!
//! Classic rules: root (or CAP_DAC_OVERRIDE) bypasses read/write checks, but
//! needs at least one execute bit on a regular file to execute it. Otherwise
//! exactly one class applies — owner if euid matches, else group if egid
//! matches, else other — and the class bits alone decide.
//! (Supplementary groups are not tracked by this kernel, so only the primary
//! egid is considered.)

pub const Meta = struct {
    mode: u32,
    uid: u32,
    gid: u32,
};

pub const Creds = struct {
    euid: u32,
    egid: u32,
    cap_dac_override: bool = false,
    groups: []const u32 = &.{},
};

pub const R: u32 = 4;
pub const W: u32 = 2;
pub const X: u32 = 1;

pub const S_IFMT: u32 = 0o170000;
pub const S_IFDIR: u32 = 0o040000;

fn classBits(m: Meta, c: Creds) u32 {
    const shift: u5 = if (c.euid == m.uid) 6 else if (@import("../proc/group_policy.zig").member(c.egid, c.groups, m.gid)) 3 else 0;
    return (m.mode >> shift) & 0o7;
}

/// May `c` perform every access in `want` (a mask of R/W/X) on `m`?
pub fn allows(m: Meta, c: Creds, want: u32) bool {
    const privileged = c.cap_dac_override;
    if (privileged) {
        // Execute still needs some execute bit on a non-directory.
        if (want & X != 0 and m.mode & S_IFMT != S_IFDIR and m.mode & 0o111 == 0) return false;
        return true;
    }
    return classBits(m, c) & want == want;
}

/// Directory traversal ("search") permission.
pub fn canSearch(m: Meta, c: Creds) bool {
    return allows(m, c, X);
}

/// Listing a directory needs read.
pub fn canList(m: Meta, c: Creds) bool {
    return allows(m, c, R);
}

/// Reading a regular file needs read.
pub fn canRead(m: Meta, c: Creds) bool {
    return allows(m, c, R);
}

pub const F_OK: u32 = 0;

/// Outcome of access(2) on an existing object of a read-only volume.
pub const AccessVerdict = enum { ok, invalid, read_only, denied };

/// access(path, mode): `mode` is F_OK or a mask of R/W/X. Bits beyond those are
/// EINVAL. Asking for write on a read-only volume is EROFS (even for root, as
/// on Linux); otherwise the permission bits decide, and F_OK needs nothing.
pub fn accessVerdict(m: Meta, c: Creds, mode: u32) AccessVerdict {
    if (mode & ~(R | W | X) != 0) return .invalid;
    if (mode & W != 0) return .read_only;
    if (mode == F_OK) return .ok;
    return if (allows(m, c, mode)) .ok else .denied;
}
