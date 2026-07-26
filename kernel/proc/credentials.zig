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

/// setuid(uid) — set real and effective user ID.
pub fn setuid(uid: u32) i64 {
    const t = getCurrentTaskMut() orelse return -1;
    if (t.euid != 0 and uid != t.uid and uid != t.suid) return -1; // EPERM
    t.uid = uid;
    t.euid = uid;
    t.suid = uid;
    return 0;
}

/// setgid(gid) — set real and effective group ID.
pub fn setgid(gid: u32) i64 {
    const t = getCurrentTaskMut() orelse return -1;
    if (t.egid != 0 and gid != t.gid and gid != t.sgid) return -1;
    t.gid = gid;
    t.egid = gid;
    t.sgid = gid;
    return 0;
}

/// setreuid(ruid, euid)
pub fn setreuid(ruid: u32, euid: u32) i64 {
    const t = getCurrentTaskMut() orelse return -1;
    if (ruid != 0xFFFFFFFF and t.euid != 0 and ruid != t.uid and ruid != t.suid) return -1;
    if (euid != 0xFFFFFFFF and t.euid != 0 and euid != t.uid and euid != t.euid and euid != t.suid) return -1;
    if (ruid != 0xFFFFFFFF) t.uid = ruid;
    if (euid != 0xFFFFFFFF) {
        t.euid = euid;
        t.suid = euid;
    }
    return 0;
}

/// setregid(rgid, egid)
pub fn setregid(rgid: u32, egid: u32) i64 {
    const t = getCurrentTaskMut() orelse return -1;
    if (rgid != 0xFFFFFFFF and t.egid != 0 and rgid != t.gid and rgid != t.sgid) return -1;
    if (egid != 0xFFFFFFFF and t.egid != 0 and egid != t.gid and egid != t.egid and egid != t.sgid) return -1;
    if (rgid != 0xFFFFFFFF) t.gid = rgid;
    if (egid != 0xFFFFFFFF) {
        t.egid = egid;
        t.sgid = egid;
    }
    return 0;
}

/// setresuid(ruid, euid, suid)
pub fn setresuid(ruid: u32, euid: u32, suid: u32) i64 {
    const t = getCurrentTaskMut() orelse return -1;
    if (t.euid != 0) {
        for ([_]u32{ ruid, euid, suid }) |val| {
            if (val != 0xFFFFFFFF and val != t.uid and val != t.euid and val != t.suid) return -1;
        }
    }
    if (ruid != 0xFFFFFFFF) t.uid = ruid;
    if (euid != 0xFFFFFFFF) t.euid = euid;
    if (suid != 0xFFFFFFFF) t.suid = suid;
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
    const t = getCurrentTaskMut() orelse return -1;
    if (t.egid != 0) {
        for ([_]u32{ rgid, egid, sgid }) |val| {
            if (val != 0xFFFFFFFF and val != t.gid and val != t.egid and val != t.sgid) return -1;
        }
    }
    if (rgid != 0xFFFFFFFF) t.gid = rgid;
    if (egid != 0xFFFFFFFF) t.egid = egid;
    if (sgid != 0xFFFFFFFF) t.sgid = sgid;
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
