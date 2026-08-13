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
