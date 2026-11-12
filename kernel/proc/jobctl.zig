/// kernel/proc/jobctl.zig — 作业控制（v1）：单一控制终端模型。
///
/// 模型：全系统一个控制台（fd 0 = 键盘）。首次访问 fd 0 的会话认领它
/// （ctty_owner_sid）；owner 会话的前台进程组为 foreground_pgid。
/// - 后台进程读 fd 0：投递 SIGTTIN 到其进程组；已装 handler → read 返回
///   EINTR；默认动作 → 组内全部停止（stopped），SIGCONT 后继续。
/// - SIGTTIN 被阻塞/忽略：read 返回 EIO。
/// - 退出：控制台的会话长退出时前台组收 SIGHUP 并释放控制台；因退出成为孤儿且含
///   停止成员的进程组收 SIGHUP + SIGCONT（onExit，规则见 orphan_pgrp_policy.zig）。
const sched = @import("sched.zig");
const task_mod = @import("task.zig");
const sig_mod = @import("signal.zig");
const sched_claim = @import("sched_claim.zig");

/// 控制台归属：认领它的会话（0 = 未认领）。
pub var ctty_owner_sid: u16 = 0;
/// owner 会话的前台进程组（0 = 未设置——此时所有组视为前台）。
pub var foreground_pgid: u16 = 0;

fn currentTask() ?*task_mod.Task {
    const idx = sched.currentTaskIndex() orelse return null;
    return task_mod.getTask(idx);
}

/// fd 0 读前的作业控制检查。
/// 返回 0 = 放行；-5(EIO) = SIGTTIN 被阻塞/忽略；-4(EINTR) = 已投递 SIGTTIN。
pub fn stdinJobCheck() i64 {
    const cur = currentTask() orelse return 0;
    if (!cur.is_user) return 0;

    // 首次使用即认领控制台。
    if (ctty_owner_sid == 0) {
        ctty_owner_sid = cur.sid;
        if (foreground_pgid == 0) foreground_pgid = cur.pgid;
        return 0;
    }
    // 未设置前台组：所有组视为前台。
    if (foreground_pgid == 0) return 0;
    // 前台组：放行。
    if (cur.pgid == foreground_pgid) return 0;

    // 后台组：SIGTTIN 被阻塞或忽略 → EIO。
    const sig_bit: u64 = @as(u64, 1) << @intCast(sig_mod.SIGTTIN - 1);
    if (cur.signal_mask & sig_bit != 0) return -5; // EIO
    const handler = cur.sigact().handlers[sig_mod.SIGTTIN - 1];
    if (handler == 1) return -5; // SIG_IGN

    // 投递到整个后台组。POSIX：已装 handler 的进程走 EINTR 路径；
    // 默认停的进程不返回——在内核等待直到本组成为前台（SIGCONT 解除停止后
    // 由 TIOCSPGRP 切换），恢复后进入真正的键盘读。
    _ = sig_mod.sendSignalToPgrp(cur.pgid, sig_mod.SIGTTIN);
    if (handler != 0) return -4; // EINTR（handler 在 syscall 返回路径运行）

    // 默认停：内核内等待前台化。SIGCONT 先解除停止态，TIOCSPGRP 改前台组；
    // 致命信号也会解除停止态并唤醒本进程以便终止。
    while (cur.stopped or cur.pgid != foreground_pgid) {
        const sc = @import("sched_claim.zig");
        if (sc.load(&cur.state) == .running) sc.store(&cur.state, .blocked);
        asm volatile ("sti");
        asm volatile ("hlt" ::: .{ .memory = true });
        // 被致命信号解除停止：交给信号路径处理（返回 EINTR 让其终结）。
        if (!cur.stopped and cur.pgid != foreground_pgid and
            (cur.pending_signals & ~cur.signal_mask) != 0) return -4;
    }
    return 0;
}

/// TIOCSPGRP 权限与状态更新。返回 0 / -1(EPERM) / -3(ESRCH)。
pub fn tcSetForegroundPgrp(new_pgid: u16) i64 {
    const cur = currentTask() orelse return -3;
    if (ctty_owner_sid == 0) ctty_owner_sid = cur.sid;
    if (cur.sid != ctty_owner_sid) return -1; // 只有 owner 会话能设前台组

    // 目标组必须存在于本会话。
    var found = false;
    for (0..task_mod.MAX_TASKS) |i| {
        if (task_mod.getTask(@intCast(i))) |t| {
            if (t.pgid == new_pgid and t.sid == cur.sid and t.state != .zombie) {
                found = true;
                break;
            }
        }
    }
    if (!found) return -3;
    foreground_pgid = new_pgid;
    return 0;
}

/// A process exits (Linux exit_notify + disassociate_ctty):
///  1. a session leader that owns the console hangs it up: the foreground
///     process group gets SIGHUP, and the console is released;
///  2. every process group the exit leaves orphaned (no member keeps a parent
///     in another group of the same session) that has a stopped member gets
///     SIGHUP and SIGCONT — nobody could continue it otherwise. Checked for
///     the exiting process's own group and for each of its children's groups
///     (orphan_pgrp_policy).
/// Called outside task_lock (the signal paths re-take it).
pub fn onExit(exiting: *task_mod.Task) void {
    const policy = @import("orphan_pgrp_policy.zig");
    var members: [task_mod.MAX_TASKS]policy.Member = undefined;
    var n: usize = 0;
    var me: ?policy.Member = null;
    const init_tid = @atomicLoad(u32, &task_mod.init_tid, .acquire);
    for (0..task_mod.MAX_TASKS) |i| {
        const t = task_mod.getTask(@intCast(i)) orelse continue;
        if (!t.is_user or t.is_thread) continue;
        const zombie = t != exiting and sched_claim.load(&t.state) == .zombie;
        var parent_pgid: u32 = 0;
        var parent_sid: u32 = 0;
        var parent_alive = false;
        if (t.parent_tid != 0) {
            if (task_mod.findTaskByTid(t.parent_tid)) |pi| {
                if (task_mod.getTask(pi)) |par| {
                    parent_pgid = par.pgid;
                    parent_sid = par.sid;
                    parent_alive = true;
                }
            }
        }
        const m: policy.Member = .{
            .pid = t.tid,
            .parent_pid = t.parent_tid,
            .pgid = t.pgid,
            .sid = t.sid,
            .parent_pgid = parent_pgid,
            .parent_sid = parent_sid,
            .parent_is_init = !parent_alive or t.parent_tid == init_tid,
            .stopped = t.stopped,
            .zombie = zombie,
        };
        members[n] = m;
        n += 1;
        if (t == exiting) me = m;
    }
    const self = me orelse return;

    if (@import("proc_id_policy.zig").groupIdIsTid(exiting.sid, exiting.tid) and ctty_owner_sid == exiting.sid) {
        const fg = foreground_pgid;
        ctty_owner_sid = 0;
        foreground_pgid = 0;
        if (fg != 0) _ = sig_mod.sendSignalToPgrp(fg, sig_mod.SIGHUP);
    }

    var groups: [task_mod.MAX_TASKS]u32 = undefined;
    const count = policy.groupsToHangUp(members[0..n], self, &groups);
    for (groups[0..count]) |g| {
        const pgid: u16 = @intCast(g);
        _ = sig_mod.sendSignalToPgrp(pgid, sig_mod.SIGHUP);
        _ = sig_mod.sendSignalToPgrp(pgid, sig_mod.SIGCONT);
    }
}
