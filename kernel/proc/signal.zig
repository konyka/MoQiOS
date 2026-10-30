/// Signal handling — POSIX-like signals for MoQiOS.
///
/// Supported signals: 1 (SIGHUP) through 64 (SIGRTMAX); 32..64 are the
/// real-time signals (default action: terminate).
/// Signal delivery happens at two points:
///   1. Syscall return path (sysretq) — check before restoring to user mode
///   2. Timer tick return path (iretq) — check in scheduler before switching
///
/// Delivery mechanism: push a signal frame onto the user stack containing
/// the saved register state, then modify the return RIP to point to the
/// user's signal handler. The sigreturn syscall restores the original context.
const task = @import("task.zig");
const siginfo = @import("siginfo_policy.zig");

/// Highest signal number (SIGRTMAX); the first real-time signal is 32.
pub const MAX_SIGNAL: u32 = 64;

pub const SIGKILL: u32 = 9;
pub const SIGPIPE: u32 = 13;
pub const SIGTERM: u32 = 15;
pub const SIGUSR1: u32 = 10;
pub const SIGUSR2: u32 = 31;
pub const SIGCHLD: u32 = 17;
pub const SIGINT: u32 = 2;
pub const SIGSEGV: u32 = 11;
pub const SIGBUS: u32 = 7;
pub const SIGHUP: u32 = 1;
pub const SIGCONT: u32 = 18;
pub const SIGSTOP: u32 = 19;
pub const SIGTTIN: u32 = 21;
pub const SIGTTOU: u32 = 22;
pub const SIGXFSZ: u32 = 25;
pub const SIGTSTP: u32 = 20;
pub const SIGURG: u32 = 23;
pub const SIGWINCH: u32 = 28;

/// Default disposition of a signal when no handler is installed.
pub const SigDefault = enum { terminate, ignore, stop, cont };

/// POSIX default actions. SIGCHLD/SIGURG/SIGWINCH are ignored,
/// SIGSTOP/SIGTSTP/SIGTTIN/SIGTTOU stop the process, SIGCONT continues it,
/// everything else terminates. (SIGTSTP used to terminate, so `kill -TSTP`
/// killed a process instead of suspending it.)
pub fn defaultAction(signum: u32) SigDefault {
    return switch (signum) {
        SIGCHLD, SIGURG, SIGWINCH => .ignore,
        SIGCONT => .cont,
        SIGSTOP, SIGTSTP, SIGTTIN, SIGTTOU => .stop,
        else => .terminate,
    };
}

/// Signal frame pushed onto user stack before calling signal handler.
/// The handler receives (signum) as the only argument (in RDI).
/// After the handler returns, it calls the sigreturn trampoline
/// which restores this frame.
pub const SignalFrame = extern struct {
    signum: u64,
    /// FXSAVE image of the interrupted x87/SSE state (512 bytes, 16-aligned
    /// within the frame). The handler shares the task's FPU, so without this
    /// any SSE use in the handler corrupted the interrupted code's xmm
    /// registers and MXCSR.
    fpu: [512]u8 align(16),
    /// siginfo_t handed to SA_SIGINFO handlers (rsi).
    info: [siginfo.SIGINFO_SIZE]u8,
    /// ucontext_t handed to SA_SIGINFO handlers (rdx). Its gregs and sigmask
    /// are what sigreturn restores, so a handler may edit them (rip, rsp,
    /// registers, the mask to resume with).
    uc: siginfo.UContext,
};

comptime {
    // fxsave/fxrstor need a 16-byte-aligned operand: the frame is placed at
    // handler_rsp + 8 with handler_rsp ≡ 8 (mod 16), i.e. frame ≡ 0 (mod 16).
    if (@offsetOf(SignalFrame, "fpu") % 16 != 0) @compileError("SignalFrame.fpu must be 16-aligned");
}

/// Sigreturn trampoline code — copied to user memory at a fixed address.
/// The SignalFrame sits ABOVE the handler's entry RSP (the handler only ever
/// writes BELOW its RSP), so after the handler's RET the RSP points exactly
/// at the SignalFrame — no adjustment needed. (The old layout placed the
/// frame below the entry RSP, where the handler's own stack frames clobbered
/// it — sigreturn then restored a corrupted rsp/rip, observed as hello13's
/// waitpid receiving a stack address as pid.)
///   movq $15, %rax            ; sigreturn syscall number
///   syscall
pub const SIGRETURN_TRAMPOLINE: [9]u8 = .{
    0x48, 0xc7, 0xc0, 0x0f, 0x00, 0x00, 0x00, // movq $15, %rax
    0x0f, 0x05, // syscall
};

/// Fixed address where the sigreturn trampoline is mapped in user space.
pub const SIGRETURN_TRAMPOLINE_ADDR: u64 = 0x7FFFF0000000;

var sigreturn_trampoline_phys: u64 = 0;

/// Send a signal to a process. Returns true on success.
/// v53.44: Uses atomic OR for SMP-safe signal bit setting.
/// If the target is blocked in a wait primitive and the pending signal is
/// actionable under its current mask, wake and kick it so it can observe the
/// signal on resume. Masked or ignored signals remain pending without waking
/// the wait.
pub fn sendSignal(target_tid: u32, signum: u32) bool {
    return sendSignalInfo(target_tid, signum, senderInfo());
}

fn tgidOf(t: *task.Task) u32 {
    return if (t.is_thread and t.parent_tid != 0) t.parent_tid else t.tid;
}

/// siginfo for a signal sent by the running task (kill): SI_USER with its
/// pid and uid; SI_KERNEL when no user task is current.
pub fn senderInfo() siginfo.Info {
    const sched = @import("sched.zig");
    const cur = sched.currentTask() orelse return .{ .code = siginfo.SI_KERNEL };
    if (!cur.is_user) return .{ .code = siginfo.SI_KERNEL };
    return .{ .code = siginfo.SI_USER, .a = siginfo.pidUid(tgidOf(cur), cur.uid) };
}

/// sendSignal with an explicit siginfo (tkill, rt_sigqueueinfo, SIGCHLD,
/// faults). The info is recorded before the pending bit is set so the
/// delivery that consumes the bit sees it.
pub fn sendSignalInfo(target_tid: u32, signum: u32, info: siginfo.Info) bool {
    if (signum == 0 or signum > MAX_SIGNAL) return false;

    for (0..task.MAX_TASKS) |i| {
        const t = task.getTask(@intCast(i)) orelse continue;
        if (t.tid == target_tid and t.state != .zombie) {
            // POSIX: SIGCONT 立即继续（阻塞/忽略亦生效），pending 位照置以便
            // handler 在恢复后投递；致命信号必须先解除停止态否则杀不死。
            if (signum == SIGCONT) continueTask(t);
            if (defaultAction(signum) == .terminate and t.stopped) t.stopped = false;
            t.sig_info[signum - 1] = info;
            _ = @atomicRmw(u64, &t.pending_signals, .Or, @as(u64, 1) << @intCast(signum - 1), .seq_cst);
            kickIfBlocked(@intCast(i));
            return true;
        }
    }
    return false;
}

/// Wake a blocked task so it can observe an actionable pending signal on
/// resume. unblockTask re-enqueues it and preempts / IPIs its CPU as needed.
pub fn kickIfBlocked(idx: u32) void {
    const t = task.getTask(idx) orelse return;
    // Keep blocked waits asleep for signals masked by the current wait mask.
    // The pending bit remains set and can wake the task after the mask changes.
    if (t.state == .blocked and pendingActionable(t)) {
        task.unblockTask(idx);
    }
}

/// Job control: stop a task (SIGSTOP/SIGTTIN/SIGTTOU default). Running/ready
/// tasks transition to .blocked and stay there until SIGCONT — wait-queue
/// wakes are suppressed while `stopped` holds (see continueTask).
pub fn stopTask(t: *task.Task) void {
    if (t.stopped) return;
    t.stopped = true;
    const sc = @import("sched_claim.zig");
    const s = sc.load(&t.state);
    if (s == .running or s == .ready) sc.store(&t.state, .blocked);
}

/// Job control: continue a stopped task (SIGCONT — effective even when the
/// signal is blocked or ignored, per POSIX).
pub fn continueTask(t: *task.Task) void {
    if (!t.stopped) return;
    t.stopped = false;
    task.unblockTask(t.self_idx);
}

/// Broadcast a signal to every task in a process group (kill(-pgid) and the
/// job-control stops). Stop/continue signals act immediately per default
/// disposition; everything else goes through the normal pending-signal path.
/// Returns the number of tasks signalled.
pub fn sendSignalToPgrp(pgid: u16, signum: u32) u32 {
    return sendSignalToPgrpFiltered(pgid, signum, null);
}

/// Group broadcast; with a `sender`, members the sender may not signal
/// (POSIX kill permission) are skipped.
pub fn sendSignalToPgrpFiltered(pgid: u16, signum: u32, sender: ?*task.Task) u32 {
    if (signum == 0 or signum > MAX_SIGNAL) return 0;
    const action = defaultAction(signum);
    const info: siginfo.Info = if (sender != null) senderInfo() else .{ .code = siginfo.SI_KERNEL };
    var sent: u32 = 0;
    for (0..task.MAX_TASKS) |i| {
        const t = task.getTask(@intCast(i)) orelse continue;
        if (t.pgid != pgid or t.state == .zombie) continue;
        if (sender) |snd| {
            if (!@import("signal_syscall.zig").maySignal(snd, t)) continue;
        }
        sent += 1;
        t.sig_info[signum - 1] = info;
        switch (action) {
            .stop => {
                const h = t.signal_handlers[signum - 1];
                if (signum != SIGSTOP and h == 1) {
                    // SIG_IGN：忽略该成员。
                } else if (signum != SIGSTOP and h != 0) {
                    // 已装 handler：走普通 pending 投递（handler 运行，读得 EINTR）。
                    _ = @atomicRmw(u64, &t.pending_signals, .Or, @as(u64, 1) << @intCast(signum - 1), .seq_cst);
                    kickIfBlocked(@intCast(i));
                } else {
                    stopTask(t);
                }
            },
            .cont => {
                // Continue, and queue the bit like the single-target path so
                // an installed SIGCONT handler actually runs.
                continueTask(t);
                _ = @atomicRmw(u64, &t.pending_signals, .Or, @as(u64, 1) << @intCast(signum - 1), .seq_cst);
                kickIfBlocked(@intCast(i));
            },
            else => {
                _ = @atomicRmw(u64, &t.pending_signals, .Or, @as(u64, 1) << @intCast(signum - 1), .seq_cst);
                // 致命信号必须能终止已停止的任务：先解除停止态再唤醒。
                if (defaultAction(signum) == .terminate and t.stopped) t.stopped = false;
                kickIfBlocked(@intCast(i));
            },
        }
    }
    return sent;
}

/// Raise a signal on the current task itself (e.g. SIGPIPE from pipeWrite).
/// Delivery happens on the usual syscall-return / timer-tick paths.
pub fn raiseSelf(signum: u32) void {
    if (signum == 0 or signum > MAX_SIGNAL) return;
    const sched = @import("sched.zig");
    const t = sched.currentTask() orelse return;
    _ = @atomicRmw(u64, &t.pending_signals, .Or, @as(u64, 1) << @intCast(signum - 1), .seq_cst);
}

/// Lowest pending, unblocked signal that has no user handler installed and
/// whose default action terminates the process, or null. Blocking wait
/// primitives check this after a non-grant wake: on a hit the caller routes
/// through task.exitTask(128 + signum), the same exit-by-signal path the
/// scheduler tick uses (sched.deliverSignalToRunningTask).
pub fn pendingFatal(t: *task.Task) ?u32 {
    const pending = @atomicLoad(u64, &t.pending_signals, .seq_cst) & ~t.signal_mask;
    var bits = pending;
    while (bits != 0) {
        const bit: u6 = @intCast(@ctz(bits));
        bits &= bits - 1;
        const signum = @as(u32, bit) + 1;
        if (t.signal_handlers[bit] == 0 and !defaultSignalAction(signum)) return signum;
    }
    return null;
}

/// True if the task has any pending, unblocked signal (handled or not).
/// Wait primitives return -EINTR on a hit so the syscall-return/tick path
/// can run the handler.
///
/// NOTE: raw pending check — includes default-ignored signals (SIGCHLD).
/// For EINTR decisions use `pendingActionable` instead: Linux only
/// interrupts a blocking syscall when a signal is actually delivered
/// (handler installed) or terminates the process.
pub fn pendingAny(t: *task.Task) bool {
    return (@atomicLoad(u64, &t.pending_signals, .seq_cst) & ~t.signal_mask) != 0;
}

/// True if a pending, unblocked signal would actually be acted on: a handler
/// is installed for it, or its default action terminates the process.
/// Default-ignored signals (SIGCHLD) do NOT interrupt blocking syscalls —
/// observed as waitpid returning spurious -EINTR after an earlier child's
/// SIGCHLD landed while waiting for a second child.
pub fn pendingActionable(t: *task.Task) bool {
    const pending = @atomicLoad(u64, &t.pending_signals, .seq_cst) & ~t.signal_mask;
    var bits = pending;
    while (bits != 0) {
        const bit: u6 = @intCast(@ctz(bits));
        bits &= bits - 1;
        if ((t.signal_handlers[bit] != 0 and t.signal_handlers[bit] != 1) or !defaultSignalAction(@as(u32, bit) + 1)) return true;
    }
    return false;
}

/// Check if a task has any pending, non-blocked signals.
/// Returns the lowest signal number, or null if none.
/// v53.44: O(1) with @ctz instead of O(31) linear scan.
pub fn dequeueSignal(t: *task.Task) ?u32 {
    const pending = @atomicLoad(u64, &t.pending_signals, .seq_cst) & ~t.signal_mask;
    if (pending == 0) return null;

    const bit: u6 = @intCast(@ctz(pending));
    _ = @atomicRmw(u64, &t.pending_signals, .And, ~(@as(u64, 1) << bit), .seq_cst);
    return @as(u32, bit) + 1;
}

/// Map the shared sigreturn trampoline into a user address space.
pub fn setupSigreturnTrampoline(user_pml4: u64) void {
    const paging = @import("../arch/arch.zig").paging;
    const pmm = @import("../mm/pmm.zig");
    const hhdm_mod = @import("../mm/hhdm.zig");

    if (@atomicLoad(u64, &sigreturn_trampoline_phys, .acquire) == 0) {
        const new_phys = pmm.allocPage() orelse return;
        const virt = hhdm_mod.physToVirt(new_phys);

        var ptr: [*]u8 = @ptrFromInt(virt);
        @memset(ptr[0..4096], 0);
        @memcpy(ptr[0..SIGRETURN_TRAMPOLINE.len], &SIGRETURN_TRAMPOLINE);
        @atomicStore(u64, &sigreturn_trampoline_phys, new_phys, .release);
    }

    const phys = @atomicLoad(u64, &sigreturn_trampoline_phys, .acquire);
    paging.mapPageNoFlush(user_pml4, SIGRETURN_TRAMPOLINE_ADDR, phys, .{
        .writable = false,
        .user = true,
        .no_execute = false,
        .global = false,
    }) catch {};
}

/// Handle default signal action. Returns true if the signal was handled
/// (i.e., the process should continue). Returns false if the process
/// should be terminated.
pub fn defaultSignalAction(signum: u32) bool {
    return defaultAction(signum) != .terminate;
}

/// General-purpose register snapshot saved into the signal frame so sigreturn
/// can restore the FULL interrupted context (POSIX: sigreturn must leave all
/// callee-saved registers intact). Without this the handler's sigreturn
/// zeroed rbx/rbp/r12-r15/etc. — intermittent user-state corruption whenever
/// the compiler kept anything live in those registers across the interruption
/// (observed as hello13's waitpid receiving a stack address as pid on SMP).
pub const GpRegs = extern struct {
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

/// Deliver a signal to a user-space task by pushing a signal frame.
/// `user_rsp` is the current user RSP (where we'll push the frame).
/// `user_rip` is the current user RIP (where execution would return).
/// `user_rflags` is the current RFLAGS.
/// `gprs` holds the interrupted GPR set to be restored by sigreturn.
/// Returns the new user RSP (handler entry RSP) and the handler address;
/// new_rsp == 0 means the frame could not be written, and the caller must
/// kill the task with SIGSEGV (Linux force_sigsegv) rather than drop it.
///
/// User stack layout after delivery:
///   [higher address]
///   128-byte red zone below the interrupted RSP (left untouched)
///   SignalFrame (saved context)
///   sigreturn_trampoline_addr (8 bytes — handler return address)
///   [lower address] <- RSP when handler is entered
///
/// When the handler returns via RET, it jumps to the sigreturn trampoline.
/// The trampoline does syscall #15 (sigreturn). At that point RSP points
/// to the SignalFrame, which sigreturn reads and restores.
pub fn pushSignalFrame(
    t: *task.Task,
    signum: u32,
    user_rsp: u64,
    user_rip: u64,
    user_rflags: u64,
    gprs: *const GpRegs,
) struct { new_rsp: u64, handler: u64, info_addr: u64 = 0, uc_addr: u64 = 0 } {
    const handler_addr = t.signal_handlers[signum - 1];

    // Layout (stack grows down; the handler only writes BELOW its entry RSP):
    //   [SignalFrame]           at handler_rsp + 8 (above the handler's stack)
    //   [return address]        at handler_rsp
    //   <- handler RSP          = handler_rsp
    //
    // The frame MUST sit above the handler's RSP: placing it below (the old
    // layout) put it in the handler's stack-growth path, so any non-trivial
    // handler clobbered the saved rsp/rip slots and sigreturn resumed with a
    // corrupted stack (observed as hello13's waitpid getting a stack address
    // as pid). The handler's RSP must satisfy the ABI: RSP+8 is 16-aligned
    // at entry, and the frame must stay below the interrupted code's 128-byte
    // red zone (leaf functions keep live locals there without moving RSP).
    // sigreturn restores frame.rsp — the original user_rsp — so the gap is
    // invisible to the interrupted code (signal_frame_policy.zig).
    // SA_ONSTACK handlers run on the sigaltstack unless already on it.
    const alt_policy = @import("sigaltstack_policy.zig");
    const frame_top = alt_policy.deliveryTop(user_rsp, t.signal_sa_flags[signum - 1], .{
        .base = t.sigaltstack_base,
        .size = t.sigaltstack_size,
    });
    const handler_rsp = @import("signal_frame_policy.zig").handlerRsp(frame_top, @sizeOf(SignalFrame)) orelse
        return .{ .new_rsp = 0, .handler = 0 };

    const frame_addr = handler_rsp + 8;

    // v53.44: Build frame on kernel stack, then copyToUser for safe write.
    // Prevents kernel page fault if user stack is near limit or unmapped.
    var frame: SignalFrame = undefined;
    const fb: [*]u8 = @ptrCast(&frame);
    @memset(fb[0..@sizeOf(SignalFrame)], 0);
    frame.signum = signum;
    // The info recorded when the signal was sent; consumed by this delivery.
    const sent = t.sig_info[signum - 1];
    t.sig_info[signum - 1] = .{};
    frame.info = siginfo.encode(signum, sent);
    // A deferred temporary-mask restore (epoll_pwait/pselect EINTR) means
    // the mask to resume with is the pre-call mask, not the temporary one.
    // Full interrupted context in ucontext form — sigreturn restores it
    // verbatim, so a handler may edit it.
    var uc = &frame.uc;
    uc.sigmask = if (t.restore_sigmask_pending) t.saved_sigmask else t.signal_mask;
    uc.ss_sp = t.sigaltstack_base;
    uc.ss_size = t.sigaltstack_size;
    uc.gregs[siginfo.REG_RAX] = gprs.rax;
    uc.gregs[siginfo.REG_RBX] = gprs.rbx;
    uc.gregs[siginfo.REG_RCX] = gprs.rcx;
    uc.gregs[siginfo.REG_RDX] = gprs.rdx;
    uc.gregs[siginfo.REG_RSI] = gprs.rsi;
    uc.gregs[siginfo.REG_RDI] = gprs.rdi;
    uc.gregs[siginfo.REG_RBP] = gprs.rbp;
    uc.gregs[siginfo.REG_R8] = gprs.r8;
    uc.gregs[siginfo.REG_R9] = gprs.r9;
    uc.gregs[siginfo.REG_R10] = gprs.r10;
    uc.gregs[siginfo.REG_R11] = gprs.r11;
    uc.gregs[siginfo.REG_R12] = gprs.r12;
    uc.gregs[siginfo.REG_R13] = gprs.r13;
    uc.gregs[siginfo.REG_R14] = gprs.r14;
    uc.gregs[siginfo.REG_R15] = gprs.r15;
    uc.gregs[siginfo.REG_RIP] = user_rip;
    uc.gregs[siginfo.REG_EFL] = user_rflags;
    uc.gregs[siginfo.REG_RSP] = user_rsp;
    if (signum == SIGSEGV or signum == SIGBUS) uc.gregs[siginfo.REG_CR2] = sent.a;
    if (comptime @import("builtin").cpu.arch == .x86_64) {
        // The task is the current one on this CPU and its FPU state is live
        // in the registers (eager switch-in restore). Snapshot it.
        asm volatile ("fxsave (%[buf])"
            :
            : [buf] "r" (@as([*]u8, @ptrCast(&frame.fpu))),
            : .{ .memory = true });
    }

    if (comptime @import("builtin").cpu.arch == .x86_64) {
        const paging = @import("../arch/arch.zig").paging;
        const idt = @import("../arch/x86_64/idt.zig");
        var page = handler_rsp & ~@as(u64, 0xFFF);
        const end = frame_addr + @sizeOf(SignalFrame);
        while (page < end) : (page += 0x1000) {
            const raw = paging.getPageEntryRaw(t.page_table_phys, page) orelse 0;
            if (raw & 1 == 0 and !idt.prefaultUserPage(page)) break;
        }
    }

    const copy = @import("../mm/copy_from_user.zig");
    const frame_src: [*]const u8 = @ptrCast(&frame);
    if (copy.copyToUser(@ptrFromInt(frame_addr), frame_src[0..@sizeOf(SignalFrame)], @sizeOf(SignalFrame)) != @sizeOf(SignalFrame)) {
        // Stack too small or unmapped — signal delivery fails
        return .{ .new_rsp = 0, .handler = 0 };
    }

    // Write return address (sigreturn trampoline)
    var ret_val: u64 = SIGRETURN_TRAMPOLINE_ADDR;
    const ret_src: [*]const u8 = @ptrCast(&ret_val);
    if (copy.copyToUser(@ptrFromInt(handler_rsp), ret_src[0..8], 8) != 8) {
        return .{ .new_rsp = 0, .handler = 0 };
    }

    // Commit the handler's mask and one-shot reset only once the frame is
    // on the user stack (a failed push leaves the task untouched).
    const dp = @import("signal_delivery_policy.zig");
    const sa_mask = t.signal_sa_masks[signum - 1];
    const sa_flags = t.signal_sa_flags[signum - 1];
    t.signal_mask = dp.handlerMask(t.signal_mask, signum, sa_mask, sa_flags);
    t.restore_sigmask_pending = false; // now carried by uc.sigmask
    t.signal_handlers[signum - 1] = dp.handlerAfterDelivery(handler_addr, sa_flags);

    return .{
        .new_rsp = handler_rsp,
        .handler = handler_addr,
        .info_addr = frame_addr + @offsetOf(SignalFrame, "info"),
        .uc_addr = frame_addr + @offsetOf(SignalFrame, "uc"),
    };
}
