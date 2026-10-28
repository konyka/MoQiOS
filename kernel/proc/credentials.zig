// kernel/proc/credentials.zig — Credential management syscalls
//
// setuid/setgid/setreuid/setregid/setresuid/getresuid/setresgid/getresgid/unshare

const sched = @import("sched.zig");
const task_mod = @import("task.zig");
const copy = @import("../mm/copy_from_user.zig");

fn getCurrentTaskMut() ?*task_mod.Task {
    if (sched.currentTaskIndex()) |idx| {
        return task_mod.getTask(idx);
    }
    return null;
}

fn getCurrentTask() ?*const task_mod.Task {
    if (sched.currentTaskIndex()) |idx| {
        return task_mod.getTask(idx);
    }
    return null;
}

const policy = @import("cred_policy.zig");

fn uidIds(t: *const task_mod.Task) policy.Ids {
    return .{ .r = t.uid, .e = t.euid, .s = t.suid };
}

fn gidIds(t: *const task_mod.Task) policy.Ids {
    return .{ .r = t.gid, .e = t.egid, .s = t.sgid };
}

/// Install new user IDs: capabilities follow capabilities(7), and the
/// per-real-UID task count (RLIMIT_NPROC) moves with the real UID.
fn applyUids(t: *task_mod.Task, new: policy.Ids) void {
    const old = uidIds(t);
    const caps = policy.capsAfterUidChange(old, new, .{
        .effective = @bitCast(t.effective_caps),
        .permitted = @bitCast(t.permitted_caps),
    });
    t.effective_caps = @bitCast(caps.effective);
    t.permitted_caps = @bitCast(caps.permitted);
    if (new.r != old.r) task_mod.moveRealUidLocked(old.r, new.r);
    t.uid = new.r;
    t.euid = new.e;
    t.suid = new.s;
}

fn applyGids(t: *task_mod.Task, new: policy.Ids) void {
    t.gid = new.r;
    t.egid = new.e;
    t.sgid = new.s;
}

/// setuid(uid) — CAP_SETUID sets real/effective/saved; otherwise only the
/// effective ID, and only to the real or saved ID.
pub fn setuid(uid: u32) i64 {
    const lock_flags = task_mod.lockTask();
    defer task_mod.unlockTask(lock_flags);
    const t = getCurrentTaskMut() orelse return -1;
    const new = policy.setOne(uidIds(t), uid, t.effective_caps.cap_setuid) orelse return if (uid == policy.KEEP) -22 else -1;
    applyUids(t, new);
    return 0;
}

/// setgid(gid) — CAP_SETGID sets real/effective/saved; otherwise only the
/// effective ID, and only to the real or saved ID.
pub fn setgid(gid: u32) i64 {
    const lock_flags = task_mod.lockTask();
    defer task_mod.unlockTask(lock_flags);
    const t = getCurrentTaskMut() orelse return -1;
    const new = policy.setOne(gidIds(t), gid, t.effective_caps.cap_setgid) orelse return if (gid == policy.KEEP) -22 else -1;
    applyGids(t, new);
    return 0;
}

/// setreuid(ruid, euid)
pub fn setreuid(ruid: u32, euid: u32) i64 {
    const lock_flags = task_mod.lockTask();
    defer task_mod.unlockTask(lock_flags);
    const t = getCurrentTaskMut() orelse return -1;
    applyUids(t, policy.setre(uidIds(t), ruid, euid, t.effective_caps.cap_setuid) orelse return -1);
    return 0;
}

/// setregid(rgid, egid)
pub fn setregid(rgid: u32, egid: u32) i64 {
    const lock_flags = task_mod.lockTask();
    defer task_mod.unlockTask(lock_flags);
    const t = getCurrentTaskMut() orelse return -1;
    applyGids(t, policy.setre(gidIds(t), rgid, egid, t.effective_caps.cap_setgid) orelse return -1);
    return 0;
}

/// setresuid(ruid, euid, suid)
pub fn setresuid(ruid: u32, euid: u32, suid: u32) i64 {
    const lock_flags = task_mod.lockTask();
    defer task_mod.unlockTask(lock_flags);
    const t = getCurrentTaskMut() orelse return -1;
    applyUids(t, policy.setres(uidIds(t), ruid, euid, suid, t.effective_caps.cap_setuid) orelse return -1);
    return 0;
}

/// getresuid(ruid*, euid*, suid*)
pub fn getresuid118(ruid_ptr: u64, euid_ptr: u64, suid_ptr: u64) i64 {
    const t = getCurrentTask() orelse return -1;
    if (ruid_ptr == 0 or euid_ptr == 0 or suid_ptr == 0) return -14;
    if (copy.copyToUser(@ptrFromInt(ruid_ptr), @as([*]const u8, @ptrCast(&t.uid))[0..4], 4) != 4) return -14;
    if (copy.copyToUser(@ptrFromInt(euid_ptr), @as([*]const u8, @ptrCast(&t.euid))[0..4], 4) != 4) return -14;
    if (copy.copyToUser(@ptrFromInt(suid_ptr), @as([*]const u8, @ptrCast(&t.suid))[0..4], 4) != 4) return -14;
    return 0;
}

/// setresgid(rgid, egid, sgid)
pub fn setresgid(rgid: u32, egid: u32, sgid: u32) i64 {
    const lock_flags = task_mod.lockTask();
    defer task_mod.unlockTask(lock_flags);
    const t = getCurrentTaskMut() orelse return -1;
    applyGids(t, policy.setres(gidIds(t), rgid, egid, sgid, t.effective_caps.cap_setgid) orelse return -1);
    return 0;
}

/// getresgid(rgid*, egid*, sgid*)
pub fn getresgid120(rgid_ptr: u64, egid_ptr: u64, sgid_ptr: u64) i64 {
    const t = getCurrentTask() orelse return -1;
    if (rgid_ptr == 0 or egid_ptr == 0 or sgid_ptr == 0) return -14;
    if (copy.copyToUser(@ptrFromInt(rgid_ptr), @as([*]const u8, @ptrCast(&t.gid))[0..4], 4) != 4) return -14;
    if (copy.copyToUser(@ptrFromInt(egid_ptr), @as([*]const u8, @ptrCast(&t.egid))[0..4], 4) != 4) return -14;
    if (copy.copyToUser(@ptrFromInt(sgid_ptr), @as([*]const u8, @ptrCast(&t.sgid))[0..4], 4) != 4) return -14;
    return 0;
}
