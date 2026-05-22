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
pub const SIGTERM: u32 = 15;
pub const SIGUSR1: u32 = 10;
pub const SIGUSR2: u32 = 31;
pub const SIGCHLD: u32 = 17;
pub const SIGINT: u32 = 2;
pub const SIGSEGV: u32 = 11;

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
/// After the signal handler returns via RET, RSP points 8 bytes past the
/// return address slot. We adjust RSP back to the SignalFrame, then syscall.
///   leaq -160(%rsp), %rsp    ; RSP -> SignalFrame (152 + 8 = 160)
///   movq $15, %rax            ; sigreturn syscall number
///   syscall
pub const SIGRETURN_TRAMPOLINE: [17]u8 = .{
    0x48, 0x8d, 0xa4, 0x24, 0x60, 0xff, 0xff, 0xff, // leaq -160(%rsp), %rsp
    0x48, 0xc7, 0xc0, 0x0f, 0x00, 0x00, 0x00, // movq $15, %rax
    0x0f, 0x05, // syscall
};

/// Fixed address where the sigreturn trampoline is mapped in user space.
pub const SIGRETURN_TRAMPOLINE_ADDR: u64 = 0x7FFFF0000000;

/// Send a signal to a process. Returns true on success.
pub fn sendSignal(target_tid: u32, signum: u32) bool {
    if (signum == 0 or signum > 31) return false;

    for (0..task.MAX_TASKS) |i| {
        const t = task.getTask(@intCast(i)) orelse continue;
        if (t.tid == target_tid and t.state != .zombie) {
            t.pending_signals |= @as(u32, 1) << @intCast(signum - 1);
            return true;
        }
    }
    return false;
}

/// Check if a task has any pending, non-blocked signals.
/// Returns the lowest signal number, or null if none.
pub fn dequeueSignal(t: *task.Task) ?u32 {
    const pending = t.pending_signals & ~t.signal_mask;
    if (pending == 0) return null;

    var signum: u32 = 1;
    while (signum <= 31) : (signum += 1) {
        const mask = @as(u32, 1) << @intCast(signum - 1);
        if (pending & mask != 0) {
            t.pending_signals &= ~mask;
            return signum;
        }
    }
    return null;
}

/// Map the sigreturn trampoline into user address space.
/// Called once during kernel init.
pub fn setupSigreturnTrampoline(user_pml4: u64) void {
    const paging = @import("../arch/x86_64/paging.zig");
    const pmm = @import("../mm/pmm.zig");
    const hhdm_mod = @import("../mm/hhdm.zig");

    const phys = pmm.allocPage() orelse return;
    const virt = hhdm_mod.physToVirt(phys);

    var ptr: [*]u8 = @ptrFromInt(virt);
    @memset(ptr[0..4096], 0);
    @memcpy(ptr[0..SIGRETURN_TRAMPOLINE.len], &SIGRETURN_TRAMPOLINE);

    paging.mapPage(user_pml4, SIGRETURN_TRAMPOLINE_ADDR, phys, .{
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
    switch (signum) {
        SIGCHLD => return true,
        else => return false,
    }
}

/// Deliver a signal to a user-space task by pushing a signal frame.
/// `user_rsp` is the current user RSP (where we'll push the frame).
/// `user_rip` is the current user RIP (where execution would return).
/// `user_rflags` is the current RFLAGS.
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
) struct { new_rsp: u64, handler: u64 } {
    const handler_addr = t.signal_handlers[signum - 1];

    // Layout (stack grows down, lower addresses are newer):
    //   [SignalFrame]           at frame_addr
    //   [return address]        at frame_addr + sizeof(SignalFrame)
    //   <- handler RSP          = frame_addr + sizeof(SignalFrame)
    //
    // The handler's RSP must satisfy ABI: RSP+8 is 16-aligned at entry.
    // We compute the handler RSP first, then derive the frame address.

    // Reserve space for SignalFrame + return address (8 bytes)
    const total_size: u64 = @sizeOf(SignalFrame) + 8;

    var handler_rsp = user_rsp - total_size;
    handler_rsp = handler_rsp & ~@as(u64, 15);
    handler_rsp += 8;
    if (handler_rsp + total_size > user_rsp) {
        handler_rsp -= 16;
    }

    const frame_addr = handler_rsp - @sizeOf(SignalFrame);

    // Write SignalFrame
    const frame: *SignalFrame = @ptrFromInt(frame_addr);
    const bytes: [*]u8 = @ptrCast(frame);
    @memset(bytes[0..@sizeOf(SignalFrame)], 0);

    frame.rax = 0;
    frame.rip = user_rip;
    frame.rflags = user_rflags;
    frame.rsp = user_rsp;
    frame.signum = signum;

    // Write return address (sigreturn trampoline)
    const ret_addr_ptr: *u64 = @ptrFromInt(handler_rsp);
    ret_addr_ptr.* = SIGRETURN_TRAMPOLINE_ADDR;

    return .{ .new_rsp = handler_rsp, .handler = handler_addr };
}

/// Restore context from a signal frame on sigreturn.
/// The user RSP points to the SignalFrame. We read it and return
/// the saved RIP, RSP, RFLAGS so the syscall return path can use them.
pub fn popSignalFrame(frame_addr: u64) struct { rip: u64, rsp: u64, rflags: u64, rax: u64 } {
    const frame: *const SignalFrame = @ptrFromInt(frame_addr);
    return .{
        .rip = frame.rip,
        .rsp = frame.rsp,
        .rflags = frame.rflags,
        .rax = frame.rax,
    };
}
