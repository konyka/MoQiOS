/// Signal handling — POSIX-like signals for MoQiOS.
///
/// Supported signals: 1 (SIGHUP) through 31 (SIGUSR2).
/// Signal delivery happens at two points:
///   1. Syscall return path (sysretq) — check before restoring to user mode
///   2. Timer tick return path (iretq) — check in scheduler before switching
///
/// Delivery mechanism: push a signal frame onto the user stack containing
/// the saved register state, then modify the return RIP to point to the
/// user's signal handler. The sigreturn syscall restores the original context.
const task = @import("task.zig");

pub const SIGKILL: u32 = 9;
pub const SIGPIPE: u32 = 13;
pub const SIGTERM: u32 = 15;
pub const SIGUSR1: u32 = 10;
pub const SIGUSR2: u32 = 31;
pub const SIGCHLD: u32 = 17;
pub const SIGINT: u32 = 2;
pub const SIGSEGV: u32 = 11;
pub const SIGHUP: u32 = 1;
pub const SIGCONT: u32 = 18;
pub const SIGSTOP: u32 = 19;
pub const SIGTTIN: u32 = 21;
pub const SIGTTOU: u32 = 22;

/// Default disposition of a signal when no handler is installed.
pub const SigDefault = enum { terminate, ignore, stop, cont };

/// POSIX default actions. SIGCHLD is ignored, SIGSTOP/SIGTTIN/SIGTTOU stop
/// the process, SIGCONT continues it, everything else terminates.
pub fn defaultAction(signum: u32) SigDefault {
    return switch (signum) {
        SIGCHLD => .ignore,
        SIGCONT => .cont,
        SIGSTOP, SIGTTIN, SIGTTOU => .stop,
        else => .terminate,
    };
}

/// Signal frame pushed onto user stack before calling signal handler.
/// The handler receives (signum) as the only argument (in RDI).
/// After the handler returns, it calls the sigreturn trampoline
/// which restores this frame.
pub const SignalFrame = extern struct {
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
    rip: u64,
    rflags: u64,
    rsp: u64,
    signum: u64,
};

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
/// If the target is blocked in a wait primitive, wake and kick it so it can
/// observe the signal on resume: the wait loops re-check pending_signals after
/// a non-grant wake and either return -EINTR (handled signal) or terminate
/// (fatal default action). Previously a task blocked in e.g. semop or
/// epoll_wait never noticed SIGKILL — unkillable tasks.
pub fn sendSignal(target_tid: u32, signum: u32) bool {
    if (signum == 0 or signum > 31) return false;

    for (0..task.MAX_TASKS) |i| {
        const t = task.getTask(@intCast(i)) orelse continue;
        if (t.tid == target_tid and t.state != .zombie) {
            // POSIX: SIGCONT 立即继续（阻塞/忽略亦生效），pending 位照置以便
            // handler 在恢复后投递；致命信号必须先解除停止态否则杀不死。
            if (signum == SIGCONT) continueTask(t);
            if (defaultAction(signum) == .terminate and t.stopped) t.stopped = false;
            _ = @atomicRmw(u32, &t.pending_signals, .Or, @as(u32, 1) << @intCast(signum - 1), .seq_cst);
            kickIfBlocked(@intCast(i));
            return true;
        }
    }
    return false;
}

/// Wake a blocked task so it can observe a newly pending signal on resume.
/// unblockTask re-enqueues it, kickRemoteForTask IPIs the CPU it last ran on.
pub fn kickIfBlocked(idx: u32) void {
    const t = task.getTask(idx) orelse return;
    if (t.state == .blocked) {
        task.unblockTask(idx);
        task.kickRemoteForTask(idx);
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
    const idx = t.self_idx;
    task.unblockTask(idx);
    task.kickRemoteForTask(idx);
}

/// Broadcast a signal to every task in a process group (kill(-pgid) and the
/// job-control stops). Stop/continue signals act immediately per default
/// disposition; everything else goes through the normal pending-signal path.
/// Returns the number of tasks signalled.
pub fn sendSignalToPgrp(pgid: u16, signum: u32) u32 {
    if (signum == 0 or signum > 31) return 0;
    const action = defaultAction(signum);
    var sent: u32 = 0;
    for (0..task.MAX_TASKS) |i| {
        const t = task.getTask(@intCast(i)) orelse continue;
        if (t.pgid != pgid or t.state == .zombie) continue;
        sent += 1;
        switch (action) {
            .stop => {
                const h = t.signal_handlers[signum - 1];
                if (signum != SIGSTOP and h == 1) {
                    // SIG_IGN：忽略该成员。
                } else if (signum != SIGSTOP and h != 0) {
                    // 已装 handler：走普通 pending 投递（handler 运行，读得 EINTR）。
                    _ = @atomicRmw(u32, &t.pending_signals, .Or, @as(u32, 1) << @intCast(signum - 1), .seq_cst);
                    kickIfBlocked(@intCast(i));
                } else {
                    stopTask(t);
                }
            },
            .cont => continueTask(t),
            else => {
                _ = @atomicRmw(u32, &t.pending_signals, .Or, @as(u32, 1) << @intCast(signum - 1), .seq_cst);
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
    if (signum == 0 or signum > 31) return;
    const sched = @import("sched.zig");
    const t = sched.currentTask() orelse return;
    _ = @atomicRmw(u32, &t.pending_signals, .Or, @as(u32, 1) << @intCast(signum - 1), .seq_cst);
}

/// Lowest pending, unblocked signal that has no user handler installed and
/// whose default action terminates the process, or null. Blocking wait
/// primitives check this after a non-grant wake: on a hit the caller routes
/// through task.exitTask(128 + signum), the same exit-by-signal path the
/// scheduler tick uses (sched.deliverSignalToRunningTask).
pub fn pendingFatal(t: *task.Task) ?u32 {
    const pending = (@atomicLoad(u32, &t.pending_signals, .seq_cst) & ~@as(u32, @truncate(t.signal_mask))) & 0x7FFFFFFF;
    var bits = pending;
    while (bits != 0) {
        const bit: u5 = @intCast(@ctz(bits));
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
    return (@atomicLoad(u32, &t.pending_signals, .seq_cst) & ~@as(u32, @truncate(t.signal_mask)) & 0x7FFFFFFF) != 0;
}

/// True if a pending, unblocked signal would actually be acted on: a handler
/// is installed for it, or its default action terminates the process.
/// Default-ignored signals (SIGCHLD) do NOT interrupt blocking syscalls —
/// observed as waitpid returning spurious -EINTR after an earlier child's
/// SIGCHLD landed while waiting for a second child.
pub fn pendingActionable(t: *task.Task) bool {
    const pending = (@atomicLoad(u32, &t.pending_signals, .seq_cst) & ~@as(u32, @truncate(t.signal_mask))) & 0x7FFFFFFF;
    var bits = pending;
    while (bits != 0) {
        const bit: u5 = @intCast(@ctz(bits));
        bits &= bits - 1;
        if (t.signal_handlers[bit] != 0 or !defaultSignalAction(@as(u32, bit) + 1)) return true;
    }
    return false;
}

/// Check if a task has any pending, non-blocked signals.
/// Returns the lowest signal number, or null if none.
/// v53.44: O(1) with @ctz instead of O(31) linear scan.
pub fn dequeueSignal(t: *task.Task) ?u32 {
    // v53.45: Mask bit 31 — signals 1-31 only, @ctz returning 31 would
    // index signal_handlers[31] which is out of bounds (array has 31 slots, 0-30).
    const pending = (@atomicLoad(u32, &t.pending_signals, .seq_cst) & ~@as(u32, @truncate(t.signal_mask))) & 0x7FFFFFFF;
    if (pending == 0) return null;

    const bit: u5 = @intCast(@ctz(pending));
    _ = @atomicRmw(u32, &t.pending_signals, .And, ~(@as(u32, 1) << bit), .seq_cst);
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
/// Returns the new user RSP (handler entry RSP) and the handler address.
///
/// User stack layout after delivery:
///   [higher address]
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
) struct { new_rsp: u64, handler: u64 } {
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
    // at entry, and the frame (handler_rsp+8 .. +8+sizeof) must not overrun
    // the pre-signal user RSP.

    const total_size: u64 = @sizeOf(SignalFrame) + 8;

    var handler_rsp = (user_rsp - total_size) & ~@as(u64, 15);
    handler_rsp += 8;
    if (handler_rsp + total_size > user_rsp) {
        handler_rsp -= 16;
    }

    const frame_addr = handler_rsp + 8;

    // v53.44: Build frame on kernel stack, then copyToUser for safe write.
    // Prevents kernel page fault if user stack is near limit or unmapped.
    var frame: SignalFrame = undefined;
    const fb: [*]u8 = @ptrCast(&frame);
    @memset(fb[0..@sizeOf(SignalFrame)], 0);
    // Full interrupted GPR set — sigreturn restores these verbatim.
    frame.rax = gprs.rax;
    frame.rbx = gprs.rbx;
    frame.rcx = gprs.rcx;
    frame.rdx = gprs.rdx;
    frame.rsi = gprs.rsi;
    frame.rdi = gprs.rdi;
    frame.rbp = gprs.rbp;
    frame.r8 = gprs.r8;
    frame.r9 = gprs.r9;
    frame.r10 = gprs.r10;
    frame.r11 = gprs.r11;
    frame.r12 = gprs.r12;
    frame.r13 = gprs.r13;
    frame.r14 = gprs.r14;
    frame.r15 = gprs.r15;
    frame.rip = user_rip;
    frame.rflags = user_rflags;
    frame.rsp = user_rsp;
    frame.signum = signum;

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

    return .{ .new_rsp = handler_rsp, .handler = handler_addr };
}

/// Restore context from a signal frame on sigreturn.
/// The user RSP points to the SignalFrame. We read it and return
/// the saved RIP, RSP, RFLAGS so the syscall return path can use them.
/// `frame_addr` is user-controlled, so it is copied in rather than dereferenced;
/// null means the range is not fully mapped user memory.
pub fn popSignalFrame(frame_addr: u64) ?struct { rip: u64, rsp: u64, rflags: u64, rax: u64 } {
    if (frame_addr == 0 or frame_addr >= 0x0000_8000_0000_0000) return null;
    var frame: SignalFrame = undefined;
    const dst: [*]u8 = @ptrCast(&frame);
    const copy = @import("../mm/copy_from_user.zig");
    if (copy.copyFromUser(dst[0..@sizeOf(SignalFrame)], @ptrFromInt(frame_addr), @sizeOf(SignalFrame)) != @sizeOf(SignalFrame)) return null;
    return .{
        .rip = frame.rip,
        .rsp = frame.rsp,
        .rflags = frame.rflags,
        .rax = frame.rax,
    };
}
