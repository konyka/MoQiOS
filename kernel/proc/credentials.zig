// kernel/proc/credentials.zig — Credential management syscalls
//
// setuid/setgid/setreuid/setregid/setresuid/getresuid/setresgid/getresgid/setfsuid/setfsgid/getgroups/setgroups

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

/// Install new user IDs: capabilities follow capabilities(7), the per-real-UID
/// task count (RLIMIT_NPROC) moves with the real UID, and the fs uid follows the
/// effective one (Linux sets fsuid = euid; the fs capabilities are not touched).
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
    t.fsuid = new.e;
}

/// Install new group IDs; the fs gid follows the effective one (Linux: every setgid-family change sets fsgid = egid).
fn applyGids(t: *task_mod.Task, new: policy.Ids) void {
    t.gid = new.r;
    t.egid = new.e;
    t.sgid = new.s;
    t.fsgid = new.e;
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
    if (policy.resIsNoop(uidIds(t), t.fsuid, ruid, euid, suid)) return 0;
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
    if (policy.resIsNoop(gidIds(t), t.fsgid, rgid, egid, sgid)) return 0;
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

/// The file-system capabilities (Linux CAP_FS_MASK: CAP_CHOWN, CAP_MKNOD, CAP_DAC_OVERRIDE, CAP_DAC_READ_SEARCH, CAP_FOWNER,
/// CAP_FSETID, CAP_MAC_OVERRIDE), as far as SysCap models them.
const FS_CAPS: u32 = @bitCast(@import("capability_profile.zig").SysCap{ .cap_chown = true, .cap_mknod = true, .cap_dac_override = true, .cap_fowner = true });

/// setfsuid(uid): returns the old fs uid whether or not it changed (Linux __sys_setfsuid). The new id must be the real,
/// effective, saved or current fs uid unless the caller holds CAP_SETUID. Leaving fs uid 0 drops the file-system capabilities
/// from the effective set; coming back to 0 raises the permitted ones (cap_task_fix_setuid LSM_SETID_FS).
pub fn setfsuid(uid: u32) i64 {
    const lock_flags = task_mod.lockTask();
    defer task_mod.unlockTask(lock_flags);
    const t = getCurrentTaskMut() orelse return -1;
    const old = t.fsuid;
    const new = policy.setFs(uidIds(t), old, uid, t.effective_caps.cap_setuid) orelse return old;
    const caps = policy.capsAfterFsuidChange(old, new, .{ .effective = @bitCast(t.effective_caps), .permitted = @bitCast(t.permitted_caps) }, FS_CAPS);
    t.effective_caps = @bitCast(caps.effective);
    t.fsuid = new;
    return old;
}

/// setfsgid(gid): returns the old fs gid; the new one must be a current gid unless the caller holds CAP_SETGID.
pub fn setfsgid(gid: u32) i64 {
    const lock_flags = task_mod.lockTask();
    defer task_mod.unlockTask(lock_flags);
    const t = getCurrentTaskMut() orelse return -1;
    const old = t.fsgid;
    t.fsgid = policy.setFs(gidIds(t), old, gid, t.effective_caps.cap_setgid) orelse return old;
    return old;
}

const groups = @import("group_policy.zig");

/// getgroups(size, list) — supplementary group IDs of the caller.
pub fn getgroups(size: i64, list_ptr: u64) i64 {
    const t = getCurrentTask() orelse return -1;
    const n = t.ngroups;
    switch (groups.get(size, n)) {
        .einval => return -22,
        .count => |c| return c,
        .copy => |c| {
            if (c == 0) return 0;
            const bytes = c * 4;
            if (list_ptr == 0 or !copy.validateUserBufferWritable(list_ptr, bytes)) return -14;
            if (copy.copyToUser(@ptrFromInt(list_ptr), @as([*]const u8, @ptrCast(&t.groups))[0..bytes], bytes) != bytes) return -14;
            return c;
        },
    }
}

/// setgroups(size, list) — replace the supplementary groups (CAP_SETGID).
pub fn setgroups(size: i64, list_ptr: u64) i64 {
    var buf: [groups.NGROUPS_MAX]u32 = undefined;
    const caller = getCurrentTask() orelse return -1;
    switch (groups.checkSet(size, caller.effective_caps.cap_setgid)) {
        .eperm => return -1,
        .einval => return -22,
        .ok => {},
    }
    const n: u32 = @intCast(size);
    if (n > 0) {
        const bytes = n * 4;
        if (list_ptr == 0 or !copy.validateUserBuffer(list_ptr, bytes)) return -14;
        if (copy.copyFromUser(@as([*]u8, @ptrCast(&buf))[0..bytes], @ptrFromInt(list_ptr), bytes) != bytes) return -14;
    }
    const lock_flags = task_mod.lockTask();
    defer task_mod.unlockTask(lock_flags);
    const t = getCurrentTaskMut() orelse return -1;
    @memcpy(t.groups[0..n], buf[0..n]);
    t.ngroups = n;
    return 0;
}

/// Apply execve(2) credential rules to the calling task (cred_policy.afterExec).
pub fn applyExec(t: *task_mod.Task) void {
    const lock_flags = task_mod.lockTask();
    defer task_mod.unlockTask(lock_flags);
    const ec = policy.afterExec(uidIds(t), gidIds(t), .{
        .effective = @bitCast(t.effective_caps),
        .permitted = @bitCast(t.permitted_caps),
    });
    t.suid = ec.uid.s;
    t.sgid = ec.gid.s;
    t.fsuid = t.euid;
    t.fsgid = t.egid;
    t.effective_caps = @bitCast(ec.caps.effective);
    t.permitted_caps = @bitCast(ec.caps.permitted);
}
