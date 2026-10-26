pub const Access = packed struct(u2) {
    read_bit: bool = false,
    write_bit: bool = false,

    pub const read: Access = .{ .read_bit = true };
    pub const write: Access = .{ .write_bit = true };
    pub const read_write: Access = .{ .read_bit = true, .write_bit = true };
};

pub const Metadata = struct {
    mode: u32,
    uid: u32,
    gid: u32,
};

pub const Credentials = struct {
    euid: u32,
    egid: u32,
    cap_dac_override: bool = false,
};

pub const OpenDecision = struct {
    allowed: bool,
    truncate: bool,
};

pub const enforcesOwnershipOnCreate = false;

pub fn descriptorCanRead(status_flags: u32) bool {
    return (status_flags & 0x03) != 1;
}

pub fn accessForOpen(flags: u32) Access {
    var access: Access = switch (flags & 0x03) {
        0 => .read,
        1 => .write,
        else => .read_write,
    };
    if ((flags & 0x200) != 0) access.write_bit = true;
    return access;
}

pub fn allows(metadata: Metadata, credentials: Credentials, access: Access) bool {
    if (credentials.euid == 0 or credentials.cap_dac_override) return true;

    const shift: u5 = if (credentials.euid == metadata.uid)
        6
    else if (credentials.egid == metadata.gid)
        3
    else
        0;
    const class_bits = (metadata.mode >> shift) & 0x7;
    if (access.read_bit and (class_bits & 0x4) == 0) return false;
    if (access.write_bit and (class_bits & 0x2) == 0) return false;
    return true;
}

pub fn canListDirectory(metadata: Metadata, credentials: Credentials) bool {
    return allows(metadata, credentials, .read);
}

pub fn decideExistingOpen(metadata: Metadata, credentials: Credentials, flags: u32) OpenDecision {
    return .{
        .allowed = allows(metadata, credentials, accessForOpen(flags)),
        .truncate = (flags & 0x200) != 0,
    };
}

/// chmod/fchmod/fchmodat: only the file's owner, or a holder of CAP_FOWNER,
/// may change its permission bits (POSIX; uid 0 counts as holding it).
pub fn mayChmod(file_uid: u32, euid: u32, cap_fowner: bool) bool {
    return euid == 0 or cap_fowner or euid == file_uid;
}

/// chown/fchown/lchown. `new_uid`/`new_gid` of null mean "leave unchanged"
/// (the -1 argument). Giving a file to another user needs CAP_CHOWN; the
/// owner may change the group only to its own effective group (supplementary
/// groups are not tracked), anything else needs CAP_CHOWN. Re-stating the
/// current ids is always allowed for the owner.
pub fn mayChown(file_uid: u32, file_gid: u32, euid: u32, egid: u32, cap_chown: bool, new_uid: ?u32, new_gid: ?u32) bool {
    if (euid == 0 or cap_chown) return true;
    if (new_uid) |u| {
        if (u != file_uid) return false;
    }
    if (new_gid) |g| {
        if (g != file_gid and (euid != file_uid or g != egid)) return false;
    }
    if ((new_uid != null or new_gid != null) and euid != file_uid) {
        // A non-owner re-stating the current ids changes nothing, but Linux
        // still refuses it: only the owner may call chown on the file at all.
        return false;
    }
    return true;
}
