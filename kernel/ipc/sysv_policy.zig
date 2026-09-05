/// Pure policy shared by the SysV message queue and semaphore runtimes.
pub const Credentials = struct {
    euid: u32,
    egid: u32,
    cap_sys_admin: bool = false,
};

pub const Owner = struct {
    uid: u32,
    gid: u32,
    cuid: u32,
    cgid: u32,
};

pub fn modeAllows(mode: u32, owner: Owner, credentials: Credentials, read: bool, write: bool) bool {
    if (credentials.euid == 0 or credentials.cap_sys_admin) return true;
    const shift: u5 = if (credentials.euid == owner.uid)
        6
    else if (credentials.egid == owner.gid)
        3
    else
        0;
    const bits = (mode >> shift) & 0o7;
    if (read and (bits & 0o4) == 0) return false;
    if (write and (bits & 0o2) == 0) return false;
    return true;
}

pub fn canManage(owner: Owner, credentials: Credentials) bool {
    return credentials.euid == 0 or credentials.cap_sys_admin or
        credentials.euid == owner.uid or credentials.euid == owner.cuid;
}

pub fn flagsValid(flags: i32, allowed: i32) bool {
    return (flags & ~allowed) == 0;
}

pub fn removalCanFree(marked: bool, waiter_count: u32) bool {
    return marked and waiter_count == 0;
}

test "SysV mode and management policy" {
    const owner: Owner = .{ .uid = 10, .gid = 20, .cuid = 10, .cgid = 20 };
    try @import("std").testing.expect(modeAllows(0o640, owner, .{ .euid = 10, .egid = 99 }, true, true));
    try @import("std").testing.expect(modeAllows(0o064, owner, .{ .euid = 99, .egid = 20 }, true, true));
    try @import("std").testing.expect(!modeAllows(0o600, owner, .{ .euid = 99, .egid = 99 }, true, false));
    try @import("std").testing.expect(canManage(owner, .{ .euid = 10, .egid = 99 }));
    try @import("std").testing.expect(canManage(owner, .{ .euid = 99, .egid = 99, .cap_sys_admin = true }));
    try @import("std").testing.expect(!canManage(owner, .{ .euid = 99, .egid = 99 }));
    try @import("std").testing.expect(removalCanFree(true, 0));
    try @import("std").testing.expect(!removalCanFree(true, 1));
}
