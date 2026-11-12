/// waitpid — wait for child process state changes.
///
/// Extracted from syscall_entry.zig (v18.9).
const copy = @import("../mm/copy_from_user.zig");
const sched_mod = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const se = @import("../arch/arch.zig").syscall;
const cpu_time_policy = @import("cpu_time_policy.zig");

/// waitpid(pid, status_ptr) -> child tid or -errno.
/// pid: -1 (any child) or >0 (specific child).
pub fn waitpid(pid_raw: u64, status_ptr: u64) i64 {
    return waitpidWithOptions(pid_raw, status_ptr, 0);
}

/// waitpidWithOptions — core implementation with WNOHANG support.
/// options: bit 0 = WNOHANG (return 0 immediately if no zombie child)
pub fn waitpidWithOptions(pid_raw: u64, status_ptr: u64, options: u32) i64 {
    return waitpidUsage(pid_raw, status_ptr, options, null);
}

/// waitpidWithOptions that also reports the reaped child's CPU time (wait4's rusage).
pub fn waitpidUsage(pid_raw: u64, status_ptr: u64, options: u32, usage_out: ?*cpu_time_policy.Usage) i64 {
    const pid: i32 = if (pid_raw == @as(u64, @bitCast(@as(i64, -1))))
        @as(i32, -1)
    else if (pid_raw > 0x7FFFFFFF)
        @as(i32, -1)
    else
        @intCast(pid_raw);

    const opt_rc = @import("proc_id_policy.zig").waitOptionsErrno(options);
    if (opt_rc != 0) return opt_rc;
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    if (status_ptr != 0 and !copy.validateUserBufferWritable(status_ptr, 4)) return -14;

    if (!task_mod.hasMatchingChild(cur_idx, pid)) return -10; // -ECHILD: nothing waitpid(pid) could select

    var exit_code: i32 = 0;
    if (task_mod.waitpid(cur_idx, pid, &exit_code, usage_out)) |child_tid| {
        if (!writeStatus(status_ptr, exit_code)) return -14;
        return child_tid;
    }

    // WUNTRACED / WCONTINUED: a live child's unreported stop or continue.
    if (task_mod.takeWaitReport(cur_idx, pid, options, &exit_code)) |child_tid| {
        if (!writeStatus(status_ptr, exit_code)) return -14;
        return child_tid;
    }

    // WNOHANG: return 0 immediately if no zombie child
    if (options & 1 != 0) return 0;

    // No zombie child yet — block on each matching child's exit queue. The
    // previous waitpid path hlt-spun in the syscall until a child exited, which
    // deadlocked on a single CPU because the newly spawned child never ran.
    const parent = task_mod.getTask(cur_idx) orelse return -1;
    const sig_mod = @import("signal.zig");

    // Retry loop: any child's exit clears `waiting_for_child` (exitTask does
    // not filter by target pid), so a non-target child's exit must NOT end the
    // wait — reap our target if available, otherwise re-block. Returning 0
    // here made waitpid(specific_pid) spuriously succeed (hello44 RR test).
    while (true) {
        // Atomic block protocol: the flag store, the zombie scan and the
        // .blocked store all happen under task_lock — the same lock exitTask
        // holds across its zombie store + wake check. Either exitTask's
        // section runs first (our scan sees the zombie) or ours runs first
        // (exitTask sees flag=true && state==.blocked and performs the full
        // wake: flag clear + .ready + enqueue + kick). The previous split
        // protocol (flag store outside the lock) let the wake slip between
        // the flag store and the scan, stranding the waiter off-CPU.
        const tflags = task_mod.lockTask();
        parent.waiting_for_child = true;
        parent.wait_cpu = @intCast(se.getPerCpu().cpu_id);
        // Under the same lock as noteChildStateChange's record + wake, so a stop or continue cannot slip past this check.
        if (task_mod.takeWaitReportLocked(cur_idx, pid, options, &exit_code, true)) |child_tid| {
            parent.waiting_for_child = false;
            task_mod.unlockTask(tflags);
            if (!writeStatus(status_ptr, exit_code)) return -14;
            return child_tid;
        }

        switch (task_mod.waitpidScanLocked(cur_idx, pid, &exit_code)) {
            .reaped => |reaped| {
                parent.waiting_for_child = false;
                task_mod.unlockTask(tflags);
                task_mod.finishReap(reaped);
                if (usage_out) |u| u.* = reaped.usage;
                if (!writeStatus(status_ptr, exit_code)) return -14;
                return reaped.tid;
            },
            .busy => {
                // Gated zombie — nobody will re-wake us for it (its exitTask
                // ran already), so never block: spin-reap outside the lock.
                parent.waiting_for_child = false;
                task_mod.unlockTask(tflags);
                if (task_mod.waitpid(cur_idx, pid, &exit_code, usage_out)) |child_tid| {
                    if (!writeStatus(status_ptr, exit_code)) return -14;
                    return child_tid;
                }
                continue;
            },
            .none => {
                if (!task_mod.hasChildrenLocked(cur_idx)) {
                    parent.waiting_for_child = false;
                    task_mod.unlockTask(tflags);
                    return -10; // -ECHILD
                }
                se.syncUserRspToTask(parent);
                // Blocked under the lock — see the protocol comment above.
                @import("sched_claim.zig").store(&parent.state, .blocked);
                task_mod.unlockTask(tflags);
                task_mod.kickChildCpus(parent.tid, parent.wait_cpu);
                sched_mod.requestReschedule();
            },
        }

        while (@as(*volatile bool, @ptrCast(&parent.waiting_for_child)).* and !sig_mod.pendingActionable(parent)) {
            asm volatile ("sti");
            asm volatile ("hlt" ::: .{ .memory = true });
        }
        parent.waiting_for_child = false;
        // State repair: the wait loop runs with state == .blocked while this
        // task is still current and executing on this CPU. If the wake landed
        // while we were still .running, exitTask deliberately skipped the
        // .ready store — so nothing transitions us back, and the next
        // switch-out would drop a .blocked current task from the runnable set
        // for good (observed as a post-waitpid stall, [wp] woke ... state=2).
        // Being here proves we are this CPU's current task, so restore
        // .running unless a switch/re-claim already did.
        if (parent.state != .running) {
            @import("sched_claim.zig").store(&parent.state, .running);
        }
        se.syncUserRspFromTask(parent);
        se.getPerCpu().kernel_rsp = parent.kernel_stack_top;
        @import("../arch/arch.zig").gdt.setRsp0(se.getPerCpu().cpu_id, parent.kernel_stack_top);
        // ioperm: pair every per-switch RSP0 update with the IOPB load.
        @import("ioperm.zig").loadForTask(se.getPerCpu().cpu_id, parent);

        // Woken up — a child may have exited. Reap first: a pending signal
        // only aborts the wait when no child status is available, so an
        // EINTR'd (or killed) waitpid never consumes the child's exit status.
        if (task_mod.waitpid(cur_idx, pid, &exit_code, usage_out)) |child_tid| {
            if (!writeStatus(status_ptr, exit_code)) return -14;
            return child_tid;
        }
        if (task_mod.takeWaitReport(cur_idx, pid, options, &exit_code)) |child_tid| {
            if (!writeStatus(status_ptr, exit_code)) return -14;
            return child_tid;
        }
        // Signal kick (sendSignal unblocks without a child exit): die on a
        // fatal signal via the same exit-by-signal path the timer tick uses,
        // or report EINTR so the handler can run on return.
        if (sig_mod.pendingFatal(parent)) |sig| task_mod.exitTask(128 + @as(i32, @intCast(sig)));
        if (sig_mod.pendingActionable(parent)) return -4; // -EINTR
        // Non-target child exit (or spurious wake): loop and re-block.
    }
}

fn writeStatus(status_ptr: u64, exit_code: i32) bool {
    if (status_ptr == 0) return true;
    if (status_ptr >= 0x0000_8000_0000_0000) return false;
    const src: [*]const u8 = @ptrCast(&exit_code);
    return copy.copyToUser(@ptrFromInt(status_ptr), src[0..4], 4) == 4;
}

const wid = @import("waitid_policy.zig");
const siginfo = @import("siginfo_policy.zig");
const wsp = @import("wait_status_policy.zig");

/// waitid(idtype, id, infop, options, ru) -> 0 or -errno. Unlike waitpid the success value is always 0; the child's identity and
/// status go into the caller's siginfo. A null infop is allowed and still reaps. WNOHANG with nothing to report returns 0 and
/// clears the siginfo (si_signo 0). `ru`, when non-null, receives the child's CPU time, but only when a child was actually
/// reported — a WNOHANG that found nothing leaves the buffer untouched.
pub fn waitid(idtype: u32, id: u64, infop: u64, options: u32, ru: u64) i64 {
    const req = wid.request(idtype, id, options) orelse return wid.EINVAL;
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    if (infop != 0 and !copy.validateUserBufferWritable(infop, siginfo.SIGINFO_SIZE)) return -14;
    if (ru != 0 and !copy.validateUserBufferWritable(ru, rusage_policy.RUSAGE_SIZE)) return -14;
    if (!task_mod.hasMatchingChild(cur_idx, req.pid)) return -10; // -ECHILD

    if (collectWaitid(cur_idx, req)) |got| {
        return publishWaitid(infop, ru, got);
    }
    if (options & wid.WNOHANG != 0) return publishWaitid(infop, ru, null);

    const parent = task_mod.getTask(cur_idx) orelse return -1;
    const sig_mod = @import("signal.zig");
    while (true) {
        const tflags = task_mod.lockTask();
        parent.waiting_for_child = true;
        parent.wait_cpu = @intCast(se.getPerCpu().cpu_id);
        switch (collectWaitidLocked(cur_idx, req)) {
            .got => |got| {
                parent.waiting_for_child = false;
                task_mod.unlockTask(tflags);
                if (got.finish) |r| task_mod.finishReap(r);
                return publishWaitid(infop, ru, got);
            },
            .busy => {
                parent.waiting_for_child = false;
                task_mod.unlockTask(tflags);
                asm volatile ("sti");
                @import("../arch/arch.zig").cpu.pause();
                continue;
            },
            .none => {},
        }
        if (!task_mod.hasChildrenLocked(cur_idx)) {
            parent.waiting_for_child = false;
            task_mod.unlockTask(tflags);
            return -10;
        }
        se.syncUserRspToTask(parent);
        @import("sched_claim.zig").store(&parent.state, .blocked);
        task_mod.unlockTask(tflags);
        task_mod.kickChildCpus(parent.tid, parent.wait_cpu);
        sched_mod.requestReschedule();

        while (@as(*volatile bool, @ptrCast(&parent.waiting_for_child)).* and !sig_mod.pendingActionable(parent)) {
            asm volatile ("sti");
            asm volatile ("hlt" ::: .{ .memory = true });
        }
        parent.waiting_for_child = false;
        if (parent.state != .running) @import("sched_claim.zig").store(&parent.state, .running);
        se.syncUserRspFromTask(parent);
        se.getPerCpu().kernel_rsp = parent.kernel_stack_top;
        @import("../arch/arch.zig").gdt.setRsp0(se.getPerCpu().cpu_id, parent.kernel_stack_top);
        @import("ioperm.zig").loadForTask(se.getPerCpu().cpu_id, parent);

        if (collectWaitid(cur_idx, req)) |got| return publishWaitid(infop, ru, got);
        if (sig_mod.pendingFatal(parent)) |sig| task_mod.exitTask(128 + @as(i32, @intCast(sig)));
        if (sig_mod.pendingActionable(parent)) return -4;
    }
}

const WaitidGot = struct {
    child_tid: u32,
    uid: u32,
    rep: wid.Report,
    /// The child's CPU time, written to the caller's rusage when one was passed.
    usage: cpu_time_policy.Usage = .{},
    /// Non-null when the child was reaped and its teardown is still owed.
    finish: ?task_mod.Reaped = null,
};

const rusage_policy = @import("rusage_policy.zig");

fn publishWaitid(infop: u64, ru: u64, got: ?WaitidGot) i64 {
    if (got) |g| if (ru != 0 and !writeRusage(ru, g.usage)) return -14;
    if (infop == 0) return 0;
    const bytes: [siginfo.SIGINFO_SIZE]u8 = if (got) |g|
        siginfo.encode(17, .{ .code = g.rep.code, .a = siginfo.pidUid(g.child_tid, g.uid), .b = g.rep.status })
    else
        @splat(0);
    return if (copy.copyToUser(@ptrFromInt(infop), &bytes, siginfo.SIGINFO_SIZE) == siginfo.SIGINFO_SIZE) 0 else -14;
}

/// struct rusage: the child's user and system CPU time in the first two timevals, the rest zero.
fn writeRusage(ru: u64, usage: cpu_time_policy.Usage) bool {
    const bo = @import("../lib/byte_order.zig");
    var buf: [rusage_policy.RUSAGE_SIZE]u8 = @splat(0);
    const user = rusage_policy.timeval(usage.user_us);
    const sys = rusage_policy.timeval(usage.sys_us);
    bo.writeU64Le(buf[0..8], user.sec);
    bo.writeU64Le(buf[8..16], user.usec);
    bo.writeU64Le(buf[16..24], sys.sec);
    bo.writeU64Le(buf[24..32], sys.usec);
    return copy.copyToUser(@ptrFromInt(ru), &buf, buf.len) == buf.len;
}

/// One non-blocking pass over the caller's children. `.busy` means a matching zombie exists but is not yet reapable, so the
/// caller retries instead of reporting that nothing happened.
const WaitidPass = union(enum) { none, busy, got: WaitidGot };

fn collectWaitid(cur_idx: u32, req: wid.Request) ?WaitidGot {
    while (true) {
        const flags = task_mod.lockTask();
        const pass = collectWaitidLocked(cur_idx, req);
        task_mod.unlockTask(flags);
        switch (pass) {
            .got => |g| {
                if (g.finish) |r| task_mod.finishReap(r);
                return g;
            },
            .none => return null,
            .busy => {
                asm volatile ("sti");
                @import("../arch/arch.zig").cpu.pause();
            },
        }
    }
}

/// Caller MUST hold task_lock, and MUST call finishReap on a non-null `finish` after releasing it.
fn collectWaitidLocked(cur_idx: u32, req: wid.Request) WaitidPass {
    if (req.options & wid.WEXITED != 0) {
        const nowait = req.options & wid.WNOWAIT != 0;
        switch (task_mod.peekZombieLocked(cur_idx, req.pid)) {
            .busy => if (!nowait) return .busy,
            .child => |slot| if (task_mod.getTask(slot)) |t| {
                const tid = t.tid;
                const uid = t.uid;
                const e = wsp.fromInternal(t.exit_code, t.exited_via_syscall);
                if (nowait) return .{ .got = .{ .child_tid = tid, .uid = uid, .usage = task_mod.childUsageLocked(tid), .rep = wid.report(req.options, .{ .zombie = true, .exit_value = e.value, .signaled = e.signaled }).? } };
                var scratch: i32 = 0;
                switch (task_mod.waitpidScanLocked(cur_idx, req.pid, &scratch)) {
                    .reaped => |r| return .{ .got = .{
                        .child_tid = r.tid,
                        .uid = uid,
                        .usage = r.usage,
                        .rep = .{ .code = if (e.signaled) wid.CLD_KILLED else wid.CLD_EXITED, .status = e.value, .reap = true },
                        .finish = r,
                    } },
                    .busy => return .busy,
                    .none => {},
                }
            },
            .none => {},
        }
        // WNOWAIT may report a zombie that is not reapable yet: its exit code is already final, and nothing is freed.
        if (nowait) if (waitidBusyZombie(cur_idx, req)) |g| return .{ .got = g };
    }
    var scratch: i32 = 0;
    if (task_mod.takeWaitReportLocked(cur_idx, req.pid, req.options, &scratch, req.options & wid.WNOWAIT == 0)) |child_tid| {
        const stopped = (scratch & 0xff) == 0x7f;
        const uid: u32 = if (task_mod.findTaskByTidLocked(child_tid)) |slot| (task_mod.getTask(slot) orelse return .none).uid else 0;
        return .{ .got = .{
            .child_tid = child_tid,
            .uid = uid,
            .usage = task_mod.childUsageLocked(child_tid),
            .rep = .{ .code = if (stopped) wid.CLD_STOPPED else wid.CLD_CONTINUED, .status = if (stopped) @as(u32, @intCast((scratch >> 8) & 0xff)) else wid.SIGCONT, .reap = false },
        } };
    }
    return .none;
}

/// A matching zombie that peekZombieLocked called busy, reported for WNOWAIT only. Caller holds task_lock.
fn waitidBusyZombie(cur_idx: u32, req: wid.Request) ?WaitidGot {
    const parent = task_mod.getTask(cur_idx) orelse return null;
    var i: u32 = 0;
    while (i < task_mod.MAX_TASKS) : (i += 1) {
        const t = task_mod.getTask(i) orelse continue;
        if (t.parent_tid != parent.tid or t.is_thread or t.state != .zombie) continue;
        if (!@import("proc_id_policy.zig").waitMatches(req.pid, t.tid, t.pgid, parent.pgid)) continue;
        const e = wsp.fromInternal(t.exit_code, t.exited_via_syscall);
        return .{ .child_tid = t.tid, .uid = t.uid, .usage = task_mod.childUsageLocked(t.tid), .rep = wid.report(req.options, .{ .zombie = true, .exit_value = e.value, .signaled = e.signaled }).? };
    }
    return null;
}
