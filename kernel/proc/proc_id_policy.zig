//! Pure conversions between user-supplied process ids and the narrower
//! in-kernel id fields. Task ids are u32 and never reused; pgid/sid are
//! stored as u16, so an id above 0xFFFF can never name (or be) a group or
//! session. Out-of-range input is rejected instead of trapping in @intCast.

pub const MAX_GROUP_ID: u32 = 0xFFFF;

/// exit(status) code as Linux reports it: only the low 8 bits survive.
pub fn exitCode(status: u64) i32 {
    return @intCast(status & 0xff);
}

/// kill(pid > 0) target tid, or null when pid does not fit a tid.
pub fn killTargetTid(pid: i64) ?u32 {
    if (pid <= 0 or pid > 0xFFFF_FFFF) return null;
    return @intCast(pid);
}

/// kill(pid < -1) process group, or null when -pid cannot be a pgid.
pub fn killTargetPgid(pid: i64) ?u16 {
    if (pid >= -1 or pid < -@as(i64, MAX_GROUP_ID)) return null;
    return @intCast(-pid);
}

/// A user-supplied pgid argument (setpgid), or null when out of range.
pub fn groupIdFromArg(arg: u64) ?u16 {
    if (arg > MAX_GROUP_ID) return null;
    return @intCast(arg);
}

/// The pgid/sid value a task with `tid` would get as group/session leader,
/// or null when the tid does not fit the u16 field.
pub fn groupIdForTid(tid: u32) ?u16 {
    if (tid > MAX_GROUP_ID) return null;
    return @intCast(tid);
}

/// True when a u16 group/session id equals the u32 `tid` (a tid above the
/// field width never matches).
pub fn groupIdIsTid(group_id: u16, tid: u32) bool {
    return @as(u32, group_id) == tid;
}

/// Group/session id of a task that has no parent to inherit one from: it
/// leads its own, named by its tid. Ids that do not fit the u16 field stay 0
/// (no group) rather than wrapping onto someone else's.
pub fn rootGroupId(tid: u32) u16 {
    return if (tid <= MAX_GROUP_ID) @intCast(tid) else 0;
}

const WNOHANG: u32 = 0x1;
const WUNTRACED: u32 = 0x2;
const WCONTINUED: u32 = 0x8;
const WNOTHREAD: u32 = 0x2000_0000;
const WALL: u32 = 0x4000_0000;
const WCLONE: u32 = 0x8000_0000;

/// wait4/waitpid options: only the defined bits are valid, the rest EINVAL.
pub fn waitOptionsErrno(options: u32) i64 {
    const valid = WNOHANG | WUNTRACED | WCONTINUED | WNOTHREAD | WALL | WCLONE;
    return if ((options & ~valid) != 0) -22 else 0;
}

/// Does a child (`child_tid`, in group `child_pgid`) satisfy waitpid(`pid`)
/// for a caller in group `caller_pgid`? pid > 0 names one child, -1 any child,
/// 0 any child in the caller's group, < -1 any child in group -pid.
pub fn waitMatches(pid: i32, child_tid: u32, child_pgid: u16, caller_pgid: u16) bool {
    if (pid > 0) return child_tid == @as(u32, @intCast(pid));
    if (pid == -1) return true;
    if (pid == 0) return child_pgid == caller_pgid;
    if (pid == @import("std").math.minInt(i32)) return false;
    return child_pgid == @as(u32, @intCast(-pid)) and -pid <= MAX_GROUP_ID;
}
