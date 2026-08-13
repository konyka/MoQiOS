/// Pure policy for task umask state and tmpfs creation metadata.
pub const DEFAULT_UMASK: u32 = 0o022;
pub const DEFAULT_FILE_MODE: u32 = 0o666;
pub const DEFAULT_DIRECTORY_MODE: u32 = 0o777;
pub const O_EXCL: u32 = 0x80;

pub const ObjectKind = enum {
    regular_file,
    directory,
};

pub const Metadata = struct {
    mode: u32,
    uid: u32,
    gid: u32,
};

pub const Decision = struct {
    metadata: Metadata,
    created: bool,
};

pub fn defaultRequestedMode(kind: ObjectKind) u32 {
    return switch (kind) {
        .regular_file => DEFAULT_FILE_MODE,
        .directory => DEFAULT_DIRECTORY_MODE,
    };
}

pub fn requestedMode(kind: ObjectKind, supplied: ?u32) u32 {
    return supplied orelse defaultRequestedMode(kind);
}

pub fn decide(existing: ?Metadata, kind: ObjectKind, supplied_mode: ?u32, umask_val: u32, euid: u32, egid: u32) Decision {
    if (existing) |metadata| return .{ .metadata = metadata, .created = false };

    return .{
        .metadata = .{
            .mode = (requestedMode(kind, supplied_mode) & 0o777) & ~(umask_val & 0o777),
            .uid = euid,
            .gid = egid,
        },
        .created = true,
    };
}

pub fn exclusiveCreateRejectsExisting(create: bool, flags: u32) bool {
    return create and (flags & O_EXCL) != 0;
}

pub fn initialTaskUmask() u32 {
    return DEFAULT_UMASK;
}

pub fn inheritedTaskUmask(parent_umask: u32) u32 {
    return parent_umask;
}

pub fn replaceTaskUmask(current: *u32, requested: u32) u32 {
    const previous = current.*;
    current.* = requested & 0o777;
    return previous;
}
