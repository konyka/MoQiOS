/// Process group and session management — setpgid, getpgid, setsid, getsid.
///
/// Process groups are used for job control (signal delivery to a group).
/// Sessions group process groups, typically associated with a controlling terminal.
///
/// Invariants:
///   - A session leader's sid == its pid, and pgid == its pid
///   - A process group leader's pgid == its pid
///   - Child processes inherit parent's pgid and sid on fork
///   - setsid() creates a new session AND new process group
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const task_mod = @import("task.zig");
const sched = @import("sched.zig");

var pgrp_lock: IrqSpinlock = .{};

// errno constants (negative return values)
const errno = @import("../lib/errno.zig");
const EPERM = errno.EPERM;
const ESRCH = errno.ESRCH;
const EINVAL = errno.EINVAL;

/// setpgid(pid, pgid) → 0 on success, negative errno on failure
/// pid=0: use current process; pgid=0: use pid as pgid
pub fn sysSetpgid(pid_arg: u64, pgid_arg: u64) i64 {
    const flags = pgrp_lock.acquire();
    defer pgrp_lock.release(flags);

    const cur_idx = sched.currentTaskIndex() orelse return ESRCH;
    const cur = task_mod.getTask(cur_idx) orelse return ESRCH;

    // Resolve target task
    // Use public findTaskByTid which acquires its own lock,
    // but since we already hold pgrp_lock, we need the locked variant.
    // For now, scan the task array directly under our lock.
    var target_idx: ?u32 = null;
    var target_tid: u32 = undefined;

    if (pid_arg == 0) {
        target_idx = cur_idx;
        target_tid = cur.tid;
    } else {
        target_tid = @intCast(pid_arg);
        // Find the task with this tid by scanning task array
        for (0..task_mod.MAX_TASKS) |i| {
            if (task_mod.getTask(@intCast(i))) |t| {
                if (t.tid == target_tid and t.state != .zombie) {
                    target_idx = @intCast(i);
                    break;
                }
            }
        }
        if (target_idx == null) return ESRCH;
    }

    const target = task_mod.getTask(target_idx orelse return ESRCH) orelse return ESRCH;
    // Only allow setting pgid for self or child processes
    if (target_idx.? != cur_idx) {
        if (target.parent_tid != cur.tid) {
            return EPERM; // Not self and not a child
        }
        // Child must not have done exec yet — simplified: we allow it always
        // since we don't track exec state
    }

    // Determine the new pgid
    const new_pgid: u16 = if (pgid_arg == 0) @intCast(target_tid) else @intCast(pgid_arg);

    // The new pgid must match an existing process group (i.e., some process
    // with pgid == new_pgid) or be equal to target_tid (creating a new group)
    if (new_pgid != @as(u16, @intCast(target_tid))) {
        // Verify that the pgid exists (some process has this pgid)
        // and that it's in the same session
        var found_group = false;
        for (0..task_mod.MAX_TASKS) |i| {
            if (task_mod.getTask(@intCast(i))) |t| {
                if (t.pgid == new_pgid and t.sid == target.sid) {
                    found_group = true;
                    break;
                }
            }
        }
        if (!found_group) return EPERM;
    } else {
        // Session leader check only applies when creating a NEW group
        if (target.sid == @as(u16, @intCast(target.tid))) {
            return EPERM;
        }
    }

    // Cannot change pgid of a session leader
    if (target.sid == @as(u16, @intCast(target.tid))) {
        return EPERM;
    }

    target.pgid = new_pgid;
    return 0;
}

/// getpgid(pid) → pgid on success, negative errno on failure
/// pid=0: return current process's pgid
pub fn sysGetpgid(pid_arg: u64) i64 {
    const flags = pgrp_lock.acquire();
    defer pgrp_lock.release(flags);

    if (pid_arg == 0) {
        const cur_idx = sched.currentTaskIndex() orelse return ESRCH;
        const cur = task_mod.getTask(cur_idx) orelse return ESRCH;
        return cur.pgid;
    }

    const tid: u32 = @intCast(pid_arg);
    // Scan task array under our lock
    var found_idx: ?u32 = null;
    for (0..task_mod.MAX_TASKS) |i| {
        if (task_mod.getTask(@intCast(i))) |t| {
            if (t.tid == tid and t.state != .zombie) {
                found_idx = @intCast(i);
                break;
            }
        }
    }
    const t = task_mod.getTask(found_idx orelse return ESRCH) orelse return ESRCH;
    return t.pgid;
}

/// setsid() → new session id on success, negative errno on failure
/// Creates a new session and a new process group.
/// The calling process becomes the session leader.
pub fn sysSetsid() i64 {
    const flags = pgrp_lock.acquire();
    defer pgrp_lock.release(flags);

    const cur_idx = sched.currentTaskIndex() orelse return ESRCH;
    const cur = task_mod.getTask(cur_idx) orelse return ESRCH;

    // Cannot be a process group leader already
    if (cur.pgid == @as(u16, @intCast(cur.tid))) {
        return EPERM;
    }

    // Create new session: sid = pid, pgid = pid
    const new_id: u16 = @intCast(cur.tid);
    cur.sid = new_id;
    cur.pgid = new_id;

    // Detach controlling terminal (set to 0 — no controlling tty)
    // This is conceptual; when tty support is added, clear the tty pointer

    return new_id;
}

/// getsid(pid) → session id on success, negative errno on failure
/// pid=0: return current process's session id
pub fn sysGetsid(pid_arg: u64) i64 {
    const flags = pgrp_lock.acquire();
    defer pgrp_lock.release(flags);

    if (pid_arg == 0) {
        const cur_idx = sched.currentTaskIndex() orelse return ESRCH;
        const cur = task_mod.getTask(cur_idx) orelse return ESRCH;
        return cur.sid;
    }

    const tid: u32 = @intCast(pid_arg);
    // Scan task array under our lock
    var found_idx: ?u32 = null;
    for (0..task_mod.MAX_TASKS) |i| {
        if (task_mod.getTask(@intCast(i))) |t| {
            if (t.tid == tid and t.state != .zombie) {
                found_idx = @intCast(i);
                break;
            }
        }
    }
    const t = task_mod.getTask(found_idx orelse return ESRCH) orelse return ESRCH;

    // Caller must be in the same session as the target process
    const cur_idx = sched.currentTaskIndex() orelse return ESRCH;
    const cur = task_mod.getTask(cur_idx) orelse return ESRCH;
    if (t.sid != cur.sid) {
        return EPERM;
    }

    return t.sid;
}
