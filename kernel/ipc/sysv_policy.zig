/// Pure policy shared by the SysV message queue and semaphore runtimes.
pub const Credentials = struct {
    euid: u32,
    egid: u32,
    cap_sys_admin: bool = false,
    groups: []const u32 = &.{},
};

pub const Owner = struct {
    uid: u32,
    gid: u32,
    cuid: u32,
    cgid: u32,
};

pub fn modeAllows(mode: u32, owner: Owner, credentials: Credentials, read: bool, write: bool) bool {
    if (credentials.cap_sys_admin) return true;
    const shift: u5 = if (credentials.euid == owner.uid)
        6
    else if (@import("../proc/group_policy.zig").member(credentials.egid, credentials.groups, owner.gid))
        3
    else
        0;
    const bits = (mode >> shift) & 0o7;
    if (read and (bits & 0o4) == 0) return false;
    if (write and (bits & 0o2) == 0) return false;
    return true;
}

pub fn canManage(owner: Owner, credentials: Credentials) bool {
    return credentials.cap_sys_admin or
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

/// IPC_SET input: the fields of `ipc_perm` a caller may change. `uid`/`gid`
/// of IPC_SET_KEEP leave the current value.
pub const IPC_SET_KEEP: u32 = 0xFFFF_FFFF;

pub const SetRequest = struct {
    mode: u32,
    uid: u32 = IPC_SET_KEEP,
    gid: u32 = IPC_SET_KEEP,
};

pub const SetResult = struct {
    owner: Owner,
    mode: u32,
};

/// IPC_SET (msgctl/semctl/shmctl): the owner, the creator or CAP_SYS_ADMIN
/// may set the owning uid/gid and the low 9 mode bits. The creator ids never
/// change, so the creator keeps the right to manage the object. Null: EPERM.
pub fn applySet(owner: Owner, credentials: Credentials, req: SetRequest) ?SetResult {
    if (!canManage(owner, credentials)) return null;
    var out = owner;
    if (req.uid != IPC_SET_KEEP) out.uid = req.uid;
    if (req.gid != IPC_SET_KEEP) out.gid = req.gid;
    return .{ .owner = out, .mode = req.mode & 0o777 };
}

/// IPC_SET buffer. The original native ABI is one u64 holding the mode; the
/// extended form is three u64 words {mode | IPC_SET_EXTENDED, uid, gid}. Bit
/// 63 is never part of a valid mode, so old callers keep working and the
/// kernel reads the two extra words only when the flag is present.
pub const IPC_SET_EXTENDED: u64 = 1 << 63;

pub fn isExtendedSet(first: u64) bool {
    return first & IPC_SET_EXTENDED != 0;
}

pub fn decodeSet(first: u64, rest: ?[2]u64) SetRequest {
    const r = rest orelse return .{ .mode = @truncate(first & 0o777) };
    return .{ .mode = @truncate(first & 0o777), .uid = @truncate(r[0]), .gid = @truncate(r[1]) };
}

/// Copy an IPC_SET buffer from user space (outside any IPC lock): one u64, or
/// three when the first carries IPC_SET_EXTENDED. Null on a fault.
pub fn readSetRequest(buf: u64) ?SetRequest {
    const copy = @import("../mm/copy_from_user.zig");
    if (buf == 0 or buf >= 0x0000_8000_0000_0000) return null;
    var words: [3]u64 = .{ 0, 0, 0 };
    if (copy.copyFromUser(@as([*]u8, @ptrCast(&words))[0..8], @ptrFromInt(buf), 8) != 8) return null;
    if (!isExtendedSet(words[0])) return decodeSet(words[0], null);
    if (copy.copyFromUser(@as([*]u8, @ptrCast(&words))[8..24], @ptrFromInt(buf + 8), 16) != 16) return null;
    return decodeSet(words[0], .{ words[1], words[2] });
}
