// kernel/proc/signal_syscall.zig — Signal-related syscall implementations
//
// Extracted from syscall_entry.zig: sigaction, sigprocmask, sigreturn,
// sigaltstack, rt_sigpending, rt_sigsuspend, rt_sigtimedwait,
// rt_sigqueueinfo, pidfd_send_signal, signalfd4, signalfd, rt_tgsigqueueinfo.

const sched = @import("sched.zig");
const task_mod = @import("task.zig");
const sig_mod = @import("signal.zig");
const copy = @import("../mm/copy_from_user.zig");
const vfs_mod = @import("../fs/vfs.zig");
const bo = @import("../lib/byte_order.zig");

// Access syscall_entry globals for sigreturn
const syscall_entry = @import("../arch/arch.zig").syscall;
const perm_policy = @import("signal_perm_policy.zig");
const action_policy = @import("signal_action_policy.zig");

/// Thread-group id (the pid getpid() reports) of a task.
fn threadGroupId(t: *task_mod.Task) u32 {
    return if (t.is_thread and t.parent_tid != 0) t.parent_tid else t.tid;
}

/// Permission gate for signalling the single task `target_tid` from the
/// current task (tkill, rt_sigqueueinfo, rt_tgsigqueueinfo,
/// pidfd_send_signal). Signalling your own process is allowed; anything
/// else needs cap_kill. A missing target is allowed here so the caller
/// still reports ESRCH. No current task means a kernel-internal caller.
pub fn currentMaySignalTask(target_tid: u32) bool {
    const cur = sched.currentTask() orelse return true;
    const idx = task_mod.findTaskByTid(target_tid) orelse return true;
    const target = task_mod.getTask(idx) orelse return true;
    return maySignal(cur, target);
}

/// POSIX kill(2) permission for one target: cap_kill, the sender's own
/// thread group, or matching real/effective vs real/saved uids.
pub fn maySignal(sender: *task_mod.Task, target: *task_mod.Task) bool {
    return perm_policy.credsAllow(
        .{ .uid = sender.uid, .euid = sender.euid, .suid = sender.suid },
        .{ .uid = target.uid, .euid = target.euid, .suid = target.suid },
        @field(sender.effective_caps, "cap_kill"),
        threadGroupId(sender) == threadGroupId(target),
    );
}

/// kill(2): pid > 0 one process, 0 the caller's process group, -1 every
/// process the caller may signal (except init and itself), < -1 group
/// -pid. signum 0 performs only the existence/permission check. Returns 0,
/// -ESRCH when no target exists, -EPERM when every target was refused.
pub fn killPosix(pid: i64, signum: u32) i64 {
    const id_policy = @import("proc_id_policy.zig");
    if (signum > 64) return -22;
    const cur = sched.currentTask() orelse return -3;
    if (pid == -1) return killAll(cur, signum);

    if (pid > 0) {
        const tid = id_policy.killTargetTid(pid) orelse return -3;
        const idx = task_mod.findTaskByTid(tid) orelse return -3;
        const target = task_mod.getTask(idx) orelse return -3;
        if (!maySignal(cur, target)) return -1;
        if (signum == 0) return 0;
        return if (sig_mod.sendSignal(tid, signum)) 0 else -3;
    }

    const pgid: u16 = if (pid == 0) cur.pgid else (id_policy.killTargetPgid(pid) orelse return -3);
    var found = false;
    var allowed = false;
    for (0..task_mod.MAX_TASKS) |i| {
        const t = task_mod.getTask(@intCast(i)) orelse continue;
        if (t.pgid != pgid or t.state == .zombie or !t.is_user) continue;
        found = true;
        if (!maySignal(cur, t)) continue;
        allowed = true;
    }
    if (!found) return -3;
    if (!allowed) return -1;
    if (signum == 0) return 0;
    _ = sig_mod.sendSignalToPgrpFiltered(pgid, signum, cur);
    return 0;
}


/// kill(-1, sig): every process but init and the caller's own (see
/// kill_broadcast_policy.zig for the target and return-value rules).
fn killAll(cur: *task_mod.Task, signum: u32) i64 {
    const bp = @import("kill_broadcast_policy.zig");
    const init_tid = @atomicLoad(u32, &task_mod.init_tid, .acquire);
    const self_group = threadGroupId(cur);
    var candidates: u32 = 0;
    for (0..task_mod.MAX_TASKS) |i| {
        const t = task_mod.getTask(@intCast(i)) orelse continue;
        if (!bp.isTarget(.{
            .is_user = t.is_user,
            .is_thread = t.is_thread,
            .zombie = t.state == .zombie,
            .is_init = init_tid != 0 and t.tid == init_tid,
            .same_thread_group = threadGroupId(t) == self_group,
        })) continue;
        candidates += 1;
        if (signum == 0 or !maySignal(cur, t)) continue;
        _ = sig_mod.sendSignal(t.tid, signum);
    }
    return bp.result(candidates);
}

/// sigaction(signum, act_ptr, oldact_ptr) → 0 or -errno
///
/// ABI note: Linux x86_64 struct sigaction is 152 bytes — handler@0, flags@8,
/// restorer@16, mask@24 (128-byte sigset). The legacy MoQiOS users (sh.c,
/// hello13, hello32) pass a 28/32-byte struct { handler, mask, flags,
/// restorer } of which only the handler was ever read. We keep validating
/// and reading the first 28 bytes exactly as before (handler from offset 0),
/// and additionally apply the u64 sa_mask at offset 24 with SIG_SETMASK
/// semantics only when the buffer validates for the full 152-byte Linux
/// struct. For the legacy users restorer@24 is 0, so even when the wider
/// probe succeeds the applied mask is 0 — their behavior is unchanged.
pub fn sigaction(signum: u32, act_ptr: u64, oldact_ptr: u64) i64 {
    if (signum == 0 or signum > 64) return -22;
    // SIGKILL/SIGSTOP cannot be caught or ignored; a pure query is fine.
    if (!action_policy.actionChangeAllowed(signum, act_ptr != 0)) return -22;

    const current = sched.currentTask() orelse return -1;
    const old_handler = current.signal_handlers[signum - 1];

    // Validate the optional output before changing the installed action.
    if (oldact_ptr != 0 and !copy.validateUserBufferWritable(oldact_ptr, 28)) return -14;
    if (act_ptr != 0 and !copy.validateUserBuffer(act_ptr, 28)) return -14;

    // Return old action if requested. Always written in the legacy 28-byte
    // form (handler + zeros): we cannot tell a 152-byte oldact buffer from
    // a 32-byte legacy one, and writing 152 bytes could overrun the latter.
    if (oldact_ptr != 0) {
        var old_buf: [28]u8 = undefined;
        @memset(&old_buf, 0);
        const handler_bytes: [*]const u8 = @ptrCast(&old_handler);
        @memcpy(old_buf[0..8], handler_bytes[0..8]);
        const old_flags = current.signal_sa_flags[signum - 1];
        const flag_bytes: [*]const u8 = @ptrCast(&old_flags);
        @memcpy(old_buf[8..16], flag_bytes[0..8]);
        // mask@24 is 8 bytes but the legacy-sized buffer is only 28; write
        // its low 4 bytes (signals 1-32), which is every signal this kernel has.
        const old_mask = current.signal_sa_masks[signum - 1];
        const mask_bytes: [*]const u8 = @ptrCast(&old_mask);
        @memcpy(old_buf[24..28], mask_bytes[0..4]);
        if (copy.copyToUser(@ptrFromInt(oldact_ptr), &old_buf, 28) != 28) return -14;
    }

    // Set new action if provided
    if (act_ptr != 0) {
        var act_buf: [28]u8 = undefined;
        const copied = copy.copyFromUser(&act_buf, @ptrFromInt(act_ptr), 28);
        if (copied != 28) return -14;
        const new_handler: u64 = @bitCast(act_buf[0..8].*);
        // Layout (Linux x86_64 / moqi_libc ksigaction): handler@0, flags@8,
        // restorer@16, mask@24. sa_mask is a PER-HANDLER mask applied only
        // while that handler runs (signal.pushSignalFrame) — it used to be
        // written straight into the task mask, permanently blocking those
        // signals after a single sigaction call.
        const new_flags: u64 = @bitCast(act_buf[8..16].*);
        var new_sa_mask: u64 = 0;
        var mask_buf: [8]u8 = undefined;
        if (copy.validateUserBuffer(act_ptr, 32) and copy.copyFromUser(&mask_buf, @ptrFromInt(act_ptr + 24), 8) == 8) {
            new_sa_mask = action_policy.sanitizeMask(@bitCast(mask_buf));
        }
        current.signal_handlers[signum - 1] = new_handler;
        current.signal_sa_masks[signum - 1] = new_sa_mask;
        current.signal_sa_flags[signum - 1] = new_flags;
    }

    return 0;
}

/// sigprocmask(how, set_ptr, oldset_ptr, sigsetsize) → 0 or -errno
///
/// The rt_* ABI advertises a 64-signal sigset_t (8 bytes); legacy callers
/// used a 4-byte mask. The width is chosen by sigsetsize (r10, as in Linux
/// rt_sigprocmask): >= 8 selects the 8-byte form, anything else keeps the
/// legacy 4-byte form so existing 4-byte users are not broken.
pub fn sigprocmask(how: u32, set_ptr: u64, oldset_ptr: u64, sigsetsize: u64) i64 {
    const current = sched.currentTask() orelse return -1;
    const old_mask = current.signal_mask;

    const width: usize = if (sigsetsize >= 8) 8 else 4;

    if (oldset_ptr != 0 and !copy.validateUserBufferWritable(oldset_ptr, width)) return -14;
    if (set_ptr != 0 and !copy.validateUserBuffer(set_ptr, width)) return -14;
    if (oldset_ptr != 0 and copy.copyToUser(@ptrFromInt(oldset_ptr), @as([*]const u8, @ptrCast(&old_mask))[0..width], width) != width) return -14;

    if (set_ptr != 0) {
        var new_set: u64 = 0;
        const new_set_bytes: [*]u8 = @ptrCast(&new_set);
        if (copy.copyFromUser(new_set_bytes[0..width], @ptrFromInt(set_ptr), width) != width) return -14;

        const sigkill_mask = @as(u64, 1) << 8;
        const sigstop_mask = @as(u64, 1) << 18;
        const unblockable = sigkill_mask | sigstop_mask;

        switch (how) {
            0 => {
                current.signal_mask |= new_set;
                current.signal_mask &= ~unblockable;
            },
            1 => {
                current.signal_mask &= ~new_set;
            },
            2 => {
                current.signal_mask = new_set & ~unblockable;
            },
            else => return -22,
        }
    }

    return 0;
}

/// Sigreturn context — stores register restore info for syscall entry path.
pub const SigreturnResult = struct {
    rip: u64,
    rsp: u64,
    rflags: u64,
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    rbp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
};

/// sigreturn() → SigreturnResult (register restore values)
/// This is special: it reads the signal frame and returns all register values
/// that need to be restored. The caller (syscall_entry) applies them.
pub fn sigreturn() ?SigreturnResult {
    const user_rsp = syscall_entry.getPerCpu().saved_user_rsp;
    // A process can reach sigreturn with an arbitrary RSP, so the frame address
    // is untrusted input. Reading it directly would fault inside the kernel on an
    // unmapped stack (fatal — there is no per-syscall recovery) and would feed
    // kernel memory straight back into user registers when RSP points high.
    const sig_frame = readSignalFrame(user_rsp) orelse return null;
    const gregs = &sig_frame.uc.gregs;
    const si = @import("siginfo_policy.zig");
    const sigreturn_policy = @import("sigreturn_policy.zig");
    if (!sigreturn_policy.userTargetValid(gregs[si.REG_RIP]) or
        !sigreturn_policy.userTargetValid(gregs[si.REG_RSP])) return null;
    const rflags = sigreturn_policy.sanitizeRflags(gregs[si.REG_EFL]);
    // Restore the interrupted mask (the handler ran with sa_mask | signum
    // added) and the interrupted x87/SSE state.
    if (sched.currentTask()) |cur| {
        cur.signal_mask = @import("signal_delivery_policy.zig").restoredMask(sig_frame.uc.sigmask);
    }
    if (comptime @import("builtin").cpu.arch == .x86_64) {
        // MXCSR comes from user memory: reserved bits set would make fxrstor
        // raise #GP in the kernel. Clear them (MXCSR_MASK default 0xFFBF).
        var fpu: [512]u8 align(16) = sig_frame.fpu;
        const mxcsr = @as(u32, fpu[24]) | (@as(u32, fpu[25]) << 8) | (@as(u32, fpu[26]) << 16) | (@as(u32, fpu[27]) << 24);
        const clean = mxcsr & 0xFFBF;
        fpu[24] = @truncate(clean);
        fpu[25] = @truncate(clean >> 8);
        fpu[26] = @truncate(clean >> 16);
        fpu[27] = @truncate(clean >> 24);
        asm volatile ("fxrstor (%[buf])"
            :
            : [buf] "r" (@as([*]const u8, @ptrCast(&fpu))),
            : .{ .memory = true });
    }
    // M8-5b-1: per-CPU exec redirect for the syscall return path
    const pc = syscall_entry.getPerCpu();
    pc.exec_pending = 2;
    pc.exec_new_entry = gregs[si.REG_RIP];
    pc.exec_new_stack = gregs[si.REG_RSP];
    pc.exec_new_flags = rflags;

    return .{
        .rip = gregs[si.REG_RIP],
        .rsp = gregs[si.REG_RSP],
        .rflags = rflags,
        .rax = gregs[si.REG_RAX],
        .rbx = gregs[si.REG_RBX],
        .rcx = gregs[si.REG_RCX],
        .rdx = gregs[si.REG_RDX],
        .rsi = gregs[si.REG_RSI],
        .rdi = gregs[si.REG_RDI],
        .rbp = gregs[si.REG_RBP],
        .r8 = gregs[si.REG_R8],
        .r9 = gregs[si.REG_R9],
        .r10 = gregs[si.REG_R10],
        .r11 = rflags, // r11 gets rflags for sysretq
        .r12 = gregs[si.REG_R12],
        .r13 = gregs[si.REG_R13],
        .r14 = gregs[si.REG_R14],
        .r15 = gregs[si.REG_R15],
    };
}

/// Copy a signal frame out of user memory. Returns null when `addr` is not a
/// fully mapped user range.
fn readSignalFrame(addr: u64) ?sig_mod.SignalFrame {
    const size = @sizeOf(sig_mod.SignalFrame);
    if (addr == 0 or addr >= 0x0000_8000_0000_0000) return null;
    var frame: sig_mod.SignalFrame = undefined;
    const dst: [*]u8 = @ptrCast(&frame);
    const copy_mod = @import("../mm/copy_from_user.zig");
    if (copy_mod.copyFromUser(dst[0..size], @ptrFromInt(addr), size) != size) return null;
    return frame;
}

/// sigaltstack(ss_ptr, old_ss_ptr) → 0 or -errno
///
/// stack_t: ss_sp@0 (u64), ss_flags@8 (i32), ss_size@16 (u64). Validation
/// and the on-stack/EPERM rule live in sigaltstack_policy.zig; delivery to
/// the stack for SA_ONSTACK handlers is in signal.pushSignalFrame.
pub fn sigaltstack(ss_ptr: u64, old_ss_ptr: u64) i64 {
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;
    const alt_policy = @import("sigaltstack_policy.zig");
    const user_rsp = syscall_entry.getPerCpu().saved_user_rsp;
    const current: alt_policy.AltStack = .{ .base = cur.sigaltstack_base, .size = cur.sigaltstack_size };

    if (old_ss_ptr != 0 and !copy.validateUserBufferWritable(old_ss_ptr, 24)) return -14;
    if (ss_ptr != 0 and !copy.validateUserBuffer(ss_ptr, 24)) return -14;

    var next: ?alt_policy.AltStack = null;
    if (ss_ptr != 0) {
        var ss_buf: [24]u8 = undefined;
        if (copy.copyFromUser(ss_buf[0..], @ptrFromInt(ss_ptr), 24) != 24) return -14;
        switch (alt_policy.set(user_rsp, current, bo.readU64Le(ss_buf[0..8]), bo.readU32Le(ss_buf[8..12]), bo.readU64Le(ss_buf[16..24]))) {
            .ok => |a| next = a,
            .err => |e| return e,
        }
    }
    if (old_ss_ptr != 0) {
        var old_ss: [24]u8 = undefined;
        @memset(&old_ss, 0);
        bo.writeU64Le(old_ss[0..8], current.base);
        bo.writeU32Le(old_ss[8..12], alt_policy.currentFlags(user_rsp, current));
        bo.writeU64Le(old_ss[16..24], current.size);
        if (copy.copyToUser(@ptrFromInt(old_ss_ptr), &old_ss, 24) != 24) return -14;
    }
    if (next) |a| {
        cur.sigaltstack_base = a.base;
        cur.sigaltstack_size = a.size;
    }
    return 0;
}

/// rt_sigpending(set_ptr, sigsetsize) → 0 or -errno
pub fn rtSigpending(set_ptr: u64, sigsetsize: u64) i64 {
    _ = sigsetsize;
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (set_ptr != 0) {
        const pending: u64 = @atomicLoad(u64, &cur.pending_signals, .seq_cst);
        const bytes: [*]const u8 = @ptrCast(&pending);
        if (copy.copyToUser(@ptrFromInt(set_ptr), bytes[0..8], 8) != 8) return -14;
    } else {
        return -14;
    }
    return 0;
}

/// rt_sigsuspend(mask_ptr, sigsetsize) → -errno (always EINTR in simplified impl)
pub fn rtSigsuspend(mask_ptr: u64, sigsetsize: u64) i64 {
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (mask_ptr == 0 or mask_ptr >= 0x0000_8000_0000_0000) return -14;

    // Accept the 8-byte rt_* sigset_t when advertised; legacy callers pass
    // sigsetsize == 4. The task mask is u64 — unread bytes default to 0.
    const width: usize = @intCast(@min(sigsetsize, @as(u64, 8)));
    var new_mask: u64 = 0;
    const mask_bytes: [*]u8 = @ptrCast(&new_mask);
    if (copy.copyFromUser(mask_bytes[0..width], @ptrFromInt(mask_ptr), width) != width) return -14;

    // POSIX: atomically install the temporary mask and sleep until a signal
    // that is deliverable under it arrives; always return EINTR, and restore
    // the original mask only AFTER the handler has run (deferred restore,
    // same mechanism as epoll_pwait — the handler frame saves saved_sigmask).
    // It used to return EINTR at once and leave the temporary mask in place.
    const saved = cur.signal_mask;
    cur.signal_mask = action_policy.sanitizeMask(new_mask);
    while (!sig_mod.pendingActionable(cur) and sig_mod.pendingFatal(cur) == null) {
        task_mod.blockTask(cur_idx);
        // sendSignal → kickIfBlocked unblocks us once the signal is pending
        // and actionable under the current (temporary) mask. Re-check after
        // blocking so a signal raced in before the block is not lost.
        if (sig_mod.pendingActionable(cur) or sig_mod.pendingFatal(cur) != null) {
            task_mod.unblockTask(cur_idx);
            break;
        }
        sched.forceReschedule();
        sched.repairCurrentAfterBlock();
    }
    if (sig_mod.pendingFatal(cur)) |sig| task_mod.exitTask(128 + @as(i32, @intCast(sig)));
    cur.saved_sigmask = saved;
    cur.restore_sigmask_pending = true;
    return -4; // EINTR
}

/// rt_sigtimedwait(sigset_ptr, info_ptr, timeout_ptr, sigset_size) → signal number or -errno
pub fn rtSigtimedwait(sigset_ptr: u64, info_ptr: u64, timeout_ptr: u64, sigset_size: u64) i64 {
    const si = @import("siginfo_policy.zig");
    if (info_ptr != 0 and !copy.validateUserBufferWritable(info_ptr, si.SIGINFO_SIZE)) return -14;

    if (sigset_size == 0 or sigset_ptr == 0 or sigset_ptr >= 0x0000_8000_0000_0000) return -22;

    var mask_buf: [8]u8 = @splat(0);
    const width: usize = @intCast(@min(sigset_size, @as(u64, 8)));
    const copied = copy.copyFromUser(mask_buf[0..width], @ptrFromInt(sigset_ptr), width);
    if (copied == 0) return -14;
    const mask: u64 = @bitCast(mask_buf);

    const cur_idx = sched.currentTaskIndex() orelse return -3;
    const cur = task_mod.getTask(cur_idx) orelse return -3;

    // Atomic load + Rmw like dequeueSignal: a plain read-modify-write races
    // with sendSignal's atomic Rmw on another CPU and can lose a signal bit.
    // Optional relative timeout: null pointer = wait forever; {0,0} = poll.
    var deadline: ?u64 = null;
    const tsc = @import("../arch/arch.zig").tsc;
    if (timeout_ptr != 0) {
        var ts: [16]u8 = undefined;
        if (copy.copyFromUser(&ts, @ptrFromInt(timeout_ptr), 16) != 16) return -14;
        const sec: i64 = @bitCast(ts[0..8].*);
        const nsec: i64 = @bitCast(ts[8..16].*);
        if (sec < 0 or nsec < 0 or nsec >= 1_000_000_000) return -22;
        const total = @as(u64, @intCast(sec)) *| 1_000_000_000 +| @as(u64, @intCast(nsec));
        deadline = tsc.nanos() +| total;
    }

    while (true) {
        // Atomic load + Rmw like dequeueSignal: a plain read-modify-write
        // races with sendSignal's atomic Rmw on another CPU.
        const pending = @atomicLoad(u64, &cur.pending_signals, .seq_cst) & mask;
        if (pending != 0) {
            const bit: u6 = @intCast(@ctz(pending));
            _ = @atomicRmw(u64, &cur.pending_signals, .And, ~(@as(u64, 1) << bit), .seq_cst);
            const taken = cur.sig_info[bit];
            cur.sig_info[bit] = .{};
            if (info_ptr != 0) {
                const raw = si.encode(@as(u32, bit) + 1, taken);
                if (copy.copyToUser(@ptrFromInt(info_ptr), &raw, raw.len) != raw.len) return -14;
            }
            return @as(i64, bit) + 1;
        }
        // A signal outside the wait set that would run a handler ends the
        // wait with EINTR; a fatal one kills the task.
        if (sig_mod.pendingFatal(cur)) |sig| task_mod.exitTask(128 + @as(i32, @intCast(sig)));
        if (sig_mod.pendingActionable(cur)) return -4; // EINTR
        if (deadline) |d| {
            if (tsc.nanos() >= d) return -11; // EAGAIN: timed out
        }
        // Sleep until the next tick (timed wait) or a signal kick. The waited
        // signals are normally blocked by the caller, so kickIfBlocked does not
        // wake us for them: yield one tick at a time and re-check. Coarse but
        // bounded (tick = 10 ms) and lost-wakeup free by construction.
        sched.forceReschedule();
    }
}

/// rt_sigqueueinfo(tgid, sig, uinfo_ptr) → 0 or -errno
pub fn rtSigqueueinfo(tgid: u32, sig: u32, uinfo_ptr: u64) i64 {
    const si = @import("siginfo_policy.zig");
    if (sig > 64) return -22;
    var raw: [si.SIGINFO_SIZE]u8 = undefined;
    if (copy.copyFromUser(&raw, @ptrFromInt(uinfo_ptr), raw.len) != raw.len) return -14;
    const info = si.decode(&raw);
    const cur = sched.currentTask();
    const to_self = if (cur) |c| threadGroupId(c) == tgid else true;
    if (!si.queueinfoAllowed(info.code, to_self)) return -1; // EPERM
    _ = task_mod.findTaskByTid(tgid) orelse return -3; // ESRCH
    if (!currentMaySignalTask(tgid)) return -1; // EPERM
    if (sig == 0) return 0;
    if (sig_mod.sendSignalInfo(tgid, sig, info)) return 0;
    return -3; // ESRCH
}

/// tkill(tid, sig) → 0 or -errno
pub fn tkill(tid_arg: i64, sig: u32) i64 {
    const id_policy = @import("proc_id_policy.zig");
    if (sig > 64) return -22;
    const tid = id_policy.tkillTargetTid(tid_arg) orelse return -22;
    _ = task_mod.findTaskByTid(tid) orelse return -3; // ESRCH
    if (!currentMaySignalTask(tid)) return -1; // EPERM
    if (sig == 0) return 0; // existence and permission probe
    var info = sig_mod.senderInfo();
    if (info.code == @import("siginfo_policy.zig").SI_USER) info.code = @import("siginfo_policy.zig").SI_TKILL;
    if (sig_mod.sendSignalInfo(tid, sig, info)) return 0;
    return -3; // ESRCH
}

/// pidfd_send_signal(pidfd, sig, info_ptr, flags) → 0 or -errno
pub fn pidfdSendSignal(pidfd: u32, sig: u32, info_ptr: u64, flags: u32) i64 {
    _ = info_ptr;
    _ = flags;

    const cur_idx = sched.currentTaskIndex() orelse return -3;
    const cur = task_mod.getTask(cur_idx) orelse return -3;

    if (pidfd >= vfs_mod.MAX_FDS) return -9;
    const desc = cur.fd_table.fds[pidfd];
    if (desc.fd_type != .proc_file) return -9;

    const target_pid: u32 = @intCast(desc.proc_pid);
    if (!currentMaySignalTask(target_pid)) return -1; // EPERM
    if (sig_mod.sendSignal(target_pid, sig)) return 0;
    return -3;
}

/// signalfd4(old_fd, mask, sizemask, flags) → fd or -errno
pub fn signalfd4(old_fd: u64, mask: u64, sizemask: u64, flags: u64) i64 {
    _ = mask;
    _ = sizemask;
    _ = flags;

    // If old_fd is valid, just return it
    if (old_fd != @as(u64, @bitCast(@as(i64, -1))) and old_fd < 0x0000_8000_0000_0000) {
        const cur_idx = sched.currentTaskIndex() orelse return -3;
        const cur = task_mod.getTask(cur_idx) orelse return -3;
        if (old_fd < vfs_mod.MAX_FDS) {
            const fd: u32 = @intCast(old_fd);
            if (cur.fd_table.fds[fd].fd_type == .eventfd) return @bitCast(old_fd);
        }
    }

    // Create a new eventfd-backed signalfd
    const eventfd_mod = @import("../fs/eventfd.zig");
    const efd_idx = eventfd_mod.eventfdCreate(0, false);
    if (efd_idx < 0) return @as(i64, efd_idx);
    const eventfd_idx: u32 = @intCast(efd_idx);
    var installed = false;
    defer if (!installed) eventfd_mod.eventfdClose(eventfd_idx);

    const cur_idx = sched.currentTaskIndex() orelse return -3;
    const cur = task_mod.getTask(cur_idx) orelse return -3;

    const slot = cur.fd_table.allocFd() orelse return -24;
    cur.fd_table.fds[slot] = .{ .fd_type = .eventfd, .eventfd_idx = eventfd_idx };
    cur.fd_table.publishFd(slot);
    installed = true;
    return @bitCast(@as(u64, slot));
}

/// rt_tgsigqueueinfo(tgid, tid, sig, uinfo) → 0 or -errno
pub fn rtTgsigqueueinfo(tgid: u32, tid: u32, sig: u32, uinfo: u64) i64 {
    _ = tid;
    return rtSigqueueinfo(tgid, sig, uinfo);
}
