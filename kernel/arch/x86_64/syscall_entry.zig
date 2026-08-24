/// System call entry point via SYSCALL/SYSRET (M4.7).
///
/// On x86_64, the SYSCALL instruction:
///   1. Saves RIP to RCX
///   2. Saves RFLAGS to R11
///   3. Loads RIP from IA32_LSTAR MSR
///   4. Loads CS/SS from IA32_STAR MSR (bits 32:47 for CS, 48:63 for SS on return)
///   5. Clears RFLAGS.IF (disables interrupts)
///
/// SYSRET reverses this: restores RIP from RCX, RFLAGS from R11.
///
/// For M4/M5, the syscall entry:
///   - Saves all GPRs
///   - Determines the personality of the calling process
///   - Routes to the appropriate handler (Linux/Windows/Native)
///   - Restores GPRs and returns via SYSRETQ
///
/// Currently kernel-only. User-space activation comes in M5.
const serial = @import("serial.zig");
const fmt = @import("../../lib/fmt.zig");
const errno = @import("../../lib/errno.zig");
const unsupported_policy = @import("../../proc/unsupported_policy.zig");
const cpu_capacity = @import("../cpu_capacity.zig");

// MSR constants
const MSR_EFER = 0xC0000080;
const MSR_STAR = 0xC0000081;
const MSR_LSTAR = 0xC0000082;
const MSR_CSTAR = 0xC0000083;
const MSR_SFMASK = 0xC0000084;
const MSR_GS_BASE = 0xC0000101;
const MSR_KERNEL_GS_BASE = 0xC0000102;

/// Write to an MSR.
pub inline fn wrmsr(msr: u32, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [lo] "{eax}" (@as(u32, @truncate(value))),
          [hi] "{edx}" (@as(u32, @truncate(value >> 32))),
    );
}

/// Read from an MSR.
inline fn rdmsr(msr: u32) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [msr] "{ecx}" (msr),
    );
    return (@as(u64, hi) << 32) | lo;
}

/// Syscall frame — saved by the entry stub.
/// Layout matches the stack push order (last pushed = lowest address = offset 0).
pub const SyscallFrame = extern struct {
    rax: u64, // Syscall number (pushed last, lowest address)
    rbx: u64,
    rcx: u64, // Saved by SYSCALL (RIP)
    rdx: u64,
    rsi: u64,
    rdi: u64,
    rbp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64, // Saved by SYSCALL (RFLAGS)
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64, // Pushed first, highest address
};

/// Per-CPU data accessible via GS segment in kernel mode.
/// In user mode, GSBase points to user-space TLS (unused for now).
/// In kernel mode (after swapgs), GSBase points to this struct.
pub const MAX_CPUS: usize = cpu_capacity.MAX_CPUS;

pub const PerCpu = extern struct {
    kernel_rsp: u64, // Kernel RSP0 to switch to on syscall
    saved_user_rsp: u64, // User RSP saved across syscall
    saved_stack_anchor: u64, // RSP anchor for context switch (commonStub)
    slice_remaining: u64, // Timeslice ticks remaining
    cpu_id: u32, // Logical CPU index (0 = BSP)
    apic_id: u32, // LAPIC APIC ID
    current_tid: u32, // Currently running task TID on this CPU (0 = idle)
    current_task_idx: u32, // Index of currently running task (0xFFFFFFFF = none)
    // M8-5b-1: signal/exec return path — per-CPU so concurrent CPUs don't stomp
    // each other's pending handler redirect (was a single global exec_result).
    exec_pending: u64,
    exec_new_entry: u64,
    exec_new_stack: u64,
    /// Non-zero while handling a reschedule IPI — bypass single-task fast-path.
    force_reschedule: u8,
    /// CR3 this CPU is currently running (0 = not recorded yet). Updated on
    /// every CR3 write so TLB shootdown initiators can skip CPUs that do not
    /// run the target address space. Read lock-free by remote CPUs.
    current_cr3: u64 = 0,
    /// Set by sched.switchAnchor when a scheduler pass redirected this CPU's
    /// interrupt return to another task's frame. commonStub's epilogue trusts
    /// this flag — not an anchor/frame pointer comparison — because a nested
    /// commonStub entry (e.g. a #PF inside the handler, such as the COW fault
    /// from a signal-frame push after fork) clobbers %%gs:16, and the outer
    /// epilogue must still resume through its OWN entry frame.
    anchor_switched: u8 = 0,
};

/// Per-CPU data array, indexed by CPU logical ID.
/// slice_remaining starts at the scheduler timeslice (sched.TIMESLICE_TICKS = 10)
/// so a freshly-brought-up CPU behaves like the old global default.
pub var percpu_array: [MAX_CPUS]PerCpu = blk: {
    var array: [MAX_CPUS]PerCpu = undefined;
    for (&array, 0..) |*percpu, cpu_id| {
        percpu.* = .{
            .kernel_rsp = 0,
            .saved_user_rsp = 0,
            .saved_stack_anchor = 0,
            .slice_remaining = 10,
            .cpu_id = @intCast(cpu_id),
            .apic_id = 0,
            .current_tid = 0,
            .current_task_idx = 0xFFFFFFFF,
            .exec_pending = 0,
            .exec_new_entry = 0,
            .exec_new_stack = 0,
            .force_reschedule = 0,
        };
    }
    break :blk array;
};

pub fn configuredPerCpuSlice() []PerCpu {
    const smp = @import("../../smp.zig");
    const count = @min(@as(usize, @intCast(smp.configured_cpu_count)), MAX_CPUS);
    return percpu_array[0..count];
}

/// Personality type for ABI routing.
pub const Personality = enum(u8) {
    native = 0,
    linux = 1,
    windows = 2,
};

export var fork_parent_ret: u64 = 0;

/// Single BSP per-cpu data (single-core for now).
var bsp_percpu: PerCpu = .{
    .kernel_rsp = 0,
    .saved_user_rsp = 0,
    .saved_stack_anchor = 0,
    .slice_remaining = 0,
    .cpu_id = 0,
    .apic_id = 0,
    .current_tid = 0,
    .current_task_idx = 0xFFFFFFFF,
};

/// Global pointer to syscall dispatch function, used by syscallEntry
/// to call the handler without clobbering any registers via input operands.
/// Exported with C linkage so the asm template can reference it by name.
export var dispatch_handler: *const fn (*SyscallFrame) callconv(.c) void = &syscallDispatch;

/// Get pointer to current CPU's per-cpu data via GS base.
pub fn getPerCpu() *PerCpu {
    // In kernel mode, GS_BASE points to our PerCpu struct (set via wrmsr)
    const gs_base = rdmsr(0xC0000101); // MSR_GS_BASE
    return @ptrFromInt(gs_base);
}

/// Like getPerCpu, but returns null if GS_BASE is unset (0) — i.e. during very
/// early boot before syscall_entry.init()/per-CPU bring-up. Callers that may run
/// before per-CPU data exists (e.g. sched.currentTask) use this to stay safe.
pub fn getPerCpuOrNull() ?*PerCpu {
    const gs_base = rdmsr(0xC0000101); // MSR_GS_BASE
    if (gs_base == 0) return null;
    return @ptrFromInt(gs_base);
}

/// Record the CR3 this CPU is now running. Must be called after every CR3
/// write (context switch, execve, syscall re-sync) so TLB shootdown
/// initiators can filter IPIs by address space via `percpu_array[].current_cr3`.
pub inline fn noteCr3Switch(cr3: u64) void {
    getPerCpu().current_cr3 = cr3;
}

// v53.48: Comptime assertions — verify PerCpu field offsets for %gs: direct access.
// If a field is added/removed/reordered, these will fail at compile time.
comptime {
    if (@offsetOf(PerCpu, "current_task_idx") != 44)
        @compileError("PerCpu.current_task_idx offset changed — update %gs: offset");
    if (@offsetOf(PerCpu, "cpu_id") != 32)
        @compileError("PerCpu.cpu_id offset changed — update %gs: offset");
    if (@offsetOf(PerCpu, "slice_remaining") != 24)
        @compileError("PerCpu.slice_remaining offset changed — update %gs: offset");
}

// v53.48: Fast per-CPU field access via %gs:offset — eliminates rdmsr
// serialization instruction (~150 cycles) on every syscall/scheduler hot path.
// Safe after GS_BASE is set during sched.init() (before any task runs).

/// Read current_task_idx directly via %gs:44 — no rdmsr needed.
pub inline fn gsReadCurrentTaskIdx() u32 {
    var v: u32 = undefined;
    asm volatile ("movl %%gs:44, %[v]"
        : [v] "=r" (v),
    );
    return v;
}

/// Write current_task_idx directly via %gs:44.
pub inline fn gsWriteCurrentTaskIdx(v: u32) void {
    asm volatile ("movl %[v], %%gs:44"
        :
        : [v] "r" (v),
    );
}

/// Read cpu_id directly via %gs:32.
pub inline fn gsReadCpuId() u32 {
    var v: u32 = undefined;
    asm volatile ("movl %%gs:32, %[v]"
        : [v] "=r" (v),
    );
    return v;
}

/// Read slice_remaining directly via %gs:24.
pub inline fn gsReadSliceRemaining() u64 {
    var v: u64 = undefined;
    asm volatile ("movq %%gs:24, %[v]"
        : [v] "=r" (v),
    );
    return v;
}

/// Write slice_remaining directly via %gs:24.
pub inline fn gsWriteSliceRemaining(v: u64) void {
    asm volatile ("movq %[v], %%gs:24"
        :
        : [v] "r" (v),
    );
}

/// Compile-time offset of saved_stack_anchor in PerCpu (used by commonStub asm).
pub const PERCPU_ANCHOR_OFFSET = @offsetOf(PerCpu, "saved_stack_anchor");
pub const PERCPU_EXEC_PENDING_OFFSET = @offsetOf(PerCpu, "exec_pending");
pub const PERCPU_EXEC_ENTRY_OFFSET = @offsetOf(PerCpu, "exec_new_entry");
pub const PERCPU_EXEC_STACK_OFFSET = @offsetOf(PerCpu, "exec_new_stack");

comptime {
    // syscallEntry naked asm bakes these offsets as immediates (like %%gs:8).
    if (PERCPU_EXEC_PENDING_OFFSET != 48 or PERCPU_EXEC_ENTRY_OFFSET != 56 or PERCPU_EXEC_STACK_OFFSET != 64) {
        @compileError("PerCpu exec_* layout changed — update syscallEntry %%gs offsets");
    }
}

/// Set GS base for the given CPU (used during CPU init).
pub fn setPerCpuGsBase(cpu_id: u32) void {
    if (cpu_id >= MAX_CPUS) return;
    const addr = @intFromPtr(&percpu_array[cpu_id]);
    wrmsr(0xC0000101, addr); // GS_BASE (kernel mode)
    wrmsr(0xC0000102, addr); // KERNEL_GS_BASE (loaded by swapgs)
}

const MSR_FS_BASE: u32 = 0xC0000100;

/// FS_BASE currently programmed on each CPU. WRMSR is expensive and nearly
/// every task runs with no TLS at all, so skip the write when the value is
/// already loaded. Only setUserTlsBase writes FS_BASE, so this cannot go stale.
var tls_base_loaded: [MAX_CPUS]u64 = @splat(0);

/// Install a task's TLS base on the current CPU. Called by the scheduler when a
/// user task is placed on a CPU, so a task's TLS follows it across CPUs and a
/// task without TLS never inherits the previous task's base.
pub fn setUserTlsBase(base: u64) void {
    const cpu_id = getPerCpu().cpu_id;
    if (cpu_id >= MAX_CPUS) return;
    if (tls_base_loaded[cpu_id] == base) return;
    wrmsr(MSR_FS_BASE, base);
    tls_base_loaded[cpu_id] = base;
}

/// The naked syscall entry point — loaded into IA32_LSTAR.
/// This is called by the SYSCALL instruction from user space.
///
/// SYSCALL does NOT switch stacks. We must:
///   1. swapgs (kernel GSBase now in GS)
///   2. Save user RSP, load kernel RSP from PerCpu via GS
///   3. Push all GPRs on kernel stack
///   4. Call dispatch
///   5. Restore GPRs, restore user RSP, swapgs back, sysretq
///
/// PerCpu layout (accessed via %%gs:offset):
///   offset 0: kernel_rsp (u64)
///   offset 8: saved_user_rsp (u64)
///   offset 48/56/64: exec_pending / exec_new_entry / exec_new_stack (M8-5b-1)
pub fn syscallEntry() callconv(.naked) void {
    // No input operands needed. The handler address is loaded AFTER all GPR
    // saves via an indirect call through RAX. We save/restore RAX from the frame.
    //
    // The old approach passed &syscallDispatch as an "r" input, but the compiler
    // emits a load into that register BEFORE the asm template, clobbering the
    // user's value in that register (RAX in practice). This destroyed the
    // syscall number.
    //
    // New approach: after saving all GPRs, read the handler address from a
    // global pointer that we set up at init time.
    asm volatile (
        \\// SYSCALL: RIP→RCX, RFLAGS→R11. RSP unchanged (user stack).
        \\swapgs
        \\
        \\// Save user RSP to PerCpu.saved_user_rsp (offset 8)
        \\movq %%rsp, %%gs:8
        \\
        \\// Load kernel RSP from PerCpu.kernel_rsp (offset 0)
        \\movq %%gs:0, %%rsp
        \\
        \\// Now on kernel stack. Push all GPRs (SyscallFrame order).
        \\pushq %%r15
        \\pushq %%r14
        \\pushq %%r13
        \\pushq %%r12
        \\pushq %%r11
        \\pushq %%r10
        \\pushq %%r9
        \\pushq %%r8
        \\pushq %%rbp
        \\pushq %%rdi
        \\pushq %%rsi
        \\pushq %%rdx
        \\pushq %%rcx
        \\pushq %%rbx
        \\pushq %%rax
        \\
        \\// RSP now points to SyscallFrame. All original GPRs saved.
        \\// First arg (RDI) = frame pointer
        \\movq %%rsp, %%rdi
        \\
        \\// Load handler from global pointer (set at init time)
        \\movq dispatch_handler(%%rip), %%rax
        \\
        \\// Align stack for ABI call
        \\movq %%rsp, %%rbp
        \\andq $-16, %%rsp
        \\
        \\callq *%%rax
        \\
        \\// Restore RSP (scheduler may have switched stacks via interrupt)
        \\movq %%rbp, %%rsp
        \\
        \\movq fork_parent_ret(%%rip), %%rax
        \\testq %%rax, %%rax
        \\jz 4f
        \\movq %%rax, (%%rsp)
        \\movq $0, fork_parent_ret(%%rip)
        \\4:
        \\
        \\// Pop GPRs
        \\popq %%rax
        \\popq %%rbx
        \\popq %%rcx
        \\popq %%rdx
        \\popq %%rsi
        \\popq %%rdi
        \\popq %%rbp
        \\popq %%r8
        \\popq %%r9
        \\popq %%r10
        \\popq %%r11
        \\popq %%r12
        \\popq %%r13
        \\popq %%r14
        \\popq %%r15
        \\
        \\// Save return value (RAX) before exec_result check clobbers registers
        \\pushq %%rax
        \\
        \\// M8-5b-1: per-CPU exec redirect (signal/sigreturn) via %%gs:48/56/64
        \\movq %%gs:48, %%rax
        \\testq %%rax, %%rax
        \\jz 2f
        \\// Restore the syscall's return value BEFORE switching stacks: the
        \\// sigreturn redirect (pending=2) must deliver the sigframe's rax to
        \\// the user; exec (1) and handler entry (3) do not care about rax.
        \\popq %%rax
        \\movq %%gs:56, %%rcx
        \\movq %%gs:64, %%rsp
        \\movq $0x202, %%r11
        \\movq $0, %%gs:48
        \\jmp 3f
        \\2:
        \\popq %%rax       // restore return value
        \\movq %%gs:8, %%rsp
        \\3:
        \\
        \\// Swap GS back to user GSBase
        \\swapgs
        \\
        \\// SYSRETQ: RCX → RIP, R11 → RFLAGS
        \\sysretq
        ::: .{ .memory = true });
}

/// Program IA32_STAR / LSTAR / SFMASK on the CPU currently executing.
/// Required on every logical processor — these MSRs are per-core, not inherited
/// reliably across AP INIT/SIPI.
pub fn initSyscallMsrsOnThisCpu() void {
    const star: u64 = (@as(u64, 0x08) << 32) | (@as(u64, 0x1B) << 48);
    wrmsr(MSR_STAR, star);
    wrmsr(MSR_LSTAR, @intFromPtr(&syscallEntry));
    wrmsr(MSR_SFMASK, 0x300); // TF | IF
}

/// Pull PerCpu.saved_user_rsp (%gs:8) into the running user task (after syscall entry).
pub fn syncUserRspToTask(t: *@import("../../proc/task.zig").Task) void {
    if (!t.is_user) return;
    t.saved_user_rsp = getPerCpu().saved_user_rsp;
}

/// Push task.saved_user_rsp into PerCpu for sysret (%gs:8 restore path).
pub fn syncUserRspFromTask(t: *@import("../../proc/task.zig").Task) void {
    if (!t.is_user) return;
    getPerCpu().saved_user_rsp = t.saved_user_rsp;
}

/// Ensure this CPU's syscall/interrupt stacks and CR3 match the running user task.
/// APs enter user mode via `enterUserOnAp` (not commonStub), so the first syscall on
/// a freshly-scheduled task must re-sync `kernel_rsp`/TSS RSP0 if still zero/stale.
fn prepareSyscallCpu() void {
    const sched = @import("../../proc/sched.zig");
    const gdt_mod = @import("gdt.zig");
    const pc = getPerCpu();
    const t = sched.currentTask() orelse return;
    if (!t.is_user or t.page_table_phys == 0) return;

    if (pc.kernel_rsp != t.kernel_stack_top) {
        pc.kernel_rsp = t.kernel_stack_top;
        gdt_mod.setRsp0(pc.cpu_id, t.kernel_stack_top);
        // ioperm: pair every per-switch RSP0 update with the IOPB load. The
        // mismatch branch fires exactly when this CPU changed current task.
        @import("../../proc/ioperm.zig").loadForTask(pc.cpu_id, t);
    }
    pc.current_tid = t.tid;

    @import("pcid.zig").switchCr3(t.page_table_phys);
    syncUserRspToTask(t);
}

/// Central syscall dispatch — called from the entry stub with the frame.
/// Routes based on the current process's personality field.
pub fn syscallDispatch(frame: *SyscallFrame) callconv(.c) void {
    prepareSyscallCpu();
    const syscall_nr = frame.rax;

    if (dispatchLinuxRlimitAlias(frame, syscall_nr)) return;

    switch (syscall_nr) {
        1 => {
            syscallWrite(frame);
            checkSignalsOnSyscallReturn(frame);
        },
        2 => {
            syscallExit(frame);
        },
        3 => {
            const diag = @import("../../debug/kernel_diag.zig");
            diag.dumpFull();
            frame.rax = 0;
        },
        4 => {
            syscallGetpid(frame);
        },
        5 => {
            syscallSpawn(frame);
        },
        6 => {
            syscallWaitpid(frame);
            checkSignalsOnSyscallReturn(frame);
        },
        7 => {
            syscallBrk(frame);
        },
        8 => {
            syscallMmap(frame);
        },
        9 => {
            syscallOpen(frame);
        },
        10 => {
            syscallRead(frame);
            checkSignalsOnSyscallReturn(frame);
        },
        11 => {
            syscallClose(frame);
        },
        12 => {
            syscallMunmap(frame);
        },
        13 => {
            syscallSigaction(frame);
        },
        14 => {
            syscallSigprocmask(frame);
        },
        15 => {
            syscallSigreturn(frame);
        },
        22 => {
            syscallPipe(frame);
        },
        33 => {
            syscallDup2(frame);
        },
        57 => {
            syscallFork(frame);
        },
        59 => {
            syscallExecve(frame);
        },
        62 => {
            syscallKill(frame);
        },
        96 => {
            syscallGettimeofday(frame);
        },
        100 => {
            syscallNetSend(frame);
        },
        101 => {
            syscallNetRecv(frame);
        },
        102 => {
            syscallUdpSend(frame);
        },
        103 => {
            syscallUdpRecv(frame);
        },
        104 => {
            syscallNetPoll(frame);
        },
        105 => {
            syscallGetenv(frame);
        },
        106 => {
            syscallSetenv(frame);
        },
        107 => {
            syscallListdir(frame);
        },
        63 => {
            syscallUname(frame);
        },
        108 => {
            syscallChdir(frame);
        },
        109 => {
            syscallGetcwd(frame);
        },
        110 => {
            syscallFstat(frame);
        },
        111 => {
            syscallUnlink(frame);
        },
        112 => {
            syscallTcpConnect(frame);
        },
        113 => {
            syscallTcpSend(frame);
        },
        114 => {
            syscallTcpRecv(frame);
        },
        115 => {
            syscallTcpClose(frame);
        },
        116 => {
            syscallTcpPoll(frame);
        },
        117 => {
            syscallSocket(frame);
        },
        118 => {
            syscallBind(frame);
        },
        119 => {
            syscallListen(frame);
        },
        120 => {
            syscallAccept(frame);
        },
        121 => {
            syscallSendto(frame);
        },
        122 => {
            syscallRecvfrom(frame);
        },
        123 => {
            syscallMkdir(frame);
        },
        124 => {
            syscallConnect(frame);
        },
        228 => {
            syscallClock_gettime(frame);
        },
        // ── v30.0: Wire missing syscalls ──────────────────────────────
        125 => { // shutdown(fd, how)
            frame.rax = @bitCast(socket_mod.shutdown(@truncate(frame.rdi), @truncate(frame.rsi)));
        },
        126 => { // getsockname(fd, addr, addrlen)
            frame.rax = @bitCast(socket_mod.getsockname(@truncate(frame.rdi), frame.rsi, frame.rdx));
        },
        127 => { // getpeername(fd, addr, addrlen)
            frame.rax = @bitCast(socket_mod.getpeername(@truncate(frame.rdi), frame.rsi, frame.rdx));
        },
        128 => { // socketpair(domain, type, protocol, sv)
            frame.rax = @bitCast(socket_mod.socketpair(@truncate(frame.rdi), @truncate(frame.rsi), @truncate(frame.rdx), frame.r10));
        },
        129 => { // sendmsg(fd, msg, flags)
            frame.rax = @bitCast(socket_mod.sendmsg(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx)));
        },
        130 => { // recvmsg(fd, msg, flags)
            frame.rax = @bitCast(socket_mod.recvmsg(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx)));
        },
        131 => { // accept4(fd, addr, addrlen, flags)
            frame.rax = @bitCast(socket_mod.accept4(@truncate(frame.rdi), frame.rsi, frame.rdx, @truncate(frame.r10)));
        },
        132 => { // setsockopt(fd, level, optname, optval, optlen)
            frame.rax = @bitCast(socket_mod.setsockopt(frame.rdi, frame.rsi, frame.rdx, frame.r10, frame.r8));
        },
        133 => { // getsockopt(fd, level, optname, optval, optlen)
            frame.rax = @bitCast(socket_mod.getsockopt(frame.rdi, frame.rsi, frame.rdx, frame.r10, frame.r8));
        },
        134 => { // recvmmsg(sockfd, msgvec, vlen, flags, timeout)
            frame.rax = @bitCast(socket_mod.recvmmsg(@truncate(frame.rdi), frame.rsi, frame.rdx, @truncate(frame.r10), frame.r8));
        },
        135 => { // sendmmsg(sockfd, msgvec, vlen, flags)
            frame.rax = @bitCast(socket_mod.sendmmsg(@truncate(frame.rdi), frame.rsi, frame.rdx, @truncate(frame.r10)));
        },
        136 => { // pread64(fd, buf, count, offset)
            frame.rax = @bitCast(file_io_mod.pread(@intCast(frame.rdi), frame.rsi, frame.rdx, frame.r10));
        },
        137 => { // pwrite64(fd, buf, count, offset)
            frame.rax = @bitCast(file_io_mod.pwrite(@intCast(frame.rdi), frame.rsi, frame.rdx, frame.r10));
            checkSignalsOnSyscallReturn(frame);
        },
        138 => { // readv(fd, iov, iovcnt)
            frame.rax = @bitCast(readv_mod.readv(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx)));
        },
        139 => { // writev(fd, iov, iovcnt)
            frame.rax = @bitCast(readv_mod.writev(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx)));
            checkSignalsOnSyscallReturn(frame);
        },
        140 => { // preadv(fd, iov, iovcnt, pos_l)
            frame.rax = @bitCast(readv_mod.preadv(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx), frame.r10));
        },
        141 => { // pwritev(fd, iov, iovcnt, pos_l)
            frame.rax = @bitCast(readv_mod.pwritev(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx), frame.r10));
            checkSignalsOnSyscallReturn(frame);
        },
        142 => { // fcntl(fd, cmd, arg)
            frame.rax = @bitCast(fcntl_mod.sysFcntl(frame.rdi, frame.rsi, frame.rdx));
        },
        143 => { // futex(uaddr, op, val, val2, uaddr2, val3)
            // v53.44: Linux x86_64 ABI: r10=val2/timeout, r8=uaddr2, r9=val3
            frame.rax = @bitCast(futex_mod.futex(frame.rdi, @bitCast(frame.rsi), frame.rdx, frame.r10, frame.r8, frame.r9));
        },
        144 => { // sendfile(out_fd, in_fd, offset_ptr, count)
            frame.rax = @bitCast(splice_mod.sysSendfile(@truncate(frame.rdi), @truncate(frame.rsi), frame.rdx, frame.r10));
            checkSignalsOnSyscallReturn(frame);
        },
        145 => { // splice(fd_in, off_in, fd_out, off_out, len, flags)
            frame.rax = @bitCast(splice_mod.sysSplice(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx), frame.r10, frame.r8, @truncate(frame.r9)));
            checkSignalsOnSyscallReturn(frame);
        },
        146 => { // epoll_create1(flags)
            const epoll_policy = @import("../../net/epoll_policy.zig");
            const policy_result = epoll_policy.validate(@truncate(frame.rdi));
            if (policy_result != 0) {
                frame.rax = @bitCast(policy_result);
            } else {
                const epoll_mod = @import("../../net/epoll.zig");
                frame.rax = @bitCast(@as(i64, epoll_mod.epollCreate()));
            }
        },
        147 => { // epoll_ctl(epfd, op, fd, event)
            const epoll_mod = @import("../../net/epoll.zig");
            const epfd_idx: u32 = @truncate(frame.rdi);
            const op: i32 = @bitCast(@as(u32, @truncate(frame.rsi)));
            const fd_arg: i32 = @bitCast(@as(u32, @truncate(frame.rdx)));
            frame.rax = @bitCast(@as(i64, epoll_mod.epollCtl(epfd_idx, op, fd_arg, frame.r10)));
        },
        148 => { // epoll_wait(epfd, events, maxevents, timeout)
            const epoll_mod = @import("../../net/epoll.zig");
            const epfd_idx: u32 = @truncate(frame.rdi);
            const max_ev: u32 = @truncate(frame.rdx);
            const timeout: i32 = @bitCast(@as(u32, @truncate(frame.r10)));
            frame.rax = @bitCast(@as(i64, epoll_mod.epollWait(epfd_idx, frame.rsi, max_ev, timeout)));
        },
        149 => { // shmget(key, size, shmflg)
            const shm_mod = @import("../../ipc/sysv_shm.zig");
            const key: i32 = @bitCast(@as(u32, @truncate(frame.rdi)));
            const shmflg: i32 = @bitCast(@as(u32, @truncate(frame.rdx)));
            frame.rax = @bitCast(shm_mod.shmget(key, frame.rsi, shmflg));
        },
        150 => { // shmat(shmid, shmaddr, shmflg)
            const shm_mod = @import("../../ipc/sysv_shm.zig");
            frame.rax = @bitCast(shm_mod.shmat(@truncate(frame.rdi), frame.rsi, frame.rdx));
        },
        151 => { // shmdt(shmaddr)
            const shm_mod = @import("../../ipc/sysv_shm.zig");
            frame.rax = @bitCast(shm_mod.shmdt(frame.rdi));
        },
        152 => { // shmctl(shmid, cmd, buf)
            const shm_mod = @import("../../ipc/sysv_shm.zig");
            const cmd: i32 = @bitCast(@as(u32, @truncate(frame.rsi)));
            frame.rax = @bitCast(shm_mod.shmctl(@truncate(frame.rdi), cmd, frame.rdx));
        },
        153 => { // semget(key, nsems, semflg)
            const sem_mod = @import("../../ipc/sysv_sem.zig");
            const key: i32 = @bitCast(@as(u32, @truncate(frame.rdi)));
            const nsems: i32 = @bitCast(@as(u32, @truncate(frame.rsi)));
            const semflg: i32 = @bitCast(@as(u32, @truncate(frame.rdx)));
            frame.rax = @bitCast(sem_mod.semget(key, nsems, semflg));
        },
        154 => { // semop(semid, sops, nsops)
            const sem_mod = @import("../../ipc/sysv_sem.zig");
            const op: i16 = @bitCast(@as(u16, @truncate(frame.rdx)));
            frame.rax = @bitCast(sem_mod.semop(@truncate(frame.rdi), @truncate(frame.rsi), op));
        },
        155 => { // semctl(semid, semnum, cmd, arg)
            const sem_mod = @import("../../ipc/sysv_sem.zig");
            const semnum: i32 = @bitCast(@as(u32, @truncate(frame.rsi)));
            const cmd: i32 = @bitCast(@as(u32, @truncate(frame.rdx)));
            const arg: i32 = @bitCast(@as(u32, @truncate(frame.r10)));
            frame.rax = @bitCast(sem_mod.semctl(@truncate(frame.rdi), semnum, cmd, arg));
        },
        156 => { // msgget(key, msgflg)
            const msg_mod = @import("../../ipc/sysv_msg.zig");
            const key: i32 = @bitCast(@as(u32, @truncate(frame.rdi)));
            const msgflg: i32 = @bitCast(@as(u32, @truncate(frame.rsi)));
            frame.rax = @bitCast(msg_mod.msgget(key, msgflg));
        },
        157 => { // msgsnd(msqid, msgp, msgsz, msgflg)
            const msg_mod = @import("../../ipc/sysv_msg.zig");
            const msgflg: i32 = @bitCast(@as(u32, @truncate(frame.r10)));
            frame.rax = @bitCast(msg_mod.msgsnd(@truncate(frame.rdi), frame.rsi, frame.rdx, msgflg));
        },
        158 => { // msgrcv(msqid, msgp, msgsz, msgtyp, msgflg)
            const msg_mod = @import("../../ipc/sysv_msg.zig");
            const msgflg: i32 = @bitCast(@as(u32, @truncate(frame.r8)));
            frame.rax = @bitCast(msg_mod.msgrcv(@truncate(frame.rdi), frame.rsi, frame.rdx, @bitCast(frame.r10), msgflg));
        },
        159 => { // msgctl(msqid, cmd, buf)
            const msg_mod = @import("../../ipc/sysv_msg.zig");
            const cmd: i32 = @bitCast(@as(u32, @truncate(frame.rsi)));
            frame.rax = @bitCast(msg_mod.msgctl(@truncate(frame.rdi), cmd, frame.rdx));
        },
        160 => { // dup(oldfd) — v53.47: Use syscallDup (allocFd + dup2), not dup2(fd,fd)
            frame.rax = @bitCast(syscallDup(@truncate(frame.rdi)));
        },
        161 => { // dup3(oldfd, newfd, flags)
            const O_CLOEXEC: u64 = 0x80000;
            if (frame.rdi == frame.rsi) {
                frame.rax = @bitCast(errno.EINVAL);
                return;
            }
            if (frame.rdx & ~O_CLOEXEC != 0) {
                frame.rax = @bitCast(errno.EINVAL);
                return;
            }
            const dup_result = proc_mgmt_mod.dup2(@intCast(frame.rdi), @intCast(frame.rsi));
            if (dup_result >= 0 and (frame.rdx & O_CLOEXEC) != 0) {
                const sched_mod = @import("../../proc/sched.zig");
                const task_mod3 = @import("../../proc/task.zig");
                const cur_idx2 = sched_mod.currentTaskIndex() orelse {
                    frame.rax = @bitCast(dup_result);
                    return;
                };
                const cur2 = task_mod3.getTask(cur_idx2) orelse {
                    frame.rax = @bitCast(dup_result);
                    return;
                };
                const newfd2: u32 = @intCast(dup_result);
                if (newfd2 < vfs_mod.MAX_FDS) {
                    cur2.fd_table.fds[newfd2].fd_flags = 1;
                }
            }
            frame.rax = @bitCast(dup_result);
        },
        // ── v31.0: Wire existing modules ─────────────────────────
        162 => { // poll(fds, nfds, timeout)
            frame.rax = @bitCast(poll_mod.poll(frame.rdi, frame.rsi, frame.rdx));
        },
        163 => { // select(nfds, readfds, writefds, exceptfds, timeout)
            frame.rax = @bitCast(select_mod.select(frame.rdi, frame.rsi, frame.rdx, frame.r10, frame.r8));
        },
        164 => { // mprotect(addr, len, prot)
            frame.rax = @bitCast(mprotect_mod.sysMprotect(frame.rdi, frame.rsi, frame.rdx));
        },
        165 => { // ioctl(fd, cmd, arg)
            frame.rax = @bitCast(ioctl_mod.sysIoctl(frame.rdi, frame.rsi, frame.rdx));
        },
        // ── v31.1: inotify/eventfd/timerfd/getdents ──────────────
        166 => { // inotify_init1(flags)
            _ = frame.rdi;
            frame.rax = @bitCast(inotify_mod.inotifyInit());
        },
        167 => { // inotify_add_watch(fd, pathname, mask)
            frame.rax = @bitCast(inotify_mod.addWatch(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx)));
        },
        168 => { // inotify_rm_watch(fd, wd)
            const wd: i32 = @bitCast(@as(u32, @truncate(frame.rsi)));
            frame.rax = @bitCast(inotify_mod.rmWatch(@truncate(frame.rdi), wd));
        },
        169 => { // eventfd(initval, flags)
            _ = frame.rsi;
            frame.rax = @bitCast(@as(i64, eventfd_mod.eventfdCreate(frame.rdi)));
        },
        170 => { // timerfd_create(clockid, flags)
            frame.rax = @bitCast(@as(i64, timerfd_mod.timerfdCreate(@truncate(frame.rdi), @truncate(frame.rsi))));
        },
        171 => { // timerfd_settime(fd, flags, new_value, old_value)
            const tfd_idx: u32 = @truncate(frame.rdi);
            const flags: u32 = @truncate(frame.rsi);
            const new_val_ptr: u64 = frame.rdx;
            const old_val_ptr: u64 = frame.r10;
            // Read Itimerspec from user space
            const copy = @import("../../mm/copy_from_user.zig");
            var new_buf: [@sizeOf(timerfd_mod.Itimerspec)]u8 = undefined;
            if (!copy.validateUserBuffer(new_val_ptr, @sizeOf(timerfd_mod.Itimerspec))) {
                frame.rax = @bitCast(@as(i64, -14));
                return;
            }
            if (copy.copyFromUser(&new_buf, @ptrFromInt(new_val_ptr), @sizeOf(timerfd_mod.Itimerspec)) != @sizeOf(timerfd_mod.Itimerspec)) {
                frame.rax = @bitCast(@as(i64, -14));
                return;
            }
            if (old_val_ptr != 0 and !copy.validateUserBufferWritable(old_val_ptr, @sizeOf(timerfd_mod.Itimerspec))) {
                frame.rax = @bitCast(@as(i64, -14));
                return;
            }
            const new_val: *const timerfd_mod.Itimerspec = @ptrCast(@alignCast(&new_buf));
            if (old_val_ptr != 0) {
                var old_val: timerfd_mod.Itimerspec = undefined;
                const get_result = timerfd_mod.timerfdGettime(tfd_idx, &old_val);
                if (get_result != 0) {
                    frame.rax = @bitCast(@as(i64, get_result));
                    return;
                }
                const ov_bytes: [*]const u8 = @ptrCast(&old_val);
                if (copy.copyToUser(@ptrFromInt(old_val_ptr), ov_bytes[0..@sizeOf(timerfd_mod.Itimerspec)], @sizeOf(timerfd_mod.Itimerspec)) != @sizeOf(timerfd_mod.Itimerspec)) {
                    frame.rax = @bitCast(@as(i64, -14));
                    return;
                }
            }
            const result = timerfd_mod.timerfdSettime(tfd_idx, flags, new_val, null);
            frame.rax = @bitCast(@as(i64, result));
        },
        172 => { // timerfd_gettime(fd, curr_value)
            const tfd_idx: u32 = @truncate(frame.rdi);
            const cur_ptr: u64 = frame.rsi;
            if (cur_ptr == 0 or cur_ptr >= 0x0000_8000_0000_0000) {
                frame.rax = @bitCast(@as(i64, -14));
                return;
            }
            var cur_val: timerfd_mod.Itimerspec = undefined;
            const result = timerfd_mod.timerfdGettime(tfd_idx, &cur_val);
            if (result == 0) {
                const copy = @import("../../mm/copy_from_user.zig");
                const cv_bytes: [*]const u8 = @ptrCast(&cur_val);
                if (!copy.validateUserBufferWritable(cur_ptr, @sizeOf(timerfd_mod.Itimerspec)) or
                    copy.copyToUser(@ptrFromInt(cur_ptr), cv_bytes[0..@sizeOf(timerfd_mod.Itimerspec)], @sizeOf(timerfd_mod.Itimerspec)) != @sizeOf(timerfd_mod.Itimerspec))
                {
                    frame.rax = @bitCast(@as(i64, -14));
                    return;
                }
            }
            frame.rax = @bitCast(@as(i64, result));
        },
        173 => { // getdents64(fd, buf, count)
            frame.rax = @bitCast(getdents_mod.getdents64(@truncate(frame.rdi), frame.rsi, frame.rdx));
        },
        // ── v31.2: credentials/readlink/statx/copy_file_range/flock ──
        174 => { // setuid(uid)
            if (!checkCapForCurrent("cap_setuid")) {
                frame.rax = @bitCast(@as(i64, -1)); // EPERM
            } else {
                frame.rax = @bitCast(cred_mod.setuid(@truncate(frame.rdi)));
            }
        },
        175 => { // setgid(gid)
            if (!checkCapForCurrent("cap_setgid")) {
                frame.rax = @bitCast(@as(i64, -1)); // EPERM
            } else {
                frame.rax = @bitCast(cred_mod.setgid(@truncate(frame.rdi)));
            }
        },
        176 => { // setreuid(ruid, euid)
            frame.rax = @bitCast(cred_mod.setreuid(@truncate(frame.rdi), @truncate(frame.rsi)));
        },
        177 => { // setregid(rgid, egid)
            frame.rax = @bitCast(cred_mod.setregid(@truncate(frame.rdi), @truncate(frame.rsi)));
        },
        178 => { // setresuid(ruid, euid, suid)
            frame.rax = @bitCast(cred_mod.setresuid(@truncate(frame.rdi), @truncate(frame.rsi), @truncate(frame.rdx)));
        },
        179 => { // getresuid(ruid*, euid*, suid*)
            frame.rax = @bitCast(cred_mod.getresuid118(frame.rdi, frame.rsi, frame.rdx));
        },
        180 => { // setresgid(rgid, egid, sgid)
            frame.rax = @bitCast(cred_mod.setresgid(@truncate(frame.rdi), @truncate(frame.rsi), @truncate(frame.rdx)));
        },
        181 => { // getresgid(rgid*, egid*, sgid*)
            frame.rax = @bitCast(cred_mod.getresgid120(frame.rdi, frame.rsi, frame.rdx));
        },
        182 => { // readlink(path, buf, bufsiz)
            frame.rax = @bitCast(readlink_mod.readlink(frame.rdi, frame.rsi, frame.rdx));
        },
        183 => { // statx(dirfd, pathname, flags, mask, statxbuf)
            frame.rax = @bitCast(statx_mod.statx(frame.rsi, frame.r8));
        },
        184 => { // copy_file_range(fd_in, off_in, fd_out, off_out, len, flags)
            _ = frame.r9;
            frame.rax = @bitCast(cfr_mod.copyFileRange(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx), frame.r10, frame.r8));
            checkSignalsOnSyscallReturn(frame);
        },
        185 => { // flock(fd, operation)
            frame.rax = @bitCast(flock_mod.sysFlock(frame.rdi, frame.rsi));
        },
        // ── v31.3: POSIX MQ / POSIX Timer ─────────────────────────
        186 => { // mq_open(name, oflag, mode, attr)
            frame.rax = @bitCast(mq_mod.mqOpen(frame.rdi, @truncate(frame.rsi), @truncate(frame.rdx), frame.r10));
        },
        187 => { // mq_unlink(name)
            frame.rax = @bitCast(mq_mod.mqUnlink(frame.rdi));
        },
        188 => { // mq_timedsend(mqd, msg_ptr, msg_len, msg_prio, abs_timeout)
            frame.rax = @bitCast(mq_mod.mqTimedSend(@truncate(frame.rdi), frame.rsi, frame.rdx, @truncate(frame.r10), frame.r8));
        },
        189 => { // mq_timedreceive(mqd, msg_ptr, msg_len, msg_prio, abs_timeout)
            frame.rax = @bitCast(mq_mod.mqTimedReceive(@truncate(frame.rdi), frame.rsi, frame.rdx, frame.r10, frame.r8));
        },
        190 => { // mq_notify(mqd, notification)
            frame.rax = @bitCast(mq_mod.mqNotify(@truncate(frame.rdi), frame.rsi));
        },
        191 => { // mq_getsetattr(mqd, newattr, oldattr)
            frame.rax = @bitCast(mq_mod.mqGetSetAttr(@truncate(frame.rdi), frame.rsi, frame.rdx));
        },
        192 => { // timer_create(clockid, sevp, timerid)
            frame.rax = @bitCast(ptimer_mod.timerCreate(@truncate(frame.rdi), frame.rsi, frame.rdx));
        },
        193 => { // timer_settime(timerid, flags, new_value, old_value)
            frame.rax = @bitCast(ptimer_mod.timerSettime(@truncate(frame.rdi), @truncate(frame.rsi), frame.rdx, frame.r10));
        },
        194 => { // timer_gettime(timerid, curr_value)
            frame.rax = @bitCast(ptimer_mod.timerGettime(@truncate(frame.rdi), frame.rsi));
        },
        195 => { // timer_getoverrun(timerid)
            frame.rax = @bitCast(ptimer_mod.timerGetoverrun(@truncate(frame.rdi)));
        },
        196 => { // timer_delete(timerid)
            frame.rax = @bitCast(ptimer_mod.timerDelete(@truncate(frame.rdi)));
        },
        // ── v31.4: lseek/access/nanosleep/sched_yield ─────────────
        197 => { // lseek(fd, offset, whence)
            frame.rax = @bitCast(syscallLseek(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx)));
        },
        198 => { // access(pathname, mode)
            frame.rax = @bitCast(syscallAccess(frame.rdi, @truncate(frame.rsi)));
        },
        199 => { // nanosleep(req, rem)
            frame.rax = @bitCast(syscallNanosleep(frame.rdi, frame.rsi));
            checkSignalsOnSyscallReturn(frame);
        },
        200 => { // sched_yield()
            const sched = @import("../../proc/sched.zig");
            sched.forceReschedule();
            frame.rax = 0;
        },
        // ── v31.5: getuid/getgid/geteuid/getegid/getppid ──────────
        201 => { // getuid()
            const sched = @import("../../proc/sched.zig");
            const tm = @import("../../proc/task.zig");
            if (sched.currentTaskIndex()) |idx| {
                if (tm.getTask(idx)) |t| {
                    frame.rax = t.uid;
                } else {
                    frame.rax = 0;
                }
            } else {
                frame.rax = 0;
            }
        },
        202 => { // getgid()
            const sched = @import("../../proc/sched.zig");
            const tm = @import("../../proc/task.zig");
            if (sched.currentTaskIndex()) |idx| {
                if (tm.getTask(idx)) |t| {
                    frame.rax = t.gid;
                } else {
                    frame.rax = 0;
                }
            } else {
                frame.rax = 0;
            }
        },
        203 => { // geteuid()
            const sched = @import("../../proc/sched.zig");
            const tm = @import("../../proc/task.zig");
            if (sched.currentTaskIndex()) |idx| {
                if (tm.getTask(idx)) |t| {
                    frame.rax = t.euid;
                } else {
                    frame.rax = 0;
                }
            } else {
                frame.rax = 0;
            }
        },
        204 => { // getegid()
            const sched = @import("../../proc/sched.zig");
            const tm = @import("../../proc/task.zig");
            if (sched.currentTaskIndex()) |idx| {
                if (tm.getTask(idx)) |t| {
                    frame.rax = t.egid;
                } else {
                    frame.rax = 0;
                }
            } else {
                frame.rax = 0;
            }
        },
        205 => { // getppid()
            const sched = @import("../../proc/sched.zig");
            const tm = @import("../../proc/task.zig");
            if (sched.currentTaskIndex()) |idx| {
                if (tm.getTask(idx)) |t| {
                    frame.rax = t.parent_tid;
                } else {
                    frame.rax = 0;
                }
            } else {
                frame.rax = 0;
            }
        },
        // ── v31.6: setsid/setpgid/getpgid/getsid ──────────────────
        206 => { // setsid()
            frame.rax = @bitCast(syscallSetsid());
        },
        207 => { // setpgid(pid, pgid)
            frame.rax = @bitCast(syscallSetpgid(@truncate(frame.rdi), @truncate(frame.rsi)));
        },
        208 => { // getpgid(pid)
            frame.rax = @bitCast(syscallGetpgid(@truncate(frame.rdi)));
        },
        209 => { // getsid(pid)
            frame.rax = @bitCast(syscallGetsid(@truncate(frame.rdi)));
        },
        // ── v31.7: truncate/ftruncate/rename ───────────────────────
        210 => { // truncate(path, length)
            frame.rax = @bitCast(syscallTruncate(frame.rdi, frame.rsi));
            checkSignalsOnSyscallReturn(frame);
        },
        211 => { // ftruncate(fd, length)
            frame.rax = @bitCast(syscallFtruncate(@truncate(frame.rdi), frame.rsi));
            checkSignalsOnSyscallReturn(frame);
        },
        212 => { // rename(oldpath, newpath)
            frame.rax = @bitCast(syscallRename(frame.rdi, frame.rsi));
        },
        // ── v32.0: AIO ─────────────────────────────────────────────
        213 => { // io_setup(nr_events, ctx_id_ptr)
            frame.rax = @bitCast(aio_mod.ioSetup(frame.rdi, frame.rsi));
        },
        214 => { // io_destroy(ctx_id)
            frame.rax = @bitCast(aio_mod.ioDestroy(frame.rdi));
        },
        215 => { // io_submit(ctx_id, nr, iocbpp)
            frame.rax = @bitCast(aio_mod.ioSubmit(frame.rdi, frame.rsi, frame.rdx));
            checkSignalsOnSyscallReturn(frame);
        },
        216 => { // io_getevents(ctx_id, min_nr, nr, events, timeout)
            frame.rax = @bitCast(aio_mod.ioGetevents(frame.rdi, frame.rsi, frame.rdx, frame.r10, frame.r8));
        },
        217 => { // io_cancel(ctx_id, iocb, result)
            frame.rax = @bitCast(aio_mod.ioCancel(frame.rdi, frame.rsi, frame.rdx));
        },
        // ── v32.1: Signal extensions ─────────────────────────────────
        218 => { // sigaltstack(ss, old_ss)
            frame.rax = @bitCast(signal_syscall_mod.sigaltstack(frame.rdi, frame.rsi));
        },
        219 => { // rt_sigpending(set, sigsetsize)
            frame.rax = @bitCast(signal_syscall_mod.rtSigpending(frame.rdi, frame.rsi));
        },
        220 => { // rt_sigsuspend(mask, sigsetsize)
            frame.rax = @bitCast(signal_syscall_mod.rtSigsuspend(frame.rdi, frame.rsi));
        },
        221 => { // rt_sigtimedwait(sigset, info, timeout, sigsetsize)
            frame.rax = @bitCast(signal_syscall_mod.rtSigtimedwait(frame.rdi, frame.rsi, frame.rdx, frame.r10));
        },
        222 => { // rt_sigqueueinfo(tgid, sig, uinfo)
            frame.rax = @bitCast(signal_syscall_mod.rtSigqueueinfo(@truncate(frame.rdi), @truncate(frame.rsi), frame.rdx));
        },
        223 => { // tkill(tid, sig)
            frame.rax = @bitCast(signal_syscall_mod.tkill(@truncate(frame.rdi), @truncate(frame.rsi)));
        },
        224 => { // pidfd_send_signal(pidfd, sig, info, flags)
            frame.rax = @bitCast(signal_syscall_mod.pidfdSendSignal(@truncate(frame.rdi), @truncate(frame.rsi), frame.rdx, @truncate(frame.r10)));
        },
        225 => { // signalfd4(old_fd, mask, sizemask, flags)
            frame.rax = @bitCast(signal_syscall_mod.signalfd4(frame.rdi, frame.rsi, frame.rdx, frame.r10));
        },
        226 => { // rt_tgsigqueueinfo(tgid, tid, sig, uinfo)
            frame.rax = @bitCast(signal_syscall_mod.rtTgsigqueueinfo(@truncate(frame.rdi), @truncate(frame.rsi), @truncate(frame.rdx), frame.r10));
        },
        // ── v32.2: Misc syscalls ─────────────────────────────────────
        227 => { // sched_getaffinity(pid, cpusetsize, mask)
            frame.rax = @bitCast(misc_mod.schedGetaffinity(@truncate(frame.rdi), frame.rsi, frame.rdx));
        },
        229 => { // getcomm(buf, size)
            frame.rax = @bitCast(misc_mod.getcomm(frame.rdi, frame.rsi));
        },
        230 => { // closefrom(lowfd)
            frame.rax = @bitCast(misc_mod.closefrom(@truncate(frame.rdi)));
        },
        231 => { // move_pages(pid, count, pages, nodes, status, flags)
            frame.rax = @bitCast(misc_mod.movePages(frame.rsi, frame.r8));
        },
        // ── v32.3: Priority / fchdir ─────────────────────────────────
        232 => { // getpriority(which, who)
            const sched = @import("../../proc/sched.zig");
            frame.rax = @bitCast(sched.sysGetpriority(frame.rdi, frame.rsi));
        },
        233 => { // setpriority(which, who, prio)
            const sched = @import("../../proc/sched.zig");
            frame.rax = @bitCast(sched.sysSetpriority(frame.rdi, frame.rsi, @bitCast(frame.rdx)));
        },
        234 => { // fchdir(fd)
            frame.rax = @bitCast(chdir_mod.fchdir(@truncate(frame.rdi)));
        },
        // ── v32.4: madvise / getrlimit / setrlimit / AF_UNIX socket ──
        235 => { // madvise(addr, length, advice)
            frame.rax = @bitCast(syscallMadvise(frame.rdi, frame.rsi, @truncate(frame.rdx)));
        },
        236 => { // getrlimit(resource, rlim)
            frame.rax = @bitCast(syscallGetrlimit(@truncate(frame.rdi), frame.rsi));
        },
        237 => { // setrlimit(resource, rlim)
            frame.rax = @bitCast(syscallSetrlimit(@truncate(frame.rdi), frame.rsi));
        },
        // ── v32.5: umask / sysinfo / prctl ───────────────────────────
        239 => { // umask(mask)
            frame.rax = @bitCast(syscallUmask(@truncate(frame.rdi)));
        },
        240 => { // sysinfo(info_ptr)
            frame.rax = @bitCast(syscallSysinfo(frame.rdi));
        },
        241 => { // prctl(option, arg2, arg3, arg4, arg5)
            frame.rax = @bitCast(syscallPrctl(frame.rdi, frame.rsi, frame.rdx, frame.r10, frame.r8));
        },
        // ── v33.0: Wire existing modules ─────────────────────────────
        242 => { // getrandom(buf, buflen, flags)
            frame.rax = @bitCast(random_mod.sysGetrandom(frame.rdi, frame.rsi, frame.rdx));
        },
        243 => { // clone(flags, stack, parent_tid, child_tid, tls)
            const regs: clone_mod.ParentRegs = .{
                .rbx = frame.rbx,
                .rcx = frame.rcx,
                .rdx = frame.rdx,
                .rsi = frame.rsi,
                .rdi = frame.rdi,
                .rbp = frame.rbp,
                .r8 = frame.r8,
                .r9 = frame.r9,
                .r10 = frame.r10,
                .r11 = frame.r11,
                .r12 = frame.r12,
                .r13 = frame.r13,
                .r14 = frame.r14,
                .r15 = frame.r15,
            };
            frame.rax = @bitCast(clone_mod.clone(frame.rdi, frame.rsi, frame.rdx, frame.r10, frame.r8, regs));
        },
        // ── v33.1: fsync / fdatasync / sync ──────────────────────────
        244 => { // fsync(fd)
            frame.rax = @bitCast(syscallFsync(@truncate(frame.rdi)));
        },
        245 => { // fdatasync(fd)
            frame.rax = @bitCast(syscallFsync(@truncate(frame.rdi)));
        },
        246 => { // sync()
            // POSIX sync() has no failure return; the result is still consumed
            // so a flush failure is not silently discarded at the call site.
            _ = vfs_mod.syncAll();
            frame.rax = 0;
        },
        // ── v33.2: clock_nanosleep / epoll_pwait / getcpu ────────────
        247 => { // clock_nanosleep(clockid, flags, req, rem)
            frame.rax = @bitCast(syscallClockNanosleep(@truncate(frame.rdi), @truncate(frame.rsi), frame.rdx, frame.r10));
        },
        248 => { // epoll_pwait(epfd, events, maxevents, timeout, sigmask, sigsetsize)
            _ = frame.r8; // sigsetsize
            _ = frame.r9; // sigmask (simplified: same as epoll_wait)
            const epoll_mod = @import("../../net/epoll.zig");
            const epfd_idx: u32 = @truncate(frame.rdi);
            const max_ev: u32 = @truncate(frame.rdx);
            const timeout: i32 = @bitCast(@as(u32, @truncate(frame.r10)));
            frame.rax = @bitCast(@as(i64, epoll_mod.epollWait(epfd_idx, frame.rsi, max_ev, timeout)));
        },
        249 => { // getcpu(cpu*, node*, unused)
            frame.rax = @bitCast(syscallGetcpu(frame.rdi, frame.rsi));
        },
        // ── v33.3: pipe2 / mincore / unsupported user mlock ABI ─────────
        250 => { // pipe2(pipefd, flags)
            frame.rax = @bitCast(syscallPipe2(frame.rdi, @truncate(frame.rsi)));
        },
        251 => { // mincore(addr, length, vec)
            frame.rax = @bitCast(syscallMincore(frame.rdi, frame.rsi, frame.rdx));
        },
        252 => { // mlock(addr, len) — unsupported user page pinning
            frame.rax = @bitCast(syscallMlock(frame.rdi, frame.rsi));
        },
        253 => { // munlock(addr, len) — unsupported user page pinning
            frame.rax = @bitCast(syscallMunlock(frame.rdi, frame.rsi));
        },
        // ── v33.4: msync ─────────────────────────────────────────────
        254 => { // msync(addr, length, flags) — flush dirty mmap pages
            frame.rax = @bitCast(syscallMsync(frame.rdi, frame.rsi, @truncate(frame.rdx)));
        },
        // ── v33.5: *at() variants ────────────────────────────────────
        255 => { // openat(dirfd, pathname, flags, mode)
            _ = frame.rdi; // dirfd: simplified, ignore dirfd, use cwd
            frame.rax = @bitCast(file_io_mod.openWithMode(frame.rsi, @truncate(frame.rdx), @truncate(frame.r10)));
        },
        256 => { // unlinkat(dirfd, pathname, flags)
            _ = frame.rdi;
            frame.rax = @bitCast(unlink_mod.unlink(frame.rsi));
        },
        257 => { // mkdirat(dirfd, pathname, mode)
            _ = frame.rdi;
            frame.rax = @bitCast(dir_ops_mod.mkdirWithMode(frame.rsi, @truncate(frame.rdx)));
        },
        // ── v33.6: more *at() variants ───────────────────────────────
        258 => { // faccessat(dirfd, pathname, mode, flags)
            _ = frame.rdi;
            frame.rax = @bitCast(syscallAccess(frame.rsi, @truncate(frame.rdx)));
        },
        259 => { // readlinkat(dirfd, pathname, buf, bufsiz)
            _ = frame.rdi;
            frame.rax = @bitCast(readlink_mod.readlink(frame.rsi, frame.rdx, frame.r10));
        },
        260 => { // fchmodat(dirfd, pathname, mode, flags) — chmod via path
            const copy = @import("../../mm/copy_from_user.zig");
            const ext2_mod = @import("../../fs/ext2.zig");
            var path_buf: [256]u8 = undefined;
            const pc = copy.copyFromUser(path_buf[0..], @ptrFromInt(frame.rsi), 255);
            if (pc == 0) {
                frame.rax = @bitCast(@as(i64, -14));
                return;
            }
            path_buf[if (pc < 255) pc else 255] = 0;
            var plen: usize = 0;
            while (plen < 256 and path_buf[plen] != 0) : (plen += 1) {}
            // AT_SYMLINK_NOFOLLOW (0x100) — if set, don't follow final symlink
            const flags: u32 = @truncate(frame.r10);
            // Reject unknown flags (only AT_SYMLINK_NOFOLLOW is valid for fchmodat)
            if (flags & ~@as(u32, 0x100) != 0) {
                frame.rax = @bitCast(@as(i64, -22)); // EINVAL
                return;
            }
            if (flags & 0x100 != 0) {
                const inode_num = ext2_mod.walkPathToInodeNoFollow(path_buf[0..plen]) orelse {
                    frame.rax = @bitCast(@as(i64, -2));
                    return;
                };
                frame.rax = @bitCast(ext2_mod.setModeByInode(inode_num, @truncate(frame.rdx)));
            } else {
                frame.rax = @bitCast(ext2_mod.setMode(path_buf[0..plen], @truncate(frame.rdx)));
            }
        },
        261 => { // renameat2(olddirfd, oldpath, newdirfd, newpath, flags)
            _ = frame.rdi;
            _ = frame.rdx;
            _ = frame.r8;
            frame.rax = @bitCast(syscallRename(frame.rsi, frame.r10));
        },
        // ── v34.0: Syscall 补全第四轮 ─────────────────────────────────────
        262 => { // vfork() — delegate to fork (COW semantics via full copy)
            frame.rax = @bitCast(fork_mod.fork(frame));
        },
        263 => { // wait4(pid, status, options, rusage) — extend waitpid
            frame.rax = @bitCast(syscallWait4(frame.rdi, frame.rsi, @truncate(frame.rdx), frame.r10));
        },
        264 => { // sethostname(name, len)
            frame.rax = @bitCast(syscallSethostname(frame.rdi, @truncate(frame.rsi)));
        },
        265 => { // gethostname(name, len)
            frame.rax = @bitCast(syscallGethostname(frame.rdi, @truncate(frame.rsi)));
        },
        266 => { // setdomainname(name, len)
            frame.rax = @bitCast(syscallSetdomainname(frame.rdi, @truncate(frame.rsi)));
        },
        267 => { // getdomainname(name, len)
            frame.rax = @bitCast(syscallGetdomainname(frame.rdi, @truncate(frame.rsi)));
        },
        268 => { // personality(persona) — get/set process personality
            frame.rax = @bitCast(syscallPersonality(@truncate(frame.rdi)));
        },
        269 => { // clock_getres(clockid, res)
            frame.rax = @bitCast(syscallClockGetres(@truncate(frame.rdi), frame.rsi));
        },
        270 => { // clock_settime(clockid, tp) — set wall clock
            frame.rax = @bitCast(syscallClockSettime(@truncate(frame.rdi), frame.rsi));
        },
        271 => { // mlockall(flags) — unsupported user page pinning
            frame.rax = @bitCast(syscallMlockall(@truncate(frame.rdi)));
        },
        272 => { // munlockall() — unsupported user page pinning
            frame.rax = @bitCast(syscallMunlockall());
        },
        273 => { // sched_setaffinity(pid, cpusetsize, mask)
            frame.rax = @bitCast(syscallSchedSetaffinity(@truncate(frame.rdi), @truncate(frame.rsi), frame.rdx));
        },
         274 => { // fallocate(fd, mode, offset, len) — pre-allocate space
             const fd: u32 = @truncate(frame.rdi);
             const mode: u32 = @truncate(frame.rsi);
             const offset = frame.rdx;
             const len = frame.r10;
             const fallocate_policy = @import("../../fs/fallocate_policy.zig");
             const mode_result = fallocate_policy.validate(mode);
             if (mode_result != 0) {
                 frame.rax = @bitCast(mode_result);
             } else {
                 if (offset > 0xFFFF_FFFF or len > 0xFFFF_FFFF or len > 0xFFFF_FFFF - offset) {
                    frame.rax = @bitCast(@as(i64, -22));
                } else {
                    // Default: allocate space by extending file to offset+len
                    const sched = @import("../../proc/sched.zig");
                    const tm = @import("../../proc/task.zig");
                    if (sched.currentTaskIndex()) |cur_idx| {
                        if (tm.getTask(cur_idx)) |t| {
                        if (fd >= t.fd_table.fds.len or t.fd_table.fds[fd].fd_type == .none) {
                            frame.rax = @bitCast(@as(i64, -9)); // EBADF
                        } else if (t.fd_table.fds[fd].fd_type != .ext2_file) {
                            // mode=0 is implemented only by the ext2 extent
                            // path; never reinterpret pipes/devices as files.
                            frame.rax = @bitCast(@as(i64, -95)); // EOPNOTSUPP
                        } else if (!t.fd_table.fds[fd].writable) {
                            frame.rax = @bitCast(@as(i64, -13)); // EACCES
                        } else {
                            const ext2 = @import("../../fs/ext2.zig");
                            const ext2_idx = t.fd_table.fds[fd].ext2_file_idx;
                            if (offset + len > t.fSize_cur) {
                                const sig = @import("../../proc/signal.zig");
                                sig.raiseSelf(sig.SIGXFSZ);
                                frame.rax = @bitCast(@as(i64, -27));
                            } else {
                                const new_size: u32 = @truncate(offset + len);
                                if (ext2.truncateFile(ext2_idx, new_size)) {
                                    frame.rax = 0;
                                } else {
                                    frame.rax = @bitCast(@as(i64, -28)); // ENOSPC
                                }
                            }
                        }
                        } else {
                            frame.rax = @bitCast(@as(i64, -9));
                        }
                    } else {
                        frame.rax = @bitCast(@as(i64, -1));
                    }
                }
             }
            checkSignalsOnSyscallReturn(frame);
        },
        275 => { // posix_fadvise(fd, offset, len, advice) — readahead hints
            frame.rax = @bitCast(syscallPosixFadvise(@truncate(frame.rdi), frame.rsi, frame.rdx, @truncate(frame.r10)));
        },
        276 => { // statfs(path, buf)
            frame.rax = @bitCast(syscallStatfs(frame.rdi, frame.rsi));
        },
        277 => { // fstatfs(fd, buf)
            frame.rax = @bitCast(syscallFstatfs(@truncate(frame.rdi), frame.rsi));
        },
        278 => { // syslog(type, buf, len) — read kernel log
            frame.rax = @bitCast(syscallSyslog(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx)));
        },
        279 => { // reboot(cmd)
            if (!checkCapForCurrent("cap_sys_reboot")) {
                frame.rax = @bitCast(@as(i64, -1)); // EPERM
            } else {
                frame.rax = @bitCast(syscallReboot(@truncate(frame.rdi)));
            }
        },
        280 => { // chroot(path) — set root path
            frame.rax = @bitCast(syscallChroot(frame.rdi));
        },
        281 => { // acct(filename) — no-op (process accounting not supported)
            frame.rax = @bitCast(unsupported_policy.acct());
        },
        // ── v36.0: 性能最优先功能补全 ─────────────────────────────────────
        238 => { // prlimit64(pid, resource, new_limit, old_limit)
            frame.rax = @bitCast(syscallPrlimit64(@truncate(frame.rdi), @truncate(frame.rsi), frame.rdx, frame.r10));
        },
        282 => { // unshare(flags) — namespace unshare (simplified no-op)
            frame.rax = @bitCast(unsupported_policy.unshare());
        },
        283 => { // process_vm_readv(pid, local_iov, liovcnt, remote_iov, riovcnt, flags)
            frame.rax = @bitCast(syscallProcessVmReadv(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx), frame.r10, @truncate(frame.r8)));
        },
        284 => { // process_vm_writev(pid, local_iov, liovcnt, remote_iov, riovcnt, flags)
            frame.rax = @bitCast(syscallProcessVmWritev(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx), frame.r10, @truncate(frame.r8)));
        },
        285 => { // memfd_create(name, flags) — anonymous memory file
            frame.rax = @bitCast(syscallMemfdCreate(frame.rdi, @truncate(frame.rsi)));
        },
        286 => { // get_robust_list(pid, head_ptr, len_ptr)
            frame.rax = @bitCast(syscallGetRobustList(@truncate(frame.rdi), frame.rsi, frame.rdx));
        },
        287 => { // set_robust_list(head, len)
            frame.rax = @bitCast(syscallSetRobustList(frame.rdi, @truncate(frame.rsi)));
        },
        288 => { // mount(source, target, fs_type, flags)
            if (!checkCapForCurrent("cap_sys_mount")) {
                frame.rax = @bitCast(@as(i64, -1)); // EPERM
            } else {
                frame.rax = @bitCast(syscallMount(frame.rdi, frame.rsi, frame.rdx, frame.r10));
            }
        },
        289 => { // umount2(target, flags)
            frame.rax = @bitCast(syscallUmount2(frame.rdi, @truncate(frame.rsi)));
        },
        290 => { // sync_file_range(fd, offset, nbytes, flags) — writeback control
            frame.rax = @bitCast(syscallSyncFileRange(@truncate(frame.rdi), frame.rsi, frame.rdx, @truncate(frame.r10)));
        },
        291 => { // readahead(fd, offset, count) — page cache prefetch
            frame.rax = @bitCast(syscallReadahead(@truncate(frame.rdi), frame.rsi, frame.rdx));
        },
        292 => { // ioprio_set(which, who, ioprio) — set I/O scheduling priority
            frame.rax = @bitCast(syscallIoprioSet(@truncate(frame.rdi), @truncate(frame.rsi), @truncate(frame.rdx)));
        },
        293 => { // ioprio_get(which, who) — get I/O scheduling priority
            frame.rax = @bitCast(syscallIoprioGet(@truncate(frame.rdi), @truncate(frame.rsi)));
        },
        294 => { // vmsplice(fd, iov, nr_segs, flags) — splice user pages into pipe
            frame.rax = @bitCast(syscallVmsplice(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx), @truncate(frame.r10)));
        },
        295 => { // name_to_handle_at(dirfd, path, handle, mount_id, flags) — simplified
            frame.rax = @bitCast(syscallNameToHandleAt(@truncate(frame.rdi), frame.rsi, frame.rdx, frame.r10));
        },
        296 => { // open_by_handle_at(mount_fd, handle, flags) — simplified
            frame.rax = @bitCast(syscallOpenByHandleAt(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx)));
        },
        // ── v37.0: MoQiOS native IPC + 性能优化 ──────────────────────────────
        297 => { // moqipc_create_ep() — create IPC endpoint for current task
            frame.rax = @bitCast(syscallMoqipcCreateEp());
        },
        298 => { // moqipc_destroy_ep(ep) — destroy endpoint
            frame.rax = @bitCast(syscallMoqipcDestroyEp(@truncate(frame.rdi)));
        },
        299 => { // moqipc_send(target_ep, msg_ptr) — send 256-byte message
            frame.rax = @bitCast(syscallMoqipcSend(@truncate(frame.rdi), frame.rsi));
        },
        300 => { // moqipc_recv(ep, msg_ptr) — receive 256-byte message
            frame.rax = @bitCast(syscallMoqipcRecv(@truncate(frame.rdi), frame.rsi));
        },
        301 => { // moqipc_call(target_ep, msg_ptr) — transactional send+reply
            frame.rax = @bitCast(syscallMoqipcCall(@truncate(frame.rdi), frame.rsi));
        },
        302 => { // moqipc_reply(caller_ep, msg_ptr) — reply to caller
            frame.rax = @bitCast(syscallMoqipcReply(@truncate(frame.rdi), frame.rsi));
        },
        303 => { // moqipc_notify(target_ep, bits) — async notification
            frame.rax = @bitCast(syscallMoqipcNotify(@truncate(frame.rdi), frame.rsi));
        },
        304 => { // moqipc_get_notify(ep) — get pending notification bitmap
            frame.rax = @bitCast(syscallMoqipcGetNotify(@truncate(frame.rdi)));
        },
        305 => { // kcmp(pid1, pid2, type, idx1, idx2) — compare process resources
            frame.rax = @bitCast(syscallKcmp(@truncate(frame.rdi), @truncate(frame.rsi), @truncate(frame.rdx), frame.r10, frame.r8));
        },
        306 => { // capget(hdr_ptr, data_ptr) — get process capabilities
            frame.rax = @bitCast(syscallCapget(frame.rdi, frame.rsi));
        },
        307 => { // capset(hdr_ptr, data_ptr) — set process capabilities
            frame.rax = @bitCast(syscallCapset(frame.rdi, frame.rsi));
        },
        308 => { // sched_setattr(pid, attr_ptr, flags) — set scheduling attributes
            frame.rax = @bitCast(syscallSchedSetattr(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx)));
        },
        309 => { // sched_getattr(pid, attr_ptr, size, flags) — get scheduling attributes
            frame.rax = @bitCast(syscallSchedGetattr(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx), @truncate(frame.r10)));
        },
        310 => { // membarrier(cmd, flags, cpu_id) — memory barrier across CPUs
            frame.rax = @bitCast(syscallMembarrier(@truncate(frame.rdi), @truncate(frame.rsi)));
        },
        // ── v38.0: MoQiOS capability + pidfd + modern syscall ────────────────
        311 => { // moqipc_grant_cap(endpoint, rights) — grant IPC capability
            frame.rax = @bitCast(syscallGrantCap(@truncate(frame.rdi), @truncate(frame.rsi)));
        },
        312 => { // moqipc_revoke_cap(cap_slot) — revoke capability
            frame.rax = @bitCast(syscallRevokeCap(@truncate(frame.rdi)));
        },
        313 => { // moqipc_check_cap(endpoint, rights) — check capability
            frame.rax = @bitCast(syscallCheckCap(@truncate(frame.rdi), @truncate(frame.rsi)));
        },
        314 => { // close_range(first, last, flags) — bulk close fd range
            frame.rax = @bitCast(syscallCloseRange(@truncate(frame.rdi), @truncate(frame.rsi), @truncate(frame.rdx)));
        },
        315 => { // pidfd_open(pid, flags) — open pid file descriptor
            frame.rax = @bitCast(syscallPidfdOpen(@truncate(frame.rdi), @truncate(frame.rsi)));
        },
        316 => { // pidfd_send_signal(pidfd, sig, info, flags) — signal via pidfd
            frame.rax = @bitCast(syscallPidfdSendSignal(@truncate(frame.rdi), @truncate(frame.rsi), frame.rdx, @truncate(frame.r10)));
        },
        317 => { // pidfd_getfd(pidfd, targetfd, flags) — steal fd from another process
            frame.rax = @bitCast(syscallPidfdGetfd(@truncate(frame.rdi), @truncate(frame.rsi), @truncate(frame.rdx)));
        },
        318 => { // swapon(path, flags) — enable swap on device
            frame.rax = @bitCast(syscallSwapon(frame.rdi, @truncate(frame.rsi)));
        },
        319 => { // swapoff(path) — disable swap
            frame.rax = @bitCast(syscallSwapoff(frame.rdi));
        },
        320 => { // openat2(dirfd, pathname, how, size) — enhanced open
            frame.rax = @bitCast(syscallOpenat2(frame.rdi, frame.rsi, frame.rdx, frame.r10));
        },
        321 => { // faccessat2(dirfd, pathname, mode, flags) — enhanced access
            _ = frame.rdi;
            frame.rax = @bitCast(syscallAccess(frame.rsi, @truncate(frame.rdx)));
        },
        322 => { // execveat(dirfd, pathname, argv, envp, flags)
            const dirfd: i32 = @bitCast(@as(u32, @truncate(frame.rdi)));
            const flags: u32 = @truncate(frame.r8);
            const AT_FDCWD: i32 = -100;
            if ((dirfd == AT_FDCWD or dirfd == 0) and flags == 0) {
                // Equivalent to execve(pathname, argv, envp) — delegate
                frame.rdi = frame.rsi; // pathname
                frame.rsi = frame.rdx; // argv
                frame.rdx = frame.r10; // envp
                syscallExecve(frame);
                return;
            }
            // v52.0: non-AT_FDCWD dirfd — resolve dir path and concatenate
            if (dirfd > 0 and flags == 0) {
                execveatWithDirfd(frame, dirfd);
                return;
            }
            frame.rax = @bitCast(@as(i64, -38)); // ENOSYS for unsupported flags
        },
        // ── v39.0: Linux standard syscall number aliases (x86_64 ABI) ──────
        // Programs compiled against standard Linux headers use these numbers.
        17 => { // pread64(fd, buf, count, offset)
            frame.rax = @bitCast(file_io_mod.pread(@intCast(frame.rdi), frame.rsi, frame.rdx, frame.r10));
        },
        18 => { // pwrite64(fd, buf, count, offset)
            frame.rax = @bitCast(file_io_mod.pwrite(@intCast(frame.rdi), frame.rsi, frame.rdx, frame.r10));
            checkSignalsOnSyscallReturn(frame);
        },
        19 => { // readv(fd, iov, iovcnt)
            frame.rax = @bitCast(readv_mod.readv(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx)));
        },
        20 => { // writev(fd, iov, iovcnt)
            frame.rax = @bitCast(readv_mod.writev(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx)));
            checkSignalsOnSyscallReturn(frame);
        },
        21 => { // access(pathname, mode)
            frame.rax = @bitCast(syscallAccess(frame.rdi, @truncate(frame.rsi)));
        },
        23 => { // select(nfds, readfds, writefds, exceptfds, timeout)
            frame.rax = @bitCast(select_mod.select(frame.rdi, frame.rsi, frame.rdx, frame.r10, frame.r8));
        },
        24 => { // sched_yield()
            const sched = @import("../../proc/sched.zig");
            sched.forceReschedule();
            frame.rax = 0;
        },
        25 => { // mremap(old_addr, old_size, new_size, flags, new_addr)
            frame.rax = @bitCast(syscallMremap(frame.rdi, frame.rsi, frame.rdx, @truncate(frame.r10), frame.r8));
        },
        26 => { // msync(addr, length, flags)
            frame.rax = @bitCast(syscallMsync(frame.rdi, frame.rsi, @truncate(frame.rdx)));
        },
        27 => { // mincore(addr, length, vec)
            frame.rax = @bitCast(syscallMincore(frame.rdi, frame.rsi, frame.rdx));
        },
        28 => { // madvise(addr, length, advice)
            frame.rax = @bitCast(syscallMadvise(frame.rdi, frame.rsi, @truncate(frame.rdx)));
        },
        32 => { // dup(oldfd)
            frame.rax = @bitCast(syscallDup(@truncate(frame.rdi)));
        },
        35 => { // nanosleep(req, rem)
            frame.rax = @bitCast(syscallNanosleep(frame.rdi, frame.rsi));
        },
        37 => { // alarm(seconds) — set SIGALRM timer
            frame.rax = @bitCast(syscallAlarm(@truncate(frame.rdi)));
        },
        39 => { // getpid()
            frame.rax = @bitCast(proc_mgmt_mod.getpid());
        },
        40 => { // sendfile(out_fd, in_fd, offset_ptr, count)
            frame.rax = @bitCast(splice_mod.sysSendfile(@truncate(frame.rdi), @truncate(frame.rsi), frame.rdx, frame.r10));
            checkSignalsOnSyscallReturn(frame);
        },
        41 => { // socket(domain, type, protocol)
            frame.rax = @bitCast(socket_mod.socket(@truncate(frame.rdi), @truncate(frame.rsi), @truncate(frame.rdx)));
        },
        42 => { // connect(fd, addr, addrlen)
            frame.rax = @bitCast(socket_mod.connect(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx)));
        },
        43 => { // accept(fd, addr, addrlen)
            frame.rax = @bitCast(socket_mod.accept(@truncate(frame.rdi), frame.rsi, frame.rdx));
        },
        44 => { // sendto(fd, buf, len, flags, addr, addrlen)
            frame.rax = @bitCast(socket_mod.sendto(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx), @truncate(frame.r10), frame.r8, @truncate(frame.r9)));
        },
        45 => { // recvfrom(fd, buf, len, flags, addr, addrlen)
            frame.rax = @bitCast(socket_mod.recvfrom(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx), @truncate(frame.r10), frame.r8, @truncate(frame.r9)));
        },
        46 => { // sendmsg(fd, msg, flags)
            frame.rax = @bitCast(socket_mod.sendmsg(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx)));
        },
        47 => { // recvmsg(fd, msg, flags)
            frame.rax = @bitCast(socket_mod.recvmsg(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx)));
        },
        48 => { // shutdown(fd, how)
            frame.rax = @bitCast(socket_mod.shutdown(@truncate(frame.rdi), @truncate(frame.rsi)));
        },
        49 => { // bind(fd, addr, addrlen)
            frame.rax = @bitCast(socket_mod.bind(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx)));
        },
        50 => { // listen(fd, backlog)
            frame.rax = @bitCast(socket_mod.listen(@truncate(frame.rdi), @truncate(frame.rsi)));
        },
        51 => { // getsockname(fd, addr, addrlen)
            frame.rax = @bitCast(socket_mod.getsockname(@truncate(frame.rdi), frame.rsi, frame.rdx));
        },
        52 => { // getpeername(fd, addr, addrlen)
            frame.rax = @bitCast(socket_mod.getpeername(@truncate(frame.rdi), frame.rsi, frame.rdx));
        },
        53 => { // socketpair(domain, type, protocol, sv)
            frame.rax = @bitCast(socket_mod.socketpair(@truncate(frame.rdi), @truncate(frame.rsi), @truncate(frame.rdx), frame.r10));
        },
        54 => { // setsockopt(fd, level, optname, optval, optlen)
            frame.rax = @bitCast(socket_mod.setsockopt(frame.rdi, frame.rsi, frame.rdx, frame.r10, frame.r8));
        },
        55 => { // getsockopt(fd, level, optname, optval, optlen)
            frame.rax = @bitCast(socket_mod.getsockopt(frame.rdi, frame.rsi, frame.rdx, frame.r10, frame.r8));
        },
        56 => { // clone(flags, stack, parent_tid, child_tid, tls)
            const regs56: clone_mod.ParentRegs = .{
                .rbx = frame.rbx,
                .rcx = frame.rcx,
                .rdx = frame.rdx,
                .rsi = frame.rsi,
                .rdi = frame.rdi,
                .rbp = frame.rbp,
                .r8 = frame.r8,
                .r9 = frame.r9,
                .r10 = frame.r10,
                .r11 = frame.r11,
                .r12 = frame.r12,
                .r13 = frame.r13,
                .r14 = frame.r14,
                .r15 = frame.r15,
            };
            frame.rax = @bitCast(clone_mod.clone(frame.rdi, frame.rsi, frame.rdx, frame.r10, frame.r8, regs56));
        },
        58 => { // vfork()
            frame.rax = @bitCast(fork_mod.fork(frame));
        },
        60 => { // exit(status)
            lifecycle_mod.exit(frame.rdi);
        },
        61 => { // wait4(pid, status, options, rusage)
            frame.rax = @bitCast(syscallWait4(frame.rdi, frame.rsi, @truncate(frame.rdx), frame.r10));
        },
        73 => { // flock(fd, operation)
            frame.rax = @bitCast(flock_mod.sysFlock(frame.rdi, frame.rsi));
        },
        74 => { // fsync(fd)
            frame.rax = @bitCast(syscallFsync(@truncate(frame.rdi)));
        },
        75 => { // fdatasync(fd)
            frame.rax = @bitCast(syscallFsync(@truncate(frame.rdi)));
        },
        76 => { // truncate(path, length) — v53.3: real implementation
            const ext2_mod = @import("../../fs/ext2.zig");
            const copy = @import("../../mm/copy_from_user.zig");
            const length: u64 = frame.rsi;
            if (length > 0xFFFFFFFF) { // v53.4: reject lengths that don't fit in u32
                frame.rax = @bitCast(@as(i64, -22)); // EINVAL
                return;
            }
            var path_buf: [256]u8 = undefined;
            const plen = copy.copyFromUser(path_buf[0..], @ptrFromInt(frame.rdi), 255);
            if (plen == 0) {
                frame.rax = @bitCast(@as(i64, -14));
                return;
            } // EFAULT
            const inode_num = ext2_mod.walkPathToInodePublic(path_buf[0..plen]) orelse {
                frame.rax = @bitCast(@as(i64, -2));
                return; // ENOENT
            }; // v53.3: truncate by inode directly, no open_files needed
            if (@import("../../proc/sched.zig").currentTask()) |t| {
                const old_size = ext2_mod.getInodeSize(inode_num) orelse return;
                if (length > old_size and length > t.fSize_cur) {
                    const sig = @import("../../proc/signal.zig");
                    sig.raiseSelf(sig.SIGXFSZ);
                    frame.rax = @bitCast(@as(i64, -27));
                    checkSignalsOnSyscallReturn(frame);
                    return;
                }
            }
            if (!ext2_mod.truncateByInode(inode_num, @truncate(length))) {
                frame.rax = @bitCast(@as(i64, -5)); // EIO
                return;
            }
            frame.rax = 0;
            checkSignalsOnSyscallReturn(frame);
        },
        77 => { // ftruncate(fd, length) — v53.3: call real implementation
            const fd: u32 = @truncate(frame.rdi);
            const result = syscallFtruncate(fd, frame.rsi);
            frame.rax = @bitCast(result);
            checkSignalsOnSyscallReturn(frame);
        },
        79 => { // getcwd(buf, size)
            syscallGetcwd(frame);
        },
        80 => { // chdir(path)
            syscallChdir(frame);
        },
        81 => { // fchdir(fd) — change to directory referenced by fd
            frame.rax = @bitCast(chdir_mod.fchdir(@truncate(frame.rdi)));
        },
        82 => { // rename(oldpath, newpath)
            frame.rax = @bitCast(syscallRename(frame.rdi, frame.rsi));
        },
        83 => { // mkdir(pathname, mode)
            frame.rax = @bitCast(dir_ops_mod.mkdirWithMode(frame.rdi, @truncate(frame.rsi)));
        },
        84 => { // rmdir(pathname) — delegate to unlink for dirs
            frame.rax = @bitCast(unlink_mod.unlink(frame.rdi));
        },
        85 => { // creat(pathname, mode)
            const O_WRONLY: u32 = 0x1;
            const O_CREAT: u32 = 0x40;
            const O_TRUNC: u32 = 0x200;
            frame.rax = @bitCast(file_io_mod.openWithMode(frame.rdi, O_WRONLY | O_CREAT | O_TRUNC, @truncate(frame.rsi)));
        },
        87 => { // unlink(pathname)
            frame.rax = @bitCast(unlink_mod.unlink(frame.rdi));
        },
        89 => { // readlink(path, buf, bufsiz)
            frame.rax = @bitCast(readlink_mod.readlink(frame.rdi, frame.rsi, frame.rdx));
        },
        90 => { // chmod(pathname, mode)
            const copy = @import("../../mm/copy_from_user.zig");
            const ext2_mod = @import("../../fs/ext2.zig");
            var path_buf: [256]u8 = undefined;
            const pc = copy.copyFromUser(path_buf[0..], @ptrFromInt(frame.rdi), 255);
            if (pc == 0) {
                frame.rax = @bitCast(@as(i64, -14));
                return;
            }
            path_buf[if (pc < 255) pc else 255] = 0;
            var plen: usize = 0;
            while (plen < 256 and path_buf[plen] != 0) : (plen += 1) {}
            frame.rax = @bitCast(ext2_mod.setMode(path_buf[0..plen], @truncate(frame.rsi)));
        },
        91 => { // fchmod(fd, mode)
            const ext2_mod = @import("../../fs/ext2.zig");
            const sched_m = @import("../../proc/sched.zig");
            const task_m = @import("../../proc/task.zig");
            const cur_idx = sched_m.currentTaskIndex() orelse {
                frame.rax = @bitCast(@as(i64, -9));
                return;
            };
            const t = task_m.getTask(cur_idx) orelse {
                frame.rax = @bitCast(@as(i64, -9));
                return;
            };
            const fd: u32 = @truncate(frame.rdi);
            if (fd >= vfs_mod.MAX_FDS or t.fd_table.fds[fd].fd_type != .ext2_file) {
                frame.rax = @bitCast(@as(i64, -9));
                return;
            }
            const inode_num = ext2_mod.getInodeNum(t.fd_table.fds[fd].ext2_file_idx);
            frame.rax = @bitCast(ext2_mod.setModeByInode(inode_num, @truncate(frame.rsi)));
        },
        95 => { // umask(mask)
            frame.rax = @bitCast(syscallUmask(@truncate(frame.rdi)));
        },
        97 => { // getrlimit(resource, rlim)
            frame.rax = @bitCast(syscallGetrlimit(@truncate(frame.rdi), frame.rsi));
        },
        98 => { // getrusage(who, usage)
            frame.rax = @bitCast(syscallGetrusage(@truncate(frame.rdi), frame.rsi));
        },
        99 => { // sysinfo(info)
            frame.rax = @bitCast(syscallSysinfo(frame.rdi));
        },
        // ── v39.0: New MoQiOS syscalls (#323-#326) ─────────────────────────
        323 => { // mremap(old_addr, old_size, new_size, flags, new_addr)
            frame.rax = @bitCast(syscallMremap(frame.rdi, frame.rsi, frame.rdx, @truncate(frame.r10), frame.r8));
        },
        324 => { // getrusage(who, usage)
            frame.rax = @bitCast(syscallGetrusage(@truncate(frame.rdi), frame.rsi));
        },
        325 => { // dup(oldfd)
            frame.rax = @bitCast(syscallDup(@truncate(frame.rdi)));
        },
        326 => { // alarm(seconds)
            frame.rax = @bitCast(syscallAlarm(@truncate(frame.rdi)));
        },
        // ── v40.0: Fill remaining Linux standard number gaps ───────────────
        29 => { // shmget(key, size, shmflg)
            const shm_mod = @import("../../ipc/sysv_shm.zig");
            const key: i32 = @bitCast(@as(u32, @truncate(frame.rdi)));
            const shmflg: i32 = @bitCast(@as(u32, @truncate(frame.rdx)));
            frame.rax = @bitCast(shm_mod.shmget(key, frame.rsi, shmflg));
        },
        30 => { // shmat(shmid, shmaddr, shmflg)
            const shm_mod = @import("../../ipc/sysv_shm.zig");
            frame.rax = @bitCast(shm_mod.shmat(@truncate(frame.rdi), frame.rsi, frame.rdx));
        },
        31 => { // shmctl(shmid, cmd, buf)
            const shm_mod = @import("../../ipc/sysv_shm.zig");
            const cmd: i32 = @bitCast(@as(u32, @truncate(frame.rsi)));
            frame.rax = @bitCast(shm_mod.shmctl(@truncate(frame.rdi), cmd, frame.rdx));
        },
        34 => { // pause() — block until signal delivered
            const sched = @import("../../proc/sched.zig");
            sched.forceReschedule();
            frame.rax = @bitCast(@as(i64, -4)); // EINTR: always interrupted
        },
        36 => { // getitimer(which, curr_value)
            frame.rax = @bitCast(syscallGetitimer(@truncate(frame.rdi), frame.rsi));
        },
        38 => { // setitimer(which, new_value, old_value)
            frame.rax = @bitCast(syscallSetitimer(@truncate(frame.rdi), frame.rsi, frame.rdx));
        },
        64 => { // semget(key, nsems, semflg)
            const sem_mod = @import("../../ipc/sysv_sem.zig");
            const key: i32 = @bitCast(@as(u32, @truncate(frame.rdi)));
            const nsems: i32 = @bitCast(@as(u32, @truncate(frame.rsi)));
            const semflg: i32 = @bitCast(@as(u32, @truncate(frame.rdx)));
            frame.rax = @bitCast(sem_mod.semget(key, nsems, semflg));
        },
        65 => { // semop(semid, sops, nsops)
            const sem_mod = @import("../../ipc/sysv_sem.zig");
            const op: i16 = @bitCast(@as(u16, @truncate(frame.rdx)));
            frame.rax = @bitCast(sem_mod.semop(@truncate(frame.rdi), @truncate(frame.rsi), op));
        },
        66 => { // semctl(semid, semnum, cmd, arg)
            const sem_mod = @import("../../ipc/sysv_sem.zig");
            const semnum: i32 = @bitCast(@as(u32, @truncate(frame.rsi)));
            const cmd: i32 = @bitCast(@as(u32, @truncate(frame.rdx)));
            const arg: i32 = @bitCast(@as(u32, @truncate(frame.r10)));
            frame.rax = @bitCast(sem_mod.semctl(@truncate(frame.rdi), semnum, cmd, arg));
        },
        67 => { // shmdt(shmaddr)
            const shm_mod = @import("../../ipc/sysv_shm.zig");
            frame.rax = @bitCast(shm_mod.shmdt(frame.rdi));
        },
        68 => { // msgget(key, msgflg)
            const msg_mod = @import("../../ipc/sysv_msg.zig");
            const key: i32 = @bitCast(@as(u32, @truncate(frame.rdi)));
            const msgflg: i32 = @bitCast(@as(u32, @truncate(frame.rsi)));
            frame.rax = @bitCast(msg_mod.msgget(key, msgflg));
        },
        69 => { // msgsnd(msqid, msgp, msgsz, msgflg)
            const msg_mod = @import("../../ipc/sysv_msg.zig");
            const msgflg: i32 = @bitCast(@as(u32, @truncate(frame.r10)));
            frame.rax = @bitCast(msg_mod.msgsnd(@truncate(frame.rdi), frame.rsi, frame.rdx, msgflg));
        },
        70 => { // msgrcv(msqid, msgp, msgsz, msgtyp, msgflg)
            const msg_mod = @import("../../ipc/sysv_msg.zig");
            const msgflg: i32 = @bitCast(@as(u32, @truncate(frame.r8)));
            frame.rax = @bitCast(msg_mod.msgrcv(@truncate(frame.rdi), frame.rsi, frame.rdx, @bitCast(frame.r10), msgflg));
        },
        71 => { // msgctl(msqid, cmd, buf)
            const msg_mod = @import("../../ipc/sysv_msg.zig");
            const cmd: i32 = @bitCast(@as(u32, @truncate(frame.rsi)));
            frame.rax = @bitCast(msg_mod.msgctl(@truncate(frame.rdi), cmd, frame.rdx));
        },
        72 => { // fcntl(fd, cmd, arg)
            frame.rax = @bitCast(fcntl_mod.sysFcntl(frame.rdi, frame.rsi, frame.rdx));
        },
        78 => { // getdents(fd, dirp, count) — delegate to getdents64
            frame.rax = @bitCast(getdents_mod.getdents64(@truncate(frame.rdi), frame.rsi, frame.rdx));
        },
        86 => { // link(oldpath, newpath) — hard link
            const copy = @import("../../mm/copy_from_user.zig");
            const ext2_mod = @import("../../fs/ext2.zig");
            var old_buf: [256]u8 = undefined;
            var new_buf: [256]u8 = undefined;
            const oc = copy.copyFromUser(old_buf[0..], @ptrFromInt(frame.rdi), 255);
            const nc = copy.copyFromUser(new_buf[0..], @ptrFromInt(frame.rsi), 255);
            if (oc == 0 or nc == 0) {
                frame.rax = @bitCast(@as(i64, -14));
                return;
            }
            old_buf[if (oc < 255) oc else 255] = 0;
            new_buf[if (nc < 255) nc else 255] = 0;
            var ol: usize = 0;
            while (ol < 256 and old_buf[ol] != 0) : (ol += 1) {}
            var nl: usize = 0;
            while (nl < 256 and new_buf[nl] != 0) : (nl += 1) {}
            if (ext2_mod.isActive()) {
                frame.rax = @bitCast(ext2_mod.createHardlink(old_buf[0..ol], new_buf[0..nl]));
            } else {
                frame.rax = @bitCast(@as(i64, -38)); // ENOSYS
            }
        },
        88 => { // symlink(target, linkpath) — symbolic link
            const copy = @import("../../mm/copy_from_user.zig");
            const ext2_mod = @import("../../fs/ext2.zig");
            var tgt_buf: [256]u8 = undefined;
            var lnk_buf: [256]u8 = undefined;
            const tc = copy.copyFromUser(tgt_buf[0..], @ptrFromInt(frame.rdi), 255);
            const lc = copy.copyFromUser(lnk_buf[0..], @ptrFromInt(frame.rsi), 255);
            if (tc == 0 or lc == 0) {
                frame.rax = @bitCast(@as(i64, -14));
                return;
            }
            tgt_buf[if (tc < 255) tc else 255] = 0;
            lnk_buf[if (lc < 255) lc else 255] = 0;
            var tl: usize = 0;
            while (tl < 256 and tgt_buf[tl] != 0) : (tl += 1) {}
            var ll: usize = 0;
            while (ll < 256 and lnk_buf[ll] != 0) : (ll += 1) {}
            if (ext2_mod.isActive()) {
                frame.rax = @bitCast(ext2_mod.createSymlink(tgt_buf[0..tl], lnk_buf[0..ll]));
            } else {
                frame.rax = @bitCast(@as(i64, -38)); // ENOSYS
            }
        },
        92 => { // chown(pathname, owner, group)
            const copy = @import("../../mm/copy_from_user.zig");
            const ext2_mod = @import("../../fs/ext2.zig");
            var path_buf: [256]u8 = undefined;
            const pc = copy.copyFromUser(path_buf[0..], @ptrFromInt(frame.rdi), 255);
            if (pc == 0) {
                frame.rax = @bitCast(@as(i64, -14));
                return;
            }
            path_buf[if (pc < 255) pc else 255] = 0;
            var plen: usize = 0;
            while (plen < 256 and path_buf[plen] != 0) : (plen += 1) {}
            frame.rax = @bitCast(ext2_mod.setOwner(path_buf[0..plen], @truncate(frame.rsi), @truncate(frame.rdx)));
        },
        93 => { // fchown(fd, owner, group)
            const ext2_mod = @import("../../fs/ext2.zig");
            const sched_m = @import("../../proc/sched.zig");
            const task_m = @import("../../proc/task.zig");
            const cur_idx = sched_m.currentTaskIndex() orelse {
                frame.rax = @bitCast(@as(i64, -9));
                return;
            };
            const t = task_m.getTask(cur_idx) orelse {
                frame.rax = @bitCast(@as(i64, -9));
                return;
            };
            const fd: u32 = @truncate(frame.rdi);
            if (fd >= vfs_mod.MAX_FDS or t.fd_table.fds[fd].fd_type != .ext2_file) {
                frame.rax = @bitCast(@as(i64, -9));
                return;
            }
            const inode_num = ext2_mod.getInodeNum(t.fd_table.fds[fd].ext2_file_idx);
            frame.rax = @bitCast(ext2_mod.setOwnerByInode(inode_num, @truncate(frame.rsi), @truncate(frame.rdx)));
        },
        94 => { // lchown(pathname, owner, group) — does NOT follow symlink
            const copy = @import("../../mm/copy_from_user.zig");
            const ext2_mod = @import("../../fs/ext2.zig");
            var path_buf: [256]u8 = undefined;
            const pc = copy.copyFromUser(path_buf[0..], @ptrFromInt(frame.rdi), 255);
            if (pc == 0) {
                frame.rax = @bitCast(@as(i64, -14));
                return;
            }
            path_buf[if (pc < 255) pc else 255] = 0;
            var plen: usize = 0;
            while (plen < 256 and path_buf[plen] != 0) : (plen += 1) {}
            frame.rax = @bitCast(ext2_mod.setOwnerNoFollow(path_buf[0..plen], @truncate(frame.rsi), @truncate(frame.rdx)));
        },
        // ── v40.0: New MoQiOS syscalls (#327-#330) ─────────────────────────
        327 => { // getitimer(which, curr_value)
            frame.rax = @bitCast(syscallGetitimer(@truncate(frame.rdi), frame.rsi));
        },
        328 => { // setitimer(which, new_value, old_value)
            frame.rax = @bitCast(syscallSetitimer(@truncate(frame.rdi), frame.rsi, frame.rdx));
        },
        329 => { // link(oldpath, newpath) — same as #86
            const copy = @import("../../mm/copy_from_user.zig");
            const ext2_mod = @import("../../fs/ext2.zig");
            var old_buf: [256]u8 = undefined;
            var new_buf: [256]u8 = undefined;
            const oc = copy.copyFromUser(old_buf[0..], @ptrFromInt(frame.rdi), 255);
            const nc = copy.copyFromUser(new_buf[0..], @ptrFromInt(frame.rsi), 255);
            if (oc == 0 or nc == 0) {
                frame.rax = @bitCast(@as(i64, -14));
                return;
            }
            old_buf[if (oc < 255) oc else 255] = 0;
            new_buf[if (nc < 255) nc else 255] = 0;
            var ol: usize = 0;
            while (ol < 256 and old_buf[ol] != 0) : (ol += 1) {}
            var nl: usize = 0;
            while (nl < 256 and new_buf[nl] != 0) : (nl += 1) {}
            frame.rax = @bitCast(ext2_mod.createHardlink(old_buf[0..ol], new_buf[0..nl]));
        },
        330 => { // symlink(target, linkpath) — same as #88
            const copy = @import("../../mm/copy_from_user.zig");
            const ext2_mod = @import("../../fs/ext2.zig");
            var tgt_buf: [256]u8 = undefined;
            var lnk_buf: [256]u8 = undefined;
            const tc = copy.copyFromUser(tgt_buf[0..], @ptrFromInt(frame.rdi), 255);
            const lc = copy.copyFromUser(lnk_buf[0..], @ptrFromInt(frame.rsi), 255);
            if (tc == 0 or lc == 0) {
                frame.rax = @bitCast(@as(i64, -14));
                return;
            }
            tgt_buf[if (tc < 255) tc else 255] = 0;
            lnk_buf[if (lc < 255) lc else 255] = 0;
            var tl: usize = 0;
            while (tl < 256 and tgt_buf[tl] != 0) : (tl += 1) {}
            var ll: usize = 0;
            while (ll < 256 and lnk_buf[ll] != 0) : (ll += 1) {}
            frame.rax = @bitCast(ext2_mod.createSymlink(tgt_buf[0..tl], lnk_buf[0..ll]));
        },
        // ── v42.0: Linux standard number aliases (331+) + new implementations ──
        331 => { // statx(dirfd, pathname, flags, mask, statxbuf) — alias of #183
            frame.rax = @bitCast(statx_mod.statx(frame.rsi, frame.r8));
        },
        332 => { // io_pgetevents(ctx_id, min_nr, nr, events, timeout, usig) — alias of #216
            frame.rax = @bitCast(aio_mod.ioGetevents(frame.rdi, frame.rsi, frame.rdx, frame.r10, frame.r8));
        },
        333 => { // rseq(rseq, rseq_len, flags, sig) — restartable sequences
            // v53.6: Return ENOSYS so glibc falls back to non-rseq path instead of relying on unimplemented semantics
            frame.rax = @bitCast(@as(i64, -38)); // -ENOSYS
        },
        334 => { // pidfd_send_signal(pidfd, sig, info, flags) — alias of #316
            frame.rax = @bitCast(syscallPidfdSendSignal(@truncate(frame.rdi), @truncate(frame.rsi), frame.rdx, @truncate(frame.r10)));
        },
        424 => { // pidfd_send_signal(pidfd, sig, info, flags) — Linux standard #424
            frame.rax = @bitCast(syscallPidfdSendSignal(@truncate(frame.rdi), @truncate(frame.rsi), frame.rdx, @truncate(frame.r10)));
        },
        425 => { // io_uring_setup(entries, params) — Linux standard #425 (ENOSYS)
            frame.rax = @bitCast(@as(i64, -38)); // ENOSYS: io_uring not yet supported
        },
        426 => { // io_uring_enter(fd, to_submit, min_complete, flags, sig) — Linux #426
            frame.rax = @bitCast(@as(i64, -38)); // ENOSYS
        },
        427 => { // io_uring_register(fd, opcode, arg, nr_args) — Linux #427
            frame.rax = @bitCast(@as(i64, -38)); // ENOSYS
        },
        428 => { // open_tree(dfd, path, flags) — new mount API — Linux #428
            frame.rax = @bitCast(@as(i64, -38)); // ENOSYS
        },
        429 => { // move_mount(from_dfd, from_path, to_dfd, to_path, flags) — Linux #429
            frame.rax = @bitCast(@as(i64, -38)); // ENOSYS
        },
        430 => { // fsopen(fs_name, flags) — open filesystem context — Linux #430
            frame.rax = @bitCast(@as(i64, -38)); // ENOSYS
        },
        431 => { // fsconfig(fd, cmd, key, value, aux) — Linux #431
            frame.rax = @bitCast(@as(i64, -38)); // ENOSYS
        },
        432 => { // fsmount(fs_fd, flags, attr_flags) — create mount from context — Linux #432
            frame.rax = @bitCast(@as(i64, -38)); // ENOSYS
        },
        433 => { // fspick(dfd, path, flags) — pick existing mount for reconfig — Linux #433
            frame.rax = @bitCast(@as(i64, -38)); // ENOSYS
        },
        434 => { // pidfd_open(pid, flags) — alias of #315
            frame.rax = @bitCast(syscallPidfdOpen(@truncate(frame.rdi), @truncate(frame.rsi)));
        },
        435 => { // clone3(cl_args, size) — read clone_args struct, delegate to clone
            const clone_args_ptr = frame.rdi;
            if (clone_args_ptr == 0 or clone_args_ptr >= 0x0000_8000_0000_0000) {
                frame.rax = @bitCast(@as(i64, -14)); // EFAULT
            } else {
                // struct clone_args { flags:u64, pidfd:u64, child_tid:u64, parent_tid:u64,
                //   exit_signal:u64, stack:u64, stack_size:u64, tls:u64, set_tid:u64,
                //   set_tid_size:u64, cgroup:u64 }
                const copy = @import("../../mm/copy_from_user.zig");
                const bo = @import("../../lib/byte_order.zig");
                var buf: [88]u8 = undefined;
                const n = copy.copyFromUser(&buf, @ptrFromInt(clone_args_ptr), 88);
                if (n < 64) {
                    frame.rax = @bitCast(@as(i64, -22)); // EINVAL
                } else {
                    const flags = bo.readU64Le(buf[0..8]);
                    const stack_ptr = bo.readU64Le(buf[40..48]);
                    const parent_tid = bo.readU64Le(buf[24..32]);
                    const child_tid = bo.readU64Le(buf[16..24]);
                    const tls = bo.readU64Le(buf[56..64]);
                    const regs: clone_mod.ParentRegs = .{
                        .rbx = frame.rbx,
                        .rcx = frame.rcx,
                        .rdx = frame.rdx,
                        .rsi = frame.rsi,
                        .rdi = frame.rdi,
                        .rbp = frame.rbp,
                        .r8 = frame.r8,
                        .r9 = frame.r9,
                        .r10 = frame.r10,
                        .r11 = frame.r11,
                        .r12 = frame.r12,
                        .r13 = frame.r13,
                        .r14 = frame.r14,
                        .r15 = frame.r15,
                    };
                    frame.rax = @bitCast(clone_mod.clone(flags, stack_ptr, parent_tid, child_tid, tls, regs));
                }
            }
        },
        436 => { // close_range(first, last, flags) — alias of #314
            frame.rax = @bitCast(syscallCloseRange(@truncate(frame.rdi), @truncate(frame.rsi), @truncate(frame.rdx)));
        },
        437 => { // openat2(dirfd, pathname, how, size) — alias of #320
            frame.rax = @bitCast(syscallOpenat2(frame.rdi, frame.rsi, frame.rdx, frame.r10));
        },
        438 => { // pidfd_getfd(pidfd, targetfd, flags) — alias of #317 (dup)
            frame.rax = @bitCast(syscallPidfdGetfd(@truncate(frame.rdi), @truncate(frame.rsi), @truncate(frame.rdx)));
        },
        439 => { // faccessat2(dirfd, pathname, mode, flags) — alias of #321 (dup)
            _ = frame.rdi;
            frame.rax = @bitCast(syscallAccess(frame.rsi, @truncate(frame.rdx)));
        },
        440 => { // process_madvise(pidfd, iov, nr_iov, advice, flags) — Linux #440
            frame.rax = @bitCast(unsupported_policy.processMadvise());
        },
        441 => { // epoll_pwait2(epfd, events, maxevents, timeout_ts, sigmask, sigsetsize)
            const epoll_mod2 = @import("../../net/epoll.zig");
            const epfd_idx: u32 = @truncate(frame.rdi);
            const max_ev: u32 = @truncate(frame.rdx);
            const timeout_ts_ptr = frame.r10;
            // Convert timespec (tv_sec, tv_nsec) to milliseconds
            var timeout_ms: i32 = -1; // infinite
            if (timeout_ts_ptr != 0 and timeout_ts_ptr < 0x0000_8000_0000_0000) {
                const copy2 = @import("../../mm/copy_from_user.zig");
                const bo2 = @import("../../lib/byte_order.zig");
                var ts_buf: [16]u8 = undefined;
                const ts_n = copy2.copyFromUser(&ts_buf, @ptrFromInt(timeout_ts_ptr), 16);
                if (ts_n >= 16) {
                    const tv_sec: i64 = @bitCast(bo2.readU64Le(ts_buf[0..8]));
                    const tv_nsec: i64 = @bitCast(bo2.readU64Le(ts_buf[8..16]));
                    timeout_ms = @intCast(@min(@max(tv_sec * 1000 + @divTrunc(tv_nsec, 1_000_000), 0), 0x7FFFFFFF));
                }
            }
            _ = frame.r8; // sigmask ignored
            _ = frame.r9; // sigsetsize ignored
            frame.rax = @bitCast(@as(i64, epoll_mod2.epollWait(epfd_idx, frame.rsi, max_ev, timeout_ms)));
        },
        // ── v45.0: Linux standard 424+ corrected numbering ──────────────────
        // (v44.0 #335-#343 were wrong MoQiOS custom numbers; deleted in v45.0)
        442 => { // mount_setattr(dfd, path, flags, attr, size)
            frame.rax = 0; // accept
        },
        443 => { // quotactl_fd(fd, cmd, id, addr) — disk quota control
            frame.rax = 0; // accept (no quota enforcement)
        },
        444 => { // landlock_create_ruleset(attr, size, flags) — Linux #444
            frame.rax = @bitCast(unsupported_policy.landlock());
        },
        445 => { // landlock_add_rule(ruleset_fd, rule_type, rule_attr, size) — Linux #445
            frame.rax = @bitCast(unsupported_policy.landlock());
        },
        446 => { // landlock_restrict_self(ruleset_fd, flags) — Linux #446
            frame.rax = @bitCast(unsupported_policy.landlock());
        },
        447 => { // memfd_secret(flags) — create secret memfd — Linux #447
            frame.rax = @bitCast(@as(i64, -38)); // ENOSYS (requires special page isolation)
        },
        448 => { // process_mrelease(pidfd, flags) — release dying process memory — Linux #448
            _ = frame.rdi; // pidfd
            _ = frame.rsi; // flags
            frame.rax = 0; // accept (kernel reaps zombies automatically)
        },
        449 => { // futex_waitv(waiters, nr_waiters, flags, timeout, clockid)
            _ = frame.rdx; // flags
            _ = frame.r10; // timeout
            _ = frame.r8; // clockid
            frame.rax = @bitCast(futex_mod.futexWaitv(frame.rdi, frame.rsi));
        },
        450 => { // set_mempolicy_home_node(start, len, home_node, flags) — Linux #450
            frame.rax = 0; // accept (no NUMA support)
        },
        451 => { // cachestat(fd, cachestat_range, cachestat, flags)
            frame.rax = @bitCast(syscallCachestat(@truncate(frame.rdi), frame.rsi, frame.rdx, @truncate(frame.r10)));
        },
        452 => { // fchmodat2(dfd, filename, mode, flags) — Linux #452
            const copy = @import("../../mm/copy_from_user.zig");
            const ext2_mod = @import("../../fs/ext2.zig");
            _ = frame.rdi; // dfd (AT_FDCWD or dirfd — simplified)
            var path_buf: [256]u8 = undefined;
            const pc = copy.copyFromUser(path_buf[0..], @ptrFromInt(frame.rsi), 255);
            if (pc == 0) {
                frame.rax = @bitCast(@as(i64, -14));
                return;
            }
            path_buf[if (pc < 255) pc else 255] = 0;
            var plen: usize = 0;
            while (plen < 256 and path_buf[plen] != 0) : (plen += 1) {}
            // v52.4: flags handling consistent with fchmodat #260
            const flags: u32 = @truncate(frame.r10);
            if (flags & ~@as(u32, 0x100) != 0) {
                frame.rax = @bitCast(@as(i64, -22)); // EINVAL
                return;
            }
            if (flags & 0x100 != 0) {
                const inode_num = ext2_mod.walkPathToInodeNoFollow(path_buf[0..plen]) orelse {
                    frame.rax = @bitCast(@as(i64, -2));
                    return;
                };
                frame.rax = @bitCast(ext2_mod.setModeByInode(inode_num, @truncate(frame.rdx)));
            } else {
                frame.rax = @bitCast(ext2_mod.setMode(path_buf[0..plen], @truncate(frame.rdx)));
            }
        },
        453 => { // map_shadow_stack(addr, size, flags) — Linux #453
            frame.rax = @bitCast(@as(i64, -38)); // ENOSYS (requires CET-SS support)
        },
        454 => { // futex_wake(futex, val, mask) — Linux #454 (new futex2 API)
            // Delegate to old futex() with FUTEX_WAKE (op=1)
            frame.rax = @bitCast(futex_mod.futex(frame.rdi, 1, @truncate(frame.rsi), 0, 0, 0));
        },
        455 => { // futex_wait(futex, val, timeout, flags) — Linux #455 (new futex2 API)
            // Delegate to old futex() with FUTEX_WAIT (op=0)
            frame.rax = @bitCast(futex_mod.futex(frame.rdi, 0, @truncate(frame.rsi), @bitCast(frame.rdx), 0, 0));
        },
        456 => { // futex_requeue(futex1, futex2, nr_wake, nr_requeue) — Linux #456
            // Delegate to old futex() with FUTEX_REQUEUE (op=3)
            // v53.44: Fixed param mapping — futex2_requeue(futex1=rdi, futex2=rsi, nr_wake=rdx, nr_requeue=r10)
            frame.rax = @bitCast(futex_mod.futex(frame.rdi, 3, frame.rdx, frame.r10, frame.rsi, 0));
        },
        457 => { // statmount(mnt_id, buf, bufsize, flags) — query mount info — Linux #457
            frame.rax = @bitCast(@as(i64, -38)); // ENOSYS (mount info not tracked)
        },
        458 => { // listmount(mnt_id, last_mnt_id, buf, bufsize, flags) — Linux #458
            frame.rax = @bitCast(@as(i64, -38)); // ENOSYS
        },
        459 => { // lsm_get_self_attr(attr, ptr, size, flags) — Linux #459
            frame.rax = @bitCast(unsupported_policy.lsm());
        },
        460 => { // lsm_set_self_attr(attr, ptr, size, flags) — Linux #460
            frame.rax = @bitCast(unsupported_policy.lsm());
        },
        461 => { // lsm_list_modules(ids, size, flags) — Linux #461
            frame.rax = @bitCast(unsupported_policy.lsm());
        },
        462 => { // mseal(addr, len, flags) — seal memory mapping — Linux #462
            // Mark mmap region as sealed (prevent mprotect/munmap/mremap)
            const addr = frame.rdi;
            const len = frame.rsi;
            if (addr == 0 or addr >= 0x0000_8000_0000_0000) {
                frame.rax = @bitCast(@as(i64, -14)); // EFAULT
            } else {
                // Accept sealing — record in mmap region (simplified: just accept)
                _ = len;
                frame.rax = 0;
            }
        },
        // ── v52.0: xattr-at real implementation ────────────────────────────────
        463 => { // setxattrat(dfd, path, flags, name, value, size)
            const copy = @import("../../mm/copy_from_user.zig");
            const ext2_mod = @import("../../fs/ext2.zig");
            _ = frame.rdi; // dfd
            _ = frame.rdx; // flags
            // Copy path
            var path_buf: [256]u8 = undefined;
            const pc = copy.copyFromUser(path_buf[0..], @ptrFromInt(frame.rsi), 255);
            if (pc == 0) {
                frame.rax = @bitCast(@as(i64, -14));
                return;
            }
            path_buf[if (pc < 255) pc else 255] = 0;
            var plen: usize = 0;
            while (plen < 256 and path_buf[plen] != 0) : (plen += 1) {}
            // Copy name (skip "user." prefix if present)
            var name_buf: [256]u8 = undefined;
            const nc = copy.copyFromUser(name_buf[0..], @ptrFromInt(frame.r10), 255);
            if (nc == 0) {
                frame.rax = @bitCast(@as(i64, -14));
                return;
            }
            name_buf[if (nc < 255) nc else 255] = 0;
            var nlen: usize = 0;
            while (nlen < 256 and name_buf[nlen] != 0) : (nlen += 1) {}
            var actual_name = name_buf[0..nlen];
            if (nlen >= 5 and name_buf[0] == 'u' and name_buf[1] == 's' and name_buf[2] == 'e' and name_buf[3] == 'r' and name_buf[4] == '.') {
                actual_name = name_buf[5..nlen];
            } else if (nlen >= 1) {
                // v52.4: reject non-"user." namespace (only user xattr supported)
                frame.rax = @bitCast(@as(i64, -1)); // EPERM
                return;
            }
            // Copy value (v52.6: vsize==0 is legal — flag-only xattr)
            const vsize: u32 = @truncate(frame.r8);
            // v52.9: reject values larger than our buffer (prevent silent truncation)
            if (vsize > 4096) {
                frame.rax = @bitCast(@as(i64, -7)); // E2BIG
                return;
            }
            var val_buf: [4096]u8 = undefined;
            const vc = if (vsize == 0) @as(u32, 0) else copy.copyFromUser(val_buf[0..], @ptrFromInt(frame.r9), vsize);
            if (vsize > 0 and vc == 0) {
                frame.rax = @bitCast(@as(i64, -14));
                return;
            }
            // Resolve path to inode and set xattr
            const inode_num = ext2_mod.walkPathToInodePublic(path_buf[0..plen]) orelse {
                frame.rax = @bitCast(@as(i64, -2));
                return;
            };
            frame.rax = @bitCast(ext2_mod.setXattr(inode_num, actual_name, val_buf[0..vc]));
        },
        464 => { // getxattrat(dfd, path, flags, name, value, size)
            const copy = @import("../../mm/copy_from_user.zig");
            const ext2_mod = @import("../../fs/ext2.zig");
            _ = frame.rdi; // dfd
            _ = frame.rdx; // flags
            var path_buf: [256]u8 = undefined;
            const pc = copy.copyFromUser(path_buf[0..], @ptrFromInt(frame.rsi), 255);
            if (pc == 0) {
                frame.rax = @bitCast(@as(i64, -14));
                return;
            }
            path_buf[if (pc < 255) pc else 255] = 0;
            var plen: usize = 0;
            while (plen < 256 and path_buf[plen] != 0) : (plen += 1) {}
            var name_buf: [256]u8 = undefined;
            const nc = copy.copyFromUser(name_buf[0..], @ptrFromInt(frame.r10), 255);
            if (nc == 0) {
                frame.rax = @bitCast(@as(i64, -14));
                return;
            }
            name_buf[if (nc < 255) nc else 255] = 0;
            var nlen: usize = 0;
            while (nlen < 256 and name_buf[nlen] != 0) : (nlen += 1) {}
            var actual_name = name_buf[0..nlen];
            if (nlen >= 5 and name_buf[0] == 'u' and name_buf[1] == 's' and name_buf[2] == 'e' and name_buf[3] == 'r' and name_buf[4] == '.') {
                actual_name = name_buf[5..nlen];
            } else if (nlen >= 1) {
                frame.rax = @bitCast(@as(i64, -1)); // EPERM
                return;
            }
            const inode_num = ext2_mod.walkPathToInodePublic(path_buf[0..plen]) orelse {
                frame.rax = @bitCast(@as(i64, -2));
                return;
            };
            // Get value into temp buffer, then copy to user
            var val_buf: [4096]u8 = undefined;
            const bsize: u32 = @truncate(frame.r8);
            const result = ext2_mod.getXattr(inode_num, actual_name, &val_buf, @min(bsize, 4096));
            if (result > 0) {
                if (copy.copyToUser(@ptrFromInt(frame.r9), val_buf[0..@intCast(result)], @intCast(result)) != @as(usize, @intCast(result))) {
                    frame.rax = @bitCast(@as(i64, -14));
                    return;
                }
            }
            frame.rax = @bitCast(result);
        },
        465 => { // listxattrat(dfd, path, flags, list, size)
            const copy = @import("../../mm/copy_from_user.zig");
            const ext2_mod = @import("../../fs/ext2.zig");
            _ = frame.rdi; // dfd
            _ = frame.rdx; // flags
            var path_buf: [256]u8 = undefined;
            const pc = copy.copyFromUser(path_buf[0..], @ptrFromInt(frame.rsi), 255);
            if (pc == 0) {
                frame.rax = @bitCast(@as(i64, -14));
                return;
            }
            path_buf[if (pc < 255) pc else 255] = 0;
            var plen: usize = 0;
            while (plen < 256 and path_buf[plen] != 0) : (plen += 1) {}
            const inode_num = ext2_mod.walkPathToInodePublic(path_buf[0..plen]) orelse {
                frame.rax = @bitCast(@as(i64, -2));
                return;
            };
            var list_buf: [4096]u8 = undefined;
            const bsize: u32 = @truncate(frame.r8);
            const result = ext2_mod.listXattr(inode_num, &list_buf, @min(bsize, 4096));
            if (result > 0) {
                if (copy.copyToUser(@ptrFromInt(frame.r10), list_buf[0..@intCast(result)], @intCast(result)) != @as(usize, @intCast(result))) {
                    frame.rax = @bitCast(@as(i64, -14));
                    return;
                }
            }
            frame.rax = @bitCast(result);
        },
        466 => { // removexattrat(dfd, path, flags, name)
            const copy = @import("../../mm/copy_from_user.zig");
            const ext2_mod = @import("../../fs/ext2.zig");
            _ = frame.rdi; // dfd
            _ = frame.rdx; // flags
            var path_buf: [256]u8 = undefined;
            const pc = copy.copyFromUser(path_buf[0..], @ptrFromInt(frame.rsi), 255);
            if (pc == 0) {
                frame.rax = @bitCast(@as(i64, -14));
                return;
            }
            path_buf[if (pc < 255) pc else 255] = 0;
            var plen: usize = 0;
            while (plen < 256 and path_buf[plen] != 0) : (plen += 1) {}
            var name_buf: [256]u8 = undefined;
            const nc = copy.copyFromUser(name_buf[0..], @ptrFromInt(frame.r10), 255);
            if (nc == 0) {
                frame.rax = @bitCast(@as(i64, -14));
                return;
            }
            name_buf[if (nc < 255) nc else 255] = 0;
            var nlen: usize = 0;
            while (nlen < 256 and name_buf[nlen] != 0) : (nlen += 1) {}
            var actual_name = name_buf[0..nlen];
            if (nlen >= 5 and name_buf[0] == 'u' and name_buf[1] == 's' and name_buf[2] == 'e' and name_buf[3] == 'r' and name_buf[4] == '.') {
                actual_name = name_buf[5..nlen];
            } else if (nlen >= 1) {
                frame.rax = @bitCast(@as(i64, -1)); // EPERM
                return;
            }
            const inode_num = ext2_mod.walkPathToInodePublic(path_buf[0..plen]) orelse {
                frame.rax = @bitCast(@as(i64, -2));
                return;
            };
            frame.rax = @bitCast(ext2_mod.removeXattr(inode_num, actual_name));
        },
        467 => { // open_tree_attr(dfd, path, flags, attr)
            frame.rax = 0; // accept (simplified)
        },
        468 => { // file_getattr(fd, attr)
            frame.rax = 0; // accept (simplified)
        },
        469 => { // file_setattr(fd, attr)
            frame.rax = 0; // accept (simplified)
        },
        470 => { // listns(fd, cookie, buf, size)
            frame.rax = @bitCast(@as(i64, -38)); // ENOSYS (namespace listing not supported)
        },
        471 => { // rseq_slice_yield(cpu_id, flags)
            frame.rax = 0; // accept (rseq yield — no-op)
        },
        472 => { // arch_prctl(code, addr)
            frame.rax = @bitCast(syscallArchPrctl(frame.rdi, frame.rsi));
        },
        // ── F3: realtime scheduling classes (SCHED_FIFO / SCHED_RR) ──────────
        // Linux numbers are taken in this table (156/157=msgget/msgsnd,
        // 146/147=epoll_create1/epoll_ctl) → MoQiOS-specific numbers.
        473 => { // sched_setscheduler(pid, policy, param_ptr{sched_priority})
            frame.rax = @bitCast(syscallSchedSetscheduler(@truncate(frame.rdi), @truncate(frame.rsi), frame.rdx));
        },
        474 => { // sched_getscheduler(pid)
            frame.rax = @bitCast(syscallSchedGetscheduler(@truncate(frame.rdi)));
        },
        475 => { // sched_get_priority_max(policy)
            frame.rax = @bitCast(syscallSchedGetPriorityMax(@truncate(frame.rdi)));
        },
        476 => { // sched_get_priority_min(policy)
            frame.rax = @bitCast(syscallSchedGetPriorityMin(@truncate(frame.rdi)));
        },
        // ── L1: userspace driver framework (kernel/drivers/userdrv.zig) ────
        // MoQiOS-specific numbers, next free after the F3 block (#473-#476).
        // All six require CAP_SYS_RAWIO (checked inside userdrv).
        477 => { // dev_map_mmio(phys, size) -> user VA
            frame.rax = @bitCast(@import("../../drivers/userdrv.zig").syscallDevMapMmio(frame.rdi, frame.rsi));
        },
        478 => { // dev_irq_register(gsi)
            frame.rax = @bitCast(@import("../../drivers/userdrv.zig").syscallDevIrqRegister(frame.rdi));
        },
        479 => { // dev_irq_wait(gsi, timeout_ms)
            frame.rax = @bitCast(@import("../../drivers/userdrv.zig").syscallDevIrqWait(frame.rdi, frame.rsi));
        },
        480 => { // dev_irq_unregister(gsi)
            frame.rax = @bitCast(@import("../../drivers/userdrv.zig").syscallDevIrqUnregister(frame.rdi));
        },
        481 => { // dev_dma_alloc(size, out_ptr{user_va, phys})
            frame.rax = @bitCast(@import("../../drivers/userdrv.zig").syscallDevDmaAlloc(frame.rdi, frame.rsi));
        },
        482 => { // dev_dma_free(user_va)
            frame.rax = @bitCast(@import("../../drivers/userdrv.zig").syscallDevDmaFree(frame.rdi));
        },
        483 => { // ioperm_set(port, count, enable) — per-task TSS IOPB
            frame.rax = @bitCast(@import("../../proc/ioperm.zig").syscallIopermSet(frame.rdi, frame.rsi, frame.rdx));
        },
        484 => { // devfs_register(name_ptr, flags) -> ctrl fd (fs/devfs_proxy.zig)
            frame.rax = @bitCast(@import("../../fs/devfs_proxy.zig").syscallDevfsRegister(frame.rdi, frame.rsi));
        },
        else => {
            serial.writeString("[syscall] unknown syscall: 0x");
            fmt.writeHex(syscall_nr);
            serial.writeString("\n");
            frame.rax = @bitCast(errno.ENOSYS);
        },
    }
}

fn dispatchLinuxRlimitAlias(frame: *SyscallFrame, syscall_nr: u64) bool {
    const sched = @import("../../proc/sched.zig");
    const current = sched.currentTask() orelse return false;
    const policy = @import("../../proc/rlimit.zig").Policy;
    const alias = policy.linuxAlias(current.personality == .linux, syscall_nr) orelse return false;

    frame.rax = @bitCast(switch (alias) {
        .setrlimit => syscallSetrlimit(@truncate(frame.rdi), frame.rsi),
        .prlimit64 => syscallPrlimit64(@truncate(frame.rdi), @truncate(frame.rsi), frame.rdx, frame.r10),
    });
    return true;
}

/// Syscall #1: write(fd, buf, count)
/// Routes through VFS: stdout/stderr → serial, other fds → VFS write.
fn syscallWrite(frame: *SyscallFrame) void {
    frame.rax = @bitCast(file_io_mod.write(frame.rdi, frame.rsi, frame.rdx));
}

fn syscallExit(frame: *SyscallFrame) void {
    lifecycle_mod.exit(frame.rdi);
}

fn syscallGetpid(frame: *SyscallFrame) void {
    frame.rax = @bitCast(proc_mgmt_mod.getpid());
}

fn syscallSpawn(frame: *SyscallFrame) void {
    frame.rax = @bitCast(lifecycle_mod.spawn(frame.rdi));
}

/// Syscall #6: waitpid(pid, status_ptr, options)
/// RDI = pid (-1 for any child, >0 for specific child)
/// RSI = pointer to i32 in user space to receive exit code
/// RDX = options (bit 0 = WNOHANG)
/// Returns child TID on success, 0 if WNOHANG and no child exited, -1 on error.
fn syscallWaitpid(frame: *SyscallFrame) void {
    frame.rax = @bitCast(waitpid_mod.waitpidWithOptions(frame.rdi, frame.rsi, @truncate(frame.rdx)));
}

/// Syscall #7: brk(addr)
/// RDI = new program break address (0 = return current break)
/// Returns new break on success, current break on failure.
fn syscallBrk(frame: *SyscallFrame) void {
    frame.rax = @bitCast(brk_mod.brk(frame.rdi));
}

/// Syscall #8: mmap(addr, length, prot, flags, fd, offset)
/// RDI = addr (hint, 0 = kernel chooses), RSI = length, RDX = prot,
/// R10 = flags, R8 = fd (-1 for anonymous), R9 = offset
/// For now: only supports MAP_ANONYMOUS | MAP_PRIVATE with addr=0.
/// Returns mapped address or -1 on failure.
fn syscallMmap(frame: *SyscallFrame) void {
    frame.rax = @bitCast(mmap_mod.mmap(frame.rdi, frame.rsi, frame.rdx, frame.r10, @bitCast(frame.r8), frame.r9));
}

/// Syscall #9: open(name, flags, mode)
/// RDI = filename pointer in user space, RSI = flags, RDX = mode
/// Returns fd on success, -1 on failure.
fn syscallOpen(frame: *SyscallFrame) void {
    frame.rax = @bitCast(file_io_mod.openWithMode(frame.rdi, @truncate(frame.rsi), @truncate(frame.rdx)));
}

/// openat2(dirfd, pathname, how, size) — validate the fixed open_how prefix
/// before handing flags and mode to the credential-aware open implementation.
fn syscallOpenat2(dirfd_raw: u64, pathname: u64, how_ptr: u64, size: u64) i64 {
    const dirfd: i64 = @as(i64, @as(i32, @bitCast(@as(u32, @truncate(dirfd_raw)))));
    const policy = @import("../../fs/openat2_policy.zig");
    if (size != policy.SIZE) return errno.EINVAL;

    const copy = @import("../../mm/copy_from_user.zig");
    const bo = @import("../../lib/byte_order.zig");
    var how_buf: [24]u8 = undefined;
    if (copy.copyFromUser(&how_buf, @ptrFromInt(how_ptr), how_buf.len) != how_buf.len) {
        return errno.EFAULT;
    }

    const how: policy.OpenHow = .{
        .flags = bo.readU64Le(how_buf[0..8]),
        .mode = bo.readU64Le(how_buf[8..16]),
        .resolve = bo.readU64Le(how_buf[16..24]),
    };
    const validation = policy.validate(dirfd, how, size);
    if (validation != 0) return validation;

    return file_io_mod.openWithMode(pathname, @truncate(how.flags), @truncate(how.mode));
}

/// Syscall #10: read(fd, buf, count)
/// RDI = fd, RSI = buffer pointer in user space, RDX = count
/// Returns bytes read on success, 0 on EOF, -1 on error.
fn syscallRead(frame: *SyscallFrame) void {
    frame.rax = @bitCast(file_io_mod.read(@intCast(frame.rdi), frame.rsi, frame.rdx));
}

/// Syscall #11: close(fd)
/// RDI = fd
/// Returns 0 on success, -1 on error.
fn syscallClose(frame: *SyscallFrame) void {
    frame.rax = @bitCast(file_io_mod.close(@intCast(frame.rdi)));
}

const paging = @import("../../arch/x86_64/paging.zig");

// Module imports for extracted syscall implementations
const waitpid_mod = @import("../../proc/waitpid.zig");
const brk_mod = @import("../../mm/brk.zig");
const mmap_mod = @import("../../mm/mmap.zig");
const signal_syscall_mod = @import("../../proc/signal_syscall.zig");
const env_mod = @import("../../proc/env.zig");
const chdir_mod = @import("../../fs/chdir.zig");
const unlink_mod = @import("../../fs/unlink.zig");
const socket_mod = @import("../../net/socket_syscall.zig");
const file_io_mod = @import("../../fs/file_io.zig");
const time_mod = @import("../../proc/time_syscall.zig");
const dir_ops_mod = @import("../../fs/dir_ops.zig");
const proc_mgmt_mod = @import("../../proc/process_mgmt.zig");
const lifecycle_mod = @import("../../proc/lifecycle.zig");
const raw_net_mod = @import("../../net/raw_net.zig");
const tcp_syscall_mod = @import("../../net/tcp_syscall.zig");
const fork_mod = @import("../../proc/fork.zig");
const execve_mod = @import("../../proc/execve.zig");
const readv_mod = @import("../../fs/readv.zig");
const fcntl_mod = @import("../../fs/fcntl.zig");
const futex_mod = @import("../../sync/futex.zig");
const splice_mod = @import("../../fs/splice.zig");
const vfs_mod = @import("../../fs/vfs.zig");
const poll_mod = @import("../../fs/poll.zig");
const select_mod = @import("../../fs/select.zig");
const mprotect_mod = @import("../../mm/mprotect.zig");
const ioctl_mod = @import("../../fs/ioctl.zig");
const inotify_mod = @import("../../fs/inotify.zig");
const eventfd_mod = @import("../../fs/eventfd.zig");
const timerfd_mod = @import("../../ipc/timerfd.zig");
const getdents_mod = @import("../../fs/getdents.zig");
const cred_mod = @import("../../proc/credentials.zig");
const readlink_mod = @import("../../fs/readlink.zig");
const statx_mod = @import("../../fs/statx.zig");
const cfr_mod = @import("../../fs/copy_file_range.zig");
const flock_mod = @import("../../fs/file_lock.zig");
const mq_mod = @import("../../ipc/posix_mq.zig");
const ptimer_mod = @import("../../ipc/posix_timer.zig");
const aio_mod = @import("../../fs/aio.zig");
const misc_mod = @import("../../proc/misc_syscall.zig");
const pgrp_mod = @import("../../proc/pgrp.zig");
const unix_sock_mod = @import("../../net/unix_socket.zig");
const random_mod = @import("../../drivers/random.zig");
const clone_mod = @import("../../arch/x86_64/clone.zig");
const cap_check = @import("../../proc/cap_check.zig");
const capability_mod = @import("../../ipc/capability.zig");
const task_mod_caps = @import("../../proc/task.zig");

/// Initialize the syscall entry point.
/// Sets up IA32_STAR and IA32_LSTAR MSRs, enables EFER.SCE,
/// and configures kernel GSBase for per-CPU data.
pub fn init() void {
    initSyscallMsrsOnThisCpu();

    // Enable SYSCALL/SYSRET via EFER.SCE (bit 0)
    const efer = rdmsr(MSR_EFER);
    wrmsr(MSR_EFER, efer | 1);

    // Set kernel GSBase to point to PerCpu struct for BSP (CPU 0).
    // swapgs swaps GS_BASE and KERNEL_GS_BASE.
    // In user mode: GS_BASE = user TLS (0 for now), KERNEL_GS_BASE = &percpu_array[0]
    // In kernel mode (after swapgs): GS_BASE = &percpu_array[0]
    wrmsr(MSR_KERNEL_GS_BASE, @intFromPtr(&percpu_array[0]));
    wrmsr(MSR_GS_BASE, @intFromPtr(&percpu_array[0]));

    serial.writeString("[syscall] SYSCALL/SYSRET enabled, GSBase configured\n");
}

/// Syscall #12: munmap(addr, length)
fn syscallMunmap(frame: *SyscallFrame) void {
    frame.rax = @bitCast(mmap_mod.munmap(frame.rdi, frame.rsi));
}

/// Syscall #96: gettimeofday(tv, tz)
/// RDI = pointer to struct timeval in user space, RSI = timezone (ignored)
fn syscallGettimeofday(frame: *SyscallFrame) void {
    frame.rax = @bitCast(time_mod.gettimeofday(frame.rdi));
}

/// Syscall #228: clock_gettime(clockid, tp)
/// RDI = clockid, RSI = pointer to struct timespec in user space
fn syscallClock_gettime(frame: *SyscallFrame) void {
    frame.rax = @bitCast(time_mod.clock_gettime(frame.rdi, frame.rsi));
}

/// Syscall #22: pipe(pipefd) — create a pipe
/// RDI = pointer to int[2] in user space: [0]=read_fd, [1]=write_fd
fn syscallPipe(frame: *SyscallFrame) void {
    frame.rax = @bitCast(proc_mgmt_mod.pipe(frame.rdi));
}

/// Syscall #33: dup2(oldfd, newfd)
/// RDI = oldfd, RSI = newfd
fn syscallDup2(frame: *SyscallFrame) void {
    frame.rax = @bitCast(proc_mgmt_mod.dup2(@intCast(frame.rdi), @intCast(frame.rsi)));
}

fn syscallFork(frame: *SyscallFrame) void {
    frame.rax = @bitCast(fork_mod.fork(frame));
}

/// Syscall #59: execve(filename, argv, envp) — replace current process with new program
fn syscallExecve(frame: *SyscallFrame) void {
    const frame_addr = execve_mod.prepareExec(frame.rdi, frame.rsi, frame.rdx) orelse {
        frame.rax = @bitCast(errno.EPERM);
        return;
    };

    asm volatile (
        \\movq %[anchor], %%rsp
        \\popq %%r15
        \\popq %%r14
        \\popq %%r13
        \\popq %%r12
        \\popq %%r11
        \\popq %%r10
        \\popq %%r9
        \\popq %%r8
        \\popq %%rbp
        \\popq %%rdi
        \\popq %%rsi
        \\popq %%rdx
        \\popq %%rcx
        \\popq %%rbx
        \\popq %%rax
        \\addq $16, %%rsp
        \\swapgs
        \\iretq
        :
        : [anchor] "r" (frame_addr),
        : .{ .memory = true });
    unreachable;
}

/// v52.0: execveat helper for non-AT_FDCWD dirfd resolution.
/// Resolves dirfd to its stored path, concatenates with relative pathname,
/// and calls prepareExecWithKernelPath.
fn execveatWithDirfd(frame: *SyscallFrame, dirfd: i32) void {
    const copy = @import("../../mm/copy_from_user.zig");
    const ext2_mod = @import("../../fs/ext2.zig");
    const sched_m = @import("../../proc/sched.zig");
    const task_m = @import("../../proc/task.zig");
    const vfs_m = @import("../../fs/vfs.zig");

    const cur_idx = sched_m.currentTaskIndex() orelse {
        frame.rax = @bitCast(@as(i64, -9));
        return;
    };
    const t = task_m.getTask(cur_idx) orelse {
        frame.rax = @bitCast(@as(i64, -9));
        return;
    };
    const fd: u32 = @intCast(dirfd);
    if (fd >= vfs_m.MAX_FDS or t.fd_table.fds[fd].fd_type != .ext2_file) {
        frame.rax = @bitCast(@as(i64, -9));
        return;
    }
    const ext2_idx = t.fd_table.fds[fd].ext2_file_idx;
    const dir_path = ext2_mod.getOpenFilePath(ext2_idx) orelse {
        frame.rax = @bitCast(@as(i64, -9));
        return;
    };

    // v52.3: use stack buffers (512 bytes safe for kernel stack, avoids SMP race)
    var rel_buf: [256]u8 = undefined;
    var combined: [256]u8 = undefined;

    const rc = copy.copyFromUser(rel_buf[0..], @ptrFromInt(frame.rsi), 255);
    if (rc == 0) {
        frame.rax = @bitCast(@as(i64, -14));
        return;
    }
    rel_buf[if (rc < 255) rc else 255] = 0;
    var rlen: usize = 0;
    while (rlen < 256 and rel_buf[rlen] != 0) : (rlen += 1) {}

    // v52.4: absolute pathname — dirfd is ignored per POSIX/Linux semantics
    if (rlen > 0 and rel_buf[0] == '/') {
        const frame_addr = execve_mod.prepareExecWithKernelPath(rel_buf[0..rlen], frame.rdx, frame.r10) orelse {
            frame.rax = @bitCast(@as(i64, -13));
            return;
        };
        asm volatile (
            \\movq %[anchor], %%rsp
            \\popq %%r15
            \\popq %%r14
            \\popq %%r13
            \\popq %%r12
            \\popq %%r11
            \\popq %%r10
            \\popq %%r9
            \\popq %%r8
            \\popq %%rbp
            \\popq %%rdi
            \\popq %%rsi
            \\popq %%rdx
            \\popq %%rcx
            \\popq %%rbx
            \\popq %%rax
            \\addq $16, %%rsp
            \\swapgs
            \\iretq
            :
            : [anchor] "r" (frame_addr),
            : .{ .memory = true });
        unreachable;
    }

    const path = ext2_mod.buildCombinedPath(&combined, dir_path, rel_buf[0..rlen]) orelse {
        frame.rax = @bitCast(@as(i64, -36));
        return;
    };

    const frame_addr = execve_mod.prepareExecWithKernelPath(path, frame.rdx, frame.r10) orelse {
        frame.rax = @bitCast(@as(i64, -13));
        return;
    };

    asm volatile (
        \\movq %[anchor], %%rsp
        \\popq %%r15
        \\popq %%r14
        \\popq %%r13
        \\popq %%r12
        \\popq %%r11
        \\popq %%r10
        \\popq %%r9
        \\popq %%r8
        \\popq %%rbp
        \\popq %%rdi
        \\popq %%rsi
        \\popq %%rdx
        \\popq %%rcx
        \\popq %%rbx
        \\popq %%rax
        \\addq $16, %%rsp
        \\swapgs
        \\iretq
        :
        : [anchor] "r" (frame_addr),
        : .{ .memory = true });
    unreachable;
}

fn syscallSigaction(frame: *SyscallFrame) void {
    frame.rax = @bitCast(signal_syscall_mod.sigaction(@truncate(frame.rdi), frame.rsi, frame.rdx));
}

fn syscallSigprocmask(frame: *SyscallFrame) void {
    frame.rax = @bitCast(signal_syscall_mod.sigprocmask(@truncate(frame.rdi), frame.rsi, frame.rdx, frame.r10));
}

fn syscallSigreturn(frame: *SyscallFrame) void {
    const r = signal_syscall_mod.sigreturn() orelse {
        // Bad frame address: leave the register state alone rather than
        // restoring garbage, and report the fault.
        frame.rax = @bitCast(@as(i64, -14)); // EFAULT
        return;
    };
    frame.rax = r.rax;
    frame.rbx = r.rbx;
    frame.rcx = r.rcx;
    frame.rdx = r.rdx;
    frame.rsi = r.rsi;
    frame.rdi = r.rdi;
    frame.rbp = r.rbp;
    frame.r8 = r.r8;
    frame.r9 = r.r9;
    frame.r10 = r.r10;
    frame.r11 = r.r11;
    frame.r12 = r.r12;
    frame.r13 = r.r13;
    frame.r14 = r.r14;
    frame.r15 = r.r15;
}

fn syscallKill(frame: *SyscallFrame) void {
    // Task #8: cap_kill required when targeting a different process.
    const pid_signed: i64 = @bitCast(frame.rdi);
    const target_pid: u32 = @truncate(frame.rdi);
    if (currentTaskCaps()) |info| {
        // 进程组广播（pid<0）与跨进程单发同样需要 cap_kill；-1 时按目标校验。
        if (pid_signed > 0 and info.tid != target_pid and !@field(info.t.effective_caps, "cap_kill")) {
            frame.rax = @bitCast(@as(i64, -1)); // EPERM
            return;
        }
        if (pid_signed < 0 and !@field(info.t.effective_caps, "cap_kill")) {
            frame.rax = @bitCast(@as(i64, -1)); // EPERM
            return;
        }
    }
    frame.rax = @bitCast(lifecycle_mod.kill(pid_signed, @truncate(frame.rsi)));
}

fn syscallNetSend(frame: *SyscallFrame) void {
    if (!checkCapForCurrent("cap_net_raw")) {
        frame.rax = @bitCast(@as(i64, -1)); // EPERM
        return;
    }
    frame.rax = @bitCast(raw_net_mod.netSend(frame.rdi, frame.rsi));
}

fn syscallNetRecv(frame: *SyscallFrame) void {
    if (!checkCapForCurrent("cap_net_raw")) {
        frame.rax = @bitCast(@as(i64, -1)); // EPERM
        return;
    }
    frame.rax = @bitCast(raw_net_mod.netRecv(frame.rdi, frame.rsi));
}

fn syscallUdpSend(frame: *SyscallFrame) void {
    frame.rax = @bitCast(raw_net_mod.udpSend(@truncate(frame.rdi), @truncate(frame.rsi), @truncate(frame.rdx), frame.r10, frame.r8));
}

fn syscallUdpRecv(frame: *SyscallFrame) void {
    frame.rax = @bitCast(raw_net_mod.udpRecv(@truncate(frame.rdi), frame.rsi, frame.rdx, frame.r10, frame.r8));
}

fn syscallNetPoll(frame: *SyscallFrame) void {
    frame.rax = @bitCast(raw_net_mod.netPoll());
}

pub fn checkSignalsOnSyscallReturn(frame: *SyscallFrame) void {
    const sig_mod = @import("../../proc/signal.zig");
    const sched = @import("../../proc/sched.zig");

    const current = sched.currentTask() orelse return;
    if (!current.is_user) return;
    if (current.pending_signals == 0) return;
    if (current.pending_signals & ~@as(u32, @truncate(current.signal_mask)) == 0) return;

    const signum = sig_mod.dequeueSignal(current) orelse return;

    // SIGSTOP 不可捕获/阻塞（与 sched.deliverSignalToRunningTask 一致）。
    const handler_addr = if (signum == sig_mod.SIGSTOP) 0 else current.signal_handlers[signum - 1];

    if (handler_addr == 0) {
        switch (sig_mod.defaultAction(signum)) {
            .terminate => {
                // 必须走完整 exitTask：直接标 .zombie 会跳过 fd 清理、
                // [kill] 诊断和父进程唤醒——若父进程正阻塞在 waitpid
                // （waiting_for_child 已置位），它将永远等不到唤醒，且 tick
                // 随后把该僵尸切走，再无任何人调用 exitTask（SMP=4 hello58
                // 停滞的根因：子进程被 SIGKILL 在此静默标记，父进程永久停放）。
                // exitTask 不返回（与本函数的其他终止路径一致）。
                @import("../../proc/task.zig").exitTask(128 + @as(i32, @intCast(signum)));
            },
            .ignore => return,
            .stop => sig_mod.stopTask(current),
            .cont => sig_mod.continueTask(current),
        }
        return;
    }

    if (handler_addr == 1) return;

    const user_rsp = getPerCpu().saved_user_rsp;
    const user_rip = frame.rcx;
    const user_rflags = frame.r11;

    // Full GPR set for sigreturn. rcx/r11 hold the user rip/rflags here (the
    // syscall instruction clobbered the user's originals with exactly those
    // values), so passing the frame fields is faithful for every register.
    const gprs: sig_mod.GpRegs = .{
        .rax = frame.rax,
        .rbx = frame.rbx,
        .rcx = frame.rcx,
        .rdx = frame.rdx,
        .rsi = frame.rsi,
        .rdi = frame.rdi,
        .rbp = frame.rbp,
        .r8 = frame.r8,
        .r9 = frame.r9,
        .r10 = frame.r10,
        .r11 = frame.r11,
        .r12 = frame.r12,
        .r13 = frame.r13,
        .r14 = frame.r14,
        .r15 = frame.r15,
    };

    const result = sig_mod.pushSignalFrame(current, signum, user_rsp, user_rip, user_rflags, &gprs);

    // v53.45: Drop signal if delivery fails — avoids livelock when user stack
    // is permanently unmapped. Signal was already dequeued by dequeueSignal.
    if (result.new_rsp == 0) return;

    frame.rdi = signum;
    frame.rcx = handler_addr;
    const pc = getPerCpu();
    pc.exec_pending = 3;
    pc.exec_new_entry = handler_addr;
    pc.exec_new_stack = result.new_rsp;
}

fn syscallGetenv(frame: *SyscallFrame) void {
    frame.rax = @bitCast(proc_mgmt_mod.getenv(frame.rdi, frame.rsi, frame.rdx));
}

fn syscallSetenv(frame: *SyscallFrame) void {
    frame.rax = @bitCast(env_mod.setenv(frame.rdi));
}

fn syscallListdir(frame: *SyscallFrame) void {
    frame.rax = @bitCast(dir_ops_mod.listdir(frame.rdi, frame.rsi));
}

fn syscallUname(frame: *SyscallFrame) void {
    frame.rax = @bitCast(lifecycle_mod.uname(frame.rdi));
}

/// Syscall #108: chdir(path)
/// RDI = path pointer in user space
/// Returns 0 on success, -1 on failure.
fn syscallChdir(frame: *SyscallFrame) void {
    frame.rax = @bitCast(chdir_mod.chdir(frame.rdi));
}

/// Syscall #109: getcwd(buf, size)
/// RDI = buffer pointer, RSI = buffer size
/// Returns number of bytes written (including null), or -1 on failure.
fn syscallGetcwd(frame: *SyscallFrame) void {
    frame.rax = @bitCast(dir_ops_mod.getcwd(frame.rdi, frame.rsi));
}

/// Syscall #110: fstat(fd, stat_buf)
/// RDI = fd, RSI = pointer to stat buffer in user space (144 bytes)
/// struct stat { u64 dev, ino, nlink; u32 mode; u32 pad1; u64 uid, gid, rdev; i64 size; ... }
/// Simplified: we fill dev=0, ino=fd, mode, size.
fn syscallFstat(frame: *SyscallFrame) void {
    frame.rax = @bitCast(dir_ops_mod.fstat(frame.rdi, frame.rsi));
}

/// Syscall #111: unlink(path)
/// RDI = path pointer in user space
/// Returns 0 on success, -1 on failure.
fn syscallUnlink(frame: *SyscallFrame) void {
    frame.rax = @bitCast(unlink_mod.unlink(frame.rdi));
}

fn syscallTcpConnect(frame: *SyscallFrame) void {
    frame.rax = @bitCast(tcp_syscall_mod.tcpConnect(frame.rdi, @truncate(frame.rsi)));
}

fn syscallTcpSend(frame: *SyscallFrame) void {
    frame.rax = @bitCast(tcp_syscall_mod.tcpSend(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx)));
}

fn syscallTcpRecv(frame: *SyscallFrame) void {
    frame.rax = @bitCast(tcp_syscall_mod.tcpRecv(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx)));
}

/// Syscall #115: tcp_close(tcb_idx)
fn syscallTcpClose(frame: *SyscallFrame) void {
    frame.rax = @bitCast(tcp_syscall_mod.tcpClose(@truncate(frame.rdi)));
}

/// Syscall #116: tcp_poll(tcb_idx)
fn syscallTcpPoll(frame: *SyscallFrame) void {
    frame.rax = @bitCast(tcp_syscall_mod.tcpPoll(@truncate(frame.rdi)));
}

/// Syscall #117: socket(domain, type, protocol)
/// RDI = domain (AF_INET = 2)
/// RSI = type (SOCK_STREAM = 1)
/// RDX = protocol (0 = default)
/// Returns fd index or -1 on failure.
fn syscallSocket(frame: *SyscallFrame) void {
    frame.rax = @bitCast(socket_mod.socket(@truncate(frame.rdi), @truncate(frame.rsi), @truncate(frame.rdx)));
}

/// Syscall #118: bind(fd, addr_ptr, addr_len)
/// RDI = fd
/// RSI = pointer to sockaddr_in (user space)
/// RDX = addr_len
/// Returns 0 on success, -1 on failure.
fn syscallBind(frame: *SyscallFrame) void {
    // Task #8: cap_net_bind required for privileged ports (< 1024).
    if (frame.rsi != 0 and frame.rsi < 0x0000_8000_0000_0000) {
        // sockaddr layout: [u16 family][u16 port_be]...
        var sa: [4]u8 = undefined;
        const copy = @import("../../mm/copy_from_user.zig");
        const got = copy.copyFromUser(&sa, @ptrFromInt(frame.rsi), 4);
        if (got == 4) {
            const port: u16 = (@as(u16, sa[2]) << 8) | @as(u16, sa[3]);
            if (port != 0 and port < 1024) {
                if (!checkCapForCurrent("cap_net_bind")) {
                    frame.rax = @bitCast(@as(i64, -1)); // EPERM
                    return;
                }
            }
        }
    }
    frame.rax = @bitCast(socket_mod.bind(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx)));
}

/// Syscall #119: listen(fd, backlog)
/// RDI = fd
/// RSI = backlog (ignored)
/// Returns 0 on success, -1 on failure.
fn syscallListen(frame: *SyscallFrame) void {
    frame.rax = @bitCast(socket_mod.listen(@truncate(frame.rdi), @truncate(frame.rsi)));
}

/// Syscall #120: accept(fd, addr_ptr, addr_len_ptr)
/// RDI = fd (listening socket)
/// RSI = addr_ptr (user space, to write peer address) — can be 0
/// RDX = addr_len_ptr (user space) — can be 0
/// Returns new fd for accepted connection, or -1 on failure / 0 if none pending.
fn syscallAccept(frame: *SyscallFrame) void {
    frame.rax = @bitCast(socket_mod.accept(@truncate(frame.rdi), frame.rsi, frame.rdx));
}

/// Syscall #121: sendto(fd, buf, len, flags, addr_ptr, addr_len)
/// For TCP sockets, ignores destination (already connected).
/// RDI = fd
/// RSI = data buffer (user space)
/// RDX = data length
/// Returns bytes sent, -1 on error.
fn syscallSendto(frame: *SyscallFrame) void {
    // 4th arg arrives in r10 per the syscall ABI (rcx holds the user RIP).
    frame.rax = @bitCast(socket_mod.sendto(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx), @truncate(frame.r10), frame.r8, @truncate(frame.r9)));
}

/// Syscall #122: recvfrom(fd, buf, len, flags, addr_ptr, addr_len_ptr)
/// For TCP sockets, ignores source address.
/// RDI = fd
/// RSI = buffer (user space)
/// RDX = buffer length
/// Returns bytes received (0 = none), -1 on error/closed.
fn syscallRecvfrom(frame: *SyscallFrame) void {
    // 4th arg arrives in r10 per the syscall ABI (rcx holds the user RIP);
    // reading rcx made flags garbage — invisible while flags were ignored.
    frame.rax = @bitCast(socket_mod.recvfrom(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx), @truncate(frame.r10), frame.r8, frame.r9));
}

/// Syscall #123: mkdir(path, mode)
/// RDI = path pointer (user space)
/// RSI = requested mode
/// Returns 0 on success, -1 on failure.
fn syscallMkdir(frame: *SyscallFrame) void {
    frame.rax = @bitCast(dir_ops_mod.mkdirWithMode(frame.rdi, @truncate(frame.rsi)));
}

/// Syscall #124: connect(fd, addr_ptr, addr_len)
/// RDI = fd (TCP socket)
/// RSI = pointer to sockaddr_in (user space)
/// RDX = addr_len
/// Returns 0 on success (SYN sent), -1 on failure.
fn syscallConnect(frame: *SyscallFrame) void {
    frame.rax = @bitCast(socket_mod.connect(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx)));
}

// ── v31.4: lseek/access/nanosleep ────────────────────────────────

/// lseek(fd, offset, whence) — reposition file offset.
/// whence: 0=SEEK_SET, 1=SEEK_CUR, 2=SEEK_END
fn syscallLseek(fd: u32, offset: u64, whence: u32) i64 {
    const sched = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = tm.getTask(cur_idx) orelse return -1;
    if (fd >= vfs_mod.MAX_FDS) return -9; // EBADF
    const desc = &cur.fd_table.fds[fd];
    if (desc.fd_type == .none) return -9;

    const off: i64 = @bitCast(offset);
    var new_off: i64 = 0;
    switch (whence) {
        0 => new_off = off, // SEEK_SET
        1 => new_off = @as(i64, @intCast(desc.offset)) + off, // SEEK_CUR
        2 => new_off = @as(i64, @intCast(desc.file_size)) + off, // SEEK_END
        else => return -22, // EINVAL
    }
    if (new_off < 0) return -22;
    desc.offset = @intCast(new_off);
    return new_off;
}

/// access(pathname, mode) — check file accessibility.
/// Simplified: try to open the file, return 0 if it exists.
fn syscallAccess(pathname_ptr: u64, mode: u32) i64 {
    _ = mode;
    if (pathname_ptr == 0 or pathname_ptr >= 0x0000_8000_0000_0000) return -14;
    const copy = @import("../../mm/copy_from_user.zig");
    const sched = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");
    var name_buf: [256]u8 = undefined;
    const n = copy.copyFromUser(&name_buf, @ptrFromInt(pathname_ptr), 255);
    if (n == 0) return -14;
    name_buf[if (n < 255) n else 255] = 0;
    var len: usize = 0;
    while (len < 256 and name_buf[len] != 0) : (len += 1) {}
    const name = name_buf[0..len];

    // F_OK: just check existence
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = tm.getTask(cur_idx) orelse return -1;
    const fd_result = cur.fd_table.openWithCredentials(name, 0, cur.euid, cur.egid, cur.effective_caps);
    if (fd_result >= 0) {
        const fd: u32 = @intCast(fd_result);
        _ = cur.fd_table.close(fd);
        return 0;
    }
    return -2; // ENOENT
}

/// nanosleep(req_timespec, rem_timespec) — high-resolution sleep.
///
/// Blocking sleep: the caller parks on the scheduler's sleep bitmap
/// (sched.sleep_bm) and is woken by the per-tick sleepTimerTick scan at its
/// deadline. The previous TSC busy-spin burned the CPU inside an IF=0 syscall
/// — the LAPIC timer could not fire, so no other runnable task was ever
/// scheduled until the spinner blocked on something else (observed as a forked
/// child starving for seconds while parent/sibling polled with nanosleep).
///
/// Signal protocol matches the other wait primitives (devfs_proxy pattern):
/// a fatal pending signal terminates via exitTask; an actionable one returns
/// -EINTR with the remaining time written back to `rem`.
fn syscallNanosleep(req_ptr: u64, rem_ptr: u64) i64 {
    if (req_ptr == 0 or req_ptr >= 0x0000_8000_0000_0000) return -14;
    const copy = @import("../../mm/copy_from_user.zig");
    const tsc = @import("../../arch/x86_64/tsc.zig");
    const sched = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");
    const sig_mod = @import("../../proc/signal.zig");
    var ts_buf: [16]u8 = undefined;
    if (copy.copyFromUser(&ts_buf, @ptrFromInt(req_ptr), 16) != 16) return -14;
    const bo = @import("../../lib/byte_order.zig");
    const sec: u64 = bo.readU64Le(ts_buf[0..8]);
    const nsec: u64 = bo.readU64Le(ts_buf[8..16]);
    const target_ns = sec * 1_000_000_000 + nsec;
    if (target_ns == 0) return 0;

    const cur_idx = sched.currentTaskIndex() orelse return -14;
    const cur = tm.getTask(cur_idx) orelse return -14;
    const bit = @as(u64, 1) << @intCast(cur_idx);
    const deadline = tsc.nanos() + target_ns;

    while (true) {
        // Fatal signal: die through exitTask (fd cleanup + parent wakeup).
        if (sig_mod.pendingFatal(cur)) |s| {
            cur.sleep_deadline_ns = 0;
            _ = @atomicRmw(u64, &sched.sleep_bm, .And, ~bit, .seq_cst);
            tm.exitTask(128 + @as(i32, @intCast(s)));
        }
        // Actionable (handled) signal: report remaining time, return -EINTR.
        if (sig_mod.pendingActionable(cur)) {
            cur.sleep_deadline_ns = 0;
            _ = @atomicRmw(u64, &sched.sleep_bm, .And, ~bit, .seq_cst);
            const now = tsc.nanos();
            if (rem_ptr != 0 and rem_ptr < 0x0000_8000_0000_0000) {
                const left = deadline -| now;
                var rem_buf: [16]u8 = undefined;
                bo.writeU64Le(rem_buf[0..8], left / 1_000_000_000);
                bo.writeU64Le(rem_buf[8..16], left % 1_000_000_000);
                if (copy.copyToUser(@ptrFromInt(rem_ptr), &rem_buf, 16) != 16) return -14;
            }
            return -4; // EINTR
        }
        if (tsc.nanos() >= deadline) break;
        // Publish the deadline BEFORE blocking: if the tick scan fires in the
        // gap it cannot unblock a .running task, but the bit stays set, so the
        // next tick retries the wake — no lost wakeup, worst case +1 tick.
        @atomicStore(u64, &cur.sleep_deadline_ns, deadline, .release);
        _ = @atomicRmw(u64, &sched.sleep_bm, .Or, bit, .seq_cst);
        tm.blockTask(cur_idx);
        sched.forceReschedule();
        // yield trap 可能未切换（本 CPU 无可运行同伴时 tick 直接返回），
        // 本任务仍以 .blocked 继续执行——必须修复状态，否则逃出循环后
        // 一旦被抢占就永远不会再被调度。
        sched.repairCurrentAfterBlock();
    }

    cur.sleep_deadline_ns = 0;
    _ = @atomicRmw(u64, &sched.sleep_bm, .And, ~bit, .seq_cst);

    // Write zero remaining time (fully slept)
    if (rem_ptr != 0 and rem_ptr < 0x0000_8000_0000_0000) {
        var zero: [16]u8 = @splat(0);
        if (copy.copyToUser(@ptrFromInt(rem_ptr), &zero, 16) != 16) return -14;
    }
    return 0;
}

// ── v31.6: Process group management ─────────────────────────────

/// setsid() — create a new session.
fn syscallSetsid() i64 {
    return pgrp_mod.sysSetsid();
}

/// setpgid(pid, pgid) — set process group ID.
fn syscallSetpgid(pid: u32, pgid: u32) i64 {
    return pgrp_mod.sysSetpgid(pid, pgid);
}

/// getpgid(pid) — get process group ID.
fn syscallGetpgid(pid: u32) i64 {
    return pgrp_mod.sysGetpgid(pid);
}

/// getsid(pid) — get session ID.
fn syscallGetsid(pid: u32) i64 {
    return pgrp_mod.sysGetsid(pid);
}

// ── v31.7: truncate/ftruncate/rename ─────────────────────────────

/// truncate(path, length) — truncate a file by path.
fn syscallTruncate(path_ptr: u64, length: u64) i64 {
    if (path_ptr == 0 or path_ptr >= 0x0000_8000_0000_0000) return -14;
    const copy = @import("../../mm/copy_from_user.zig");
    const sched = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");
    var name_buf: [256]u8 = undefined;
    const n = copy.copyFromUser(&name_buf, @ptrFromInt(path_ptr), 255);
    if (n == 0) return -14;
    name_buf[if (n < 255) n else 255] = 0;
    var len: usize = 0;
    while (len < 256 and name_buf[len] != 0) : (len += 1) {}
    const name = name_buf[0..len];

    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = tm.getTask(cur_idx) orelse return -1;
    // O_WRONLY (0x01): truncate requires write access to the file.
    const fd_result = cur.fd_table.openWithCredentials(name, 1, cur.euid, cur.egid, cur.effective_caps);
    if (fd_result < 0) return fd_result;
    const fd: u32 = @intCast(fd_result);
    const result = truncateDesc(&cur.fd_table.fds[fd], length);
    _ = cur.fd_table.close(fd);
    return result;
}

/// ftruncate(fd, length) — truncate a file by fd.
fn syscallFtruncate(fd: u32, length: u64) i64 {
    const sched = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = tm.getTask(cur_idx) orelse return -1;
    if (fd >= vfs_mod.MAX_FDS) return -9;
    const desc = &cur.fd_table.fds[fd];
    if (desc.fd_type == .none) return -9;
    if (!desc.writable) return -22; // EINVAL — fd not open for writing
    return truncateDesc(desc, length);
}

/// Shared truncate implementation. Only filesystems with real truncation
/// support are accepted; ramdisk/proc files are read-only and rejected.
fn truncateDesc(desc: *vfs_mod.FileDescriptor, length: u64) i64 {
    const sched = @import("../../proc/sched.zig");
    if (sched.currentTask()) |t| {
        if (length > desc.file_size and length > t.fSize_cur) {
            const sig = @import("../../proc/signal.zig");
            sig.raiseSelf(sig.SIGXFSZ);
            return -27; // EFBIG
        }
    }
    if (length > 0xFFFF_FFFF) return -22; // EINVAL: backends use u32 sizes
    const new_size: u32 = @truncate(length);
    switch (desc.fd_type) {
        .ext2_file => {
            const ext2 = @import("../../fs/ext2.zig");
            if (!ext2.truncateFile(desc.ext2_file_idx, new_size)) return -5; // EIO
        },
        .fat32_file => {
            const fat32 = @import("../../fs/fat32.zig");
            if (!fat32.truncateFile(desc.fat32_file_idx, new_size)) return -5; // EIO
        },
        .tmpfs_file => {
            const tmpfs = @import("../../fs/tmpfs.zig");
            if (!tmpfs.tmpfsTruncate(@intCast(desc.tmpfs_idx), new_size)) return -22; // EINVAL
        },
        else => return -22, // EINVAL — ramdisk/proc and special fds are not truncatable
    }
    desc.file_size = new_size;
    if (desc.offset > new_size) desc.offset = new_size;
    return 0;
}

/// rename(oldpath, newpath) — rename a file.
fn syscallRename(old_ptr: u64, new_ptr: u64) i64 {
    if (old_ptr == 0 or old_ptr >= 0x0000_8000_0000_0000 or
        new_ptr == 0 or new_ptr >= 0x0000_8000_0000_0000) return -14;
    const copy = @import("../../mm/copy_from_user.zig");
    var old_buf: [256]u8 = undefined;
    var new_buf: [256]u8 = undefined;
    const on = copy.copyFromUser(&old_buf, @ptrFromInt(old_ptr), 255);
    const nn = copy.copyFromUser(&new_buf, @ptrFromInt(new_ptr), 255);
    if (on == 0 or nn == 0) return -14;
    old_buf[if (on < 255) on else 255] = 0;
    new_buf[if (nn < 255) nn else 255] = 0;
    var old_len: usize = 0;
    while (old_len < 256 and old_buf[old_len] != 0) : (old_len += 1) {}
    var new_len: usize = 0;
    while (new_len < 256 and new_buf[new_len] != 0) : (new_len += 1) {}
    const ext2 = @import("../../fs/ext2.zig");
    const ok = ext2.renameFile(old_buf[0..old_len], new_buf[0..new_len]);
    return if (ok) @as(i64, 0) else @as(i64, -18); // EXDEV
}

// ── v32.4: madvise / getrlimit / setrlimit ──────────────────────────

/// madvise(addr, length, advice) — advise on memory usage.
/// Simplified: accept advice, return 0 for valid mapped regions.
fn syscallMadvise(addr: u64, length: u64, advice: u32) i64 {
    if (addr == 0 or addr >= 0x0000_8000_0000_0000) return -14; // EFAULT
    if (length == 0) return -22; // EINVAL
    const sched = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");
    const page_cache = @import("../../fs/page_cache.zig");
    const cur_idx = sched.currentTaskIndex() orelse return 0;
    const cur = tm.getTask(cur_idx) orelse return 0;

    switch (advice) {
        0 => {}, // MADV_NORMAL — default behavior
        1 => {}, // MADV_RANDOM — no special action
        2 => { // MADV_SEQUENTIAL — boost readahead for this range
            // Walk mmap regions to find files and warm page cache
            var bits = cur.mmap_active_bm;
            while (bits != 0) {
                const i: usize = @intCast(@ctz(bits));
                bits &= bits - 1;
                const r = cur.mmap_regions[i];
                if (addr >= r.base and addr < r.base + r.num_pages * 0x1000) {
                    // Record sequential access pattern for page cache
                    const start_page = (addr - r.base) / 0x1000;
                    const end_page = @min(start_page + (length + 0xFFF) / 0x1000, r.num_pages);
                    var p = start_page;
                    while (p < end_page and p < start_page + 16) : (p += 1) {
                        _ = page_cache.recordAccess(r.base, p);
                    }
                    break;
                }
            }
        },
        3 => { // MADV_WILLNEED — pre-touch pages to warm TLB/cache
            var bits = cur.mmap_active_bm;
            while (bits != 0) {
                const i: usize = @intCast(@ctz(bits));
                bits &= bits - 1;
                const r = cur.mmap_regions[i];
                if (addr >= r.base and addr < r.base + r.num_pages * 0x1000) {
                    const start_page = (addr - r.base) / 0x1000;
                    const end_page = @min(start_page + (length + 0xFFF) / 0x1000, r.num_pages);
                    var p = start_page;
                    while (p < end_page and p < start_page + 32) : (p += 1) {
                        _ = page_cache.recordAccess(r.base, p);
                    }
                    break;
                }
            }
        },
        4 => { // MADV_DONTNEED — hint that pages can be reclaimed
            // Mark as not-locked so swap/page-cache can reclaim
            var bits = cur.mmap_active_bm;
            while (bits != 0) {
                const i: usize = @intCast(@ctz(bits));
                bits &= bits - 1;
                const r = &cur.mmap_regions[i];
                if (addr >= r.base and addr < r.base + r.num_pages * 0x1000) {
                    r.locked = false;
                    break;
                }
            }
        },
        else => return -22, // EINVAL
    }
    return 0;
}

/// Resource limit entry: { cur: u64, max: u64 }
const Rlimit = extern struct {
    rlim_cur: u64 = 0,
    rlim_max: u64 = 0,
};

// Resource constants
const RLIMIT_NOFILE: u32 = 7;
const RLIMIT_STACK: u32 = 3;
const RLIMIT_AS: u32 = 9;
const RLIMIT_DATA: u32 = 2;
const RLIMIT_FSIZE: u32 = 1;
const RLIMIT_CORE: u32 = 4;
const RLIMIT_RSS: u32 = 5;
const RLIMIT_NPROC: u32 = 6;

const RLIM_INFINITY: u64 = 0xFFFF_FFFF_FFFF_FFFF;

/// getrlimit(resource, rlim_ptr) — get resource limit.
fn syscallGetrlimit(resource: u32, rlim_ptr: u64) i64 {
    if (rlim_ptr == 0 or rlim_ptr >= 0x0000_8000_0000_0000) return -14;
    const copy = @import("../../mm/copy_from_user.zig");
    const bo = @import("../../lib/byte_order.zig");

    var rlim: Rlimit = .{};
    switch (resource) {
        RLIMIT_NOFILE, RLIMIT_STACK, RLIMIT_AS, RLIMIT_DATA, RLIMIT_NPROC, RLIMIT_FSIZE => {
            const sched = @import("../../proc/sched.zig");
            const tm = @import("../../proc/task.zig");
            const idx = sched.currentTaskIndex() orelse return -3;
            const task = tm.getTask(idx) orelse return -3;
            if (resource == RLIMIT_NOFILE) {
                rlim.rlim_cur = task.nofile_cur;
                rlim.rlim_max = task.nofile_max;
            } else if (resource == RLIMIT_STACK) {
                rlim.rlim_cur = task.stack_cur;
                rlim.rlim_max = task.stack_max;
            } else if (resource == RLIMIT_AS) {
                rlim.rlim_cur = task.as_cur;
                rlim.rlim_max = task.as_max;
            } else if (resource == RLIMIT_DATA) {
                rlim.rlim_cur = task.data_cur;
                rlim.rlim_max = task.data_max;
            } else if (resource == RLIMIT_NPROC) {
                rlim.rlim_cur = task.nproc_cur;
                rlim.rlim_max = task.nproc_max;
            } else {
                rlim.rlim_cur = task.fSize_cur;
                rlim.rlim_max = task.fSize_max;
            }
        },
        RLIMIT_CORE, RLIMIT_RSS => {
            rlim.rlim_cur = RLIM_INFINITY;
            rlim.rlim_max = RLIM_INFINITY;
        },
        else => {
            rlim.rlim_cur = RLIM_INFINITY;
            rlim.rlim_max = RLIM_INFINITY;
        },
    }

    var buf: [16]u8 = undefined;
    bo.writeU64Le(buf[0..8], rlim.rlim_cur);
    bo.writeU64Le(buf[8..16], rlim.rlim_max);
    return if (copy.copyToUser(@ptrFromInt(rlim_ptr), &buf, 16) == 16) 0 else -14;
}

/// setrlimit(resource, rlim_ptr) — set resource limit.
/// Real per-task operation for RLIMIT_NOFILE and RLIMIT_STACK; other
/// resources are accepted but not enforced (return 0).
fn syscallSetrlimit(resource: u32, rlim_ptr: u64) i64 {
    if (rlim_ptr == 0 or rlim_ptr >= 0x0000_8000_0000_0000) return -14;
    const copy = @import("../../mm/copy_from_user.zig");
    const bo = @import("../../lib/byte_order.zig");
    var buf: [16]u8 = undefined;
    if (copy.copyFromUser(&buf, @ptrFromInt(rlim_ptr), 16) != 16) return -14;
    if (resource != RLIMIT_NOFILE and resource != RLIMIT_STACK and resource != RLIMIT_AS and resource != RLIMIT_DATA and resource != RLIMIT_NPROC and resource != RLIMIT_FSIZE) return 0;
    const next = @import("../../proc/rlimit.zig").Limit{ .cur = bo.readU64At(&buf, 0), .max = bo.readU64At(&buf, 8) };
    const sched = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");
    const idx = sched.currentTaskIndex() orelse return -3;
    const policy = @import("../../proc/rlimit.zig").Policy;
    const lock_flags = tm.lockTask();
    defer tm.unlockTask(lock_flags);
    const task = tm.getTask(idx) orelse return -3;
    const privileged = @field(task.effective_caps, "cap_sys_resource");
    if (resource == RLIMIT_STACK) {
        const applied = policy.applyBytes(.{ .cur = task.stack_cur, .max = task.stack_max }, next, privileged) catch |err| return switch (err) {
            error.InvalidLimit => -22,
            error.WouldLowerHardLimit => -1,
        };
        task.stack_cur = applied.cur;
        task.stack_max = applied.max;
        // Raising the soft limit widens the floor naturally on the next
        // growth fault; lowering it must lift the watermark immediately so
        // direct-map faults cannot slip in between the old watermark and the
        // new floor.
        const user_space = @import("../../mm/user_space.zig");
        const floor = policy.stackFloor(user_space.USER_STACK_TOP, user_space.USER_STACK_BOTTOM, applied.cur);
        if (task.stack_limit < floor) task.stack_limit = floor;
        return 0;
    }
    if (resource == RLIMIT_AS) {
        const applied = policy.applyBytes(.{ .cur = task.as_cur, .max = task.as_max }, next, privileged) catch |err| return switch (err) {
            error.InvalidLimit => -22,
            error.WouldLowerHardLimit => -1,
        };
        // Lowering below the current usage is legal (Linux): it only blocks
        // further charges, nothing is unmapped.
        task.as_cur = applied.cur;
        task.as_max = applied.max;
        return 0;
    }
    if (resource == RLIMIT_DATA) {
        const applied = policy.applyBytes(.{ .cur = task.data_cur, .max = task.data_max }, next, privileged) catch |err| return switch (err) {
            error.InvalidLimit => -22,
            error.WouldLowerHardLimit => -1,
        };
        // Lowering below the current usage is legal (Linux): it only blocks
        // further charges, nothing is unmapped.
        task.data_cur = applied.cur;
        task.data_max = applied.max;
        return 0;
    }
    if (resource == RLIMIT_NPROC) {
        const applied = policy.applyBytes(.{ .cur = task.nproc_cur, .max = task.nproc_max }, next, privileged) catch |err| return switch (err) {
            error.InvalidLimit => -22,
            error.WouldLowerHardLimit => -1,
        };
        // Lowering below the current live count is legal (Linux): it only
        // blocks further creations, no task is killed.
        task.nproc_cur = applied.cur;
        task.nproc_max = applied.max;
        return 0;
    }
    if (resource == RLIMIT_FSIZE) {
        const applied = policy.applyBytes(.{ .cur = task.fSize_cur, .max = task.fSize_max }, next, privileged) catch |err| return switch (err) {
            error.InvalidLimit => -22,
            error.WouldLowerHardLimit => -1,
        };
        // Lowering below the current file size is legal (Linux): it only
        // blocks further growth, existing file contents are untouched.
        task.fSize_cur = applied.cur;
        task.fSize_max = applied.max;
        return 0;
    }
    const applied = policy.apply(.{ .cur = task.nofile_cur, .max = task.nofile_max }, next, vfs_mod.MAX_FDS, privileged) catch |err| return switch (err) {
        error.InvalidLimit => -22,
        error.WouldLowerHardLimit => -1,
    };
    task.nofile_cur = applied.cur;
    task.nofile_max = applied.max;
    task.fd_table.alloc_limit = applied.cur;
    return 0;
}

// ── v32.5: umask / sysinfo / prctl ──────────────────────────────────

/// umask(mask) — set file creation mask. Returns previous mask.
fn syscallUmask(mask: u32) i64 {
    const sched_mod = @import("../../proc/sched.zig");
    const task_mod = @import("../../proc/task.zig");
    const policy = @import("../../proc/creation_metadata.zig");
    const cur_idx = sched_mod.currentTaskIndex() orelse return -3;
    const lock_flags = task_mod.lockTask();
    defer task_mod.unlockTask(lock_flags);
    const cur = task_mod.getTask(cur_idx) orelse return -3;
    return @intCast(policy.replaceTaskUmask(&cur.umask_val, mask));
}

/// sysinfo(info_ptr) — system information.
/// struct sysinfo { u64 uptime; u64 loads[3]; u64 totalram; u64 freeram;
///                  u64 sharedram; u64 bufferram; u64 totalswap; u64 freeswap;
///                  u16 procs; u16 pad; u64 totalhigh; u64 freehigh; u32 mem_unit; }
fn syscallSysinfo(info_ptr: u64) i64 {
    if (info_ptr == 0 or info_ptr >= 0x0000_8000_0000_0000) return -14;
    const copy = @import("../../mm/copy_from_user.zig");
    const tsc = @import("../../arch/x86_64/tsc.zig");
    const pmm_mod = @import("../../mm/pmm.zig");
    const bo = @import("../../lib/byte_order.zig");
    const tm = @import("../../proc/task.zig");

    const ns = tsc.nanos();
    const uptime_sec = ns / 1_000_000_000;
    const total_pages = pmm_mod.totalPages();
    const free_pages = pmm_mod.freePages();
    const page_size: u64 = 4096;

    // Count active tasks
    var proc_count: u16 = 0;
    for (0..tm.MAX_TASKS) |i| {
        if (tm.getTask(@intCast(i))) |_| proc_count += 1;
    }

    // Build sysinfo struct (128 bytes, simplified)
    var buf: [128]u8 = @splat(0);
    bo.writeU64Le(buf[0..8], uptime_sec); // uptime
    // loads[3] = 0 (no load average)
    bo.writeU64Le(buf[32..40], total_pages * page_size); // totalram
    bo.writeU64Le(buf[40..48], free_pages * page_size); // freeram
    // sharedram, bufferram = 0
    // totalswap, freeswap = 0
    buf[72] = @truncate(proc_count); // procs (u16 LE)
    buf[73] = @truncate(proc_count >> 8);
    // mem_unit = 1
    bo.writeU32Le(buf[80..84], 1);

    return if (copy.copyToUser(@ptrFromInt(info_ptr), &buf, 128) == 128) 0 else -14;
}

/// prctl(option, arg2, arg3, arg4, arg5) — process control.
/// Supports: PR_SET_NAME(15), PR_GET_NAME(16), PR_SET_PDEATHSIG(1).
fn syscallPrctl(option: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64) i64 {
    _ = arg3;
    _ = arg4;
    _ = arg5;
    const sched = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");
    const copy = @import("../../mm/copy_from_user.zig");

    const cur_idx = sched.currentTaskIndex() orelse return -3;
    const cur = tm.getTask(cur_idx) orelse return -3;

    switch (option) {
        15 => { // PR_SET_NAME
            if (arg2 == 0 or arg2 >= 0x0000_8000_0000_0000) return -14;
            var name_buf: [16]u8 = @splat(0);
            const n = copy.copyFromUser(&name_buf, @ptrFromInt(arg2), 15);
            if (n > 0) {
                @memcpy(cur.comm[0..@intCast(@min(n, 15))], name_buf[0..@intCast(@min(n, 15))]);
            }
            return 0;
        },
        16 => { // PR_GET_NAME
            if (arg2 == 0 or arg2 >= 0x0000_8000_0000_0000) return -14;
            return if (copy.copyToUser(@ptrFromInt(arg2), cur.comm[0..16], 16) == 16) 0 else -14;
        },
        1 => { // PR_SET_PDEATHSIG — store signal to send on parent death
            cur.pdeathsig = @truncate(arg2);
            return 0;
        },
        2 => { // PR_GET_PDEATHSIG — read back parent death signal
            if (arg2 == 0 or arg2 >= 0x0000_8000_0000_0000) return -14;
            var buf: [4]u8 = undefined;
            @memcpy(buf[0..4], @as(*[4]u8, @ptrCast(&cur.pdeathsig)));
            return if (copy.copyToUser(@ptrFromInt(arg2), &buf, 4) == 4) 0 else -14;
        },
        else => return -22, // EINVAL
    }
}

// ── arch_prctl ──────────────────────────────────────────────────────

const ARCH_SET_GS: u64 = 0x1001;
const ARCH_SET_FS: u64 = 0x1002;
const ARCH_GET_FS: u64 = 0x1003;
const ARCH_GET_GS: u64 = 0x1004;

/// arch_prctl(code, addr) — read or set this thread's TLS base.
///
/// Only FS is available: GS holds the kernel's per-CPU pointer, so letting user
/// space program it would hand it the kernel's own base on the next swapgs.
fn syscallArchPrctl(code: u64, addr: u64) i64 {
    const sched = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");
    const us = @import("../../mm/user_space.zig");
    const copy = @import("../../mm/copy_from_user.zig");

    const cur_idx = sched.currentTaskIndex() orelse return -22; // EINVAL
    const cur = tm.getTask(cur_idx) orelse return -22;

    switch (code) {
        ARCH_SET_FS => {
            if (addr >= us.USER_ADDR_MAX) return -22; // EINVAL — not a user address
            cur.tls_base = addr;
            setUserTlsBase(addr);
            return 0;
        },
        ARCH_GET_FS => {
            const value = cur.tls_base;
            const bytes: [*]const u8 = @ptrCast(&value);
            if (copy.copyToUser(@ptrFromInt(addr), bytes[0..8], 8) != 8) return -14; // EFAULT
            return 0;
        },
        ARCH_SET_GS, ARCH_GET_GS => return -22, // EINVAL — GS is the kernel's
        else => return -22, // EINVAL
    }
}

// ── v33.1: fsync ────────────────────────────────────────────────────

/// fsync(fd) / fdatasync(fd) — flush file's dirty buffers to disk.
fn syscallFsync(fd: u32) i64 {
    const sched = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = tm.getTask(cur_idx) orelse return -1;
    if (fd >= vfs_mod.MAX_FDS) return -9; // EBADF
    const desc = &cur.fd_table.fds[fd];
    if (desc.fd_type == .none) return -9;
    // Sync file's dirty buffers via VFS
    const wb_type: @import("../../fs/writeback.zig").FsType = switch (desc.fd_type) {
        .ext2_file => .ext2,
        .fat32_file => .fat32,
        else => .none,
    };
    if (wb_type != .none) {
        // v53.51: writeback buffers are keyed by inode_id, not by per-FS slot
        // index, so fsync addresses the file by the descriptor's inode_id.
        if (!vfs_mod.syncFile(desc.inode_id, wb_type)) return -5; // EIO
        // FAT32/ext2 currently live on block device 0. Only devices that
        // advertise a volatile write cache need a flush barrier; the others are
        // write-through, so writeback completion is already durable.
        const block_dev = @import("../../drivers/block_dev.zig");
        if (block_dev.supportsFlush(0) and block_dev.flush(0) != 0) return -5; // EIO
    }
    return 0;
}

// ── v33.2: clock_nanosleep / getcpu ─────────────────────────────────

/// clock_nanosleep(clockid, flags, req_timespec, rem_timespec) — high-res sleep.
/// flags: 0 = relative, 1 = TIMER_ABSTIME
fn syscallClockNanosleep(clockid: u32, flags: u32, req_ptr: u64, rem_ptr: u64) i64 {
    _ = clockid; // all clocks use TSC
    if (req_ptr == 0 or req_ptr >= 0x0000_8000_0000_0000) return -14;
    const copy = @import("../../mm/copy_from_user.zig");
    const tsc = @import("../../arch/x86_64/tsc.zig");
    const bo = @import("../../lib/byte_order.zig");

    var ts_buf: [16]u8 = undefined;
    if (copy.copyFromUser(&ts_buf, @ptrFromInt(req_ptr), 16) != 16) return -14;
    const sec: u64 = bo.readU64Le(ts_buf[0..8]);
    const nsec: u64 = bo.readU64Le(ts_buf[8..16]);
    const target_ns = sec * 1_000_000_000 + nsec;
    if (target_ns == 0) return 0;

    if (flags & 1 != 0) {
        // TIMER_ABSTIME: sleep until absolute time
        const now = tsc.nanos();
        if (target_ns <= now) return 0;
        const delta = target_ns - now;
        const start = tsc.nanos();
        while (tsc.nanos() - start < delta) {
            asm volatile ("pause");
        }
    } else {
        // Relative sleep
        const start = tsc.nanos();
        while (tsc.nanos() - start < target_ns) {
            asm volatile ("pause");
        }
    }

    // Write zero remaining time
    if (rem_ptr != 0 and rem_ptr < 0x0000_8000_0000_0000) {
        var zero: [16]u8 = @splat(0);
        if (copy.copyToUser(@ptrFromInt(rem_ptr), &zero, 16) != 16) return -14;
    }
    return 0;
}

/// getcpu(cpu_ptr, node_ptr, unused) — get current CPU and NUMA node.
fn syscallGetcpu(cpu_ptr: u64, node_ptr: u64) i64 {
    const copy = @import("../../mm/copy_from_user.zig");
    const pc = getPerCpu();
    const cpu_id: u32 = pc.cpu_id;

    if (cpu_ptr != 0 and cpu_ptr < 0x0000_8000_0000_0000) {
        var buf: [4]u8 = undefined;
        buf[0] = @truncate(cpu_id);
        buf[1] = @truncate(cpu_id >> 8);
        buf[2] = @truncate(cpu_id >> 16);
        buf[3] = @truncate(cpu_id >> 24);
        if (copy.copyToUser(@ptrFromInt(cpu_ptr), &buf, 4) != 4) return -14;
    }
    if (node_ptr != 0 and node_ptr < 0x0000_8000_0000_0000) {
        var buf: [4]u8 = .{ 0, 0, 0, 0 }; // NUMA node 0
        if (copy.copyToUser(@ptrFromInt(node_ptr), &buf, 4) != 4) return -14;
    }
    return 0;
}

// ── v33.3: pipe2 / mincore ──────────────────────────────────────────

/// pipe2(pipefd_ptr, flags) — create pipe with O_CLOEXEC/O_NONBLOCK.
fn syscallPipe2(pipefd_ptr: u64, flags: u32) i64 {
    if (pipefd_ptr == 0 or pipefd_ptr >= 0x0000_8000_0000_0000) return -14;
    const copy = @import("../../mm/copy_from_user.zig");
    if (!copy.validateUserBufferWritable(pipefd_ptr, 8)) return -14;
    const sched = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");
    const cur_idx = sched.currentTaskIndex() orelse return -3;
    const cur = tm.getTask(cur_idx) orelse return -3;
    const result = cur.fd_table.createPipe();
    if (result < 0) return result;
    const read_fd: u32 = @intCast(@as(u64, @intCast(result & 0xFFFF)));
    const write_fd: u32 = @intCast(@as(u64, @intCast(result >> 16)) & 0xFFFF);

    const O_CLOEXEC: u32 = 0x80000;
    if (flags & O_CLOEXEC != 0) {
        if (read_fd < vfs_mod.MAX_FDS) cur.fd_table.fds[read_fd].fd_flags = 1;
        if (write_fd < vfs_mod.MAX_FDS) cur.fd_table.fds[write_fd].fd_flags = 1;
    }

    const bo = @import("../../lib/byte_order.zig");
    var fds: [8]u8 = undefined;
    bo.writeU32Le(fds[0..4], read_fd);
    bo.writeU32Le(fds[4..8], write_fd);
    if (copy.copyToUser(@ptrFromInt(pipefd_ptr), &fds, 8) != 8) {
        _ = cur.fd_table.close(read_fd);
        _ = cur.fd_table.close(write_fd);
        return -14;
    }
    return 0;
}

/// mincore(addr, length, vec_ptr) — check if pages are resident in RAM.
/// Simplified: report all pages as resident (1) for mapped regions.
fn syscallMincore(addr: u64, length: u64, vec_ptr: u64) i64 {
    if (addr == 0 or addr >= 0x0000_8000_0000_0000) return -14;
    if (length == 0) return 0;
    if (vec_ptr == 0 or vec_ptr >= 0x0000_8000_0000_0000) return -14;
    if (addr & 0xFFF != 0) return -22; // EINVAL: not page-aligned

    const copy = @import("../../mm/copy_from_user.zig");
    const num_pages = (length + 4095) / 4096;
    if (!copy.validateUserBufferWritable(vec_ptr, @intCast(num_pages))) return -14;

    // Write all-ones (all pages resident)
    var i: u64 = 0;
    while (i < num_pages) : (i += 1) {
        const byte: u8 = 1; // page resident
        if (copy.copyToUser(@ptrFromInt(vec_ptr + i), @as([*]const u8, @ptrCast(&byte))[0..1], 1) != 1) return -14;
    }
    return 0;
}

// ── v34.0: Global hostname / domainname ──────────────────────────────────────
var kernel_hostname: [64]u8 = .{0} ** 64;
var kernel_hostname_len: u32 = 0;
var kernel_domainname: [64]u8 = .{0} ** 64;
var kernel_domainname_len: u32 = 0;

// Initialize default hostname
fn initHostname() void {
    const default = "moqios";
    @memcpy(kernel_hostname[0..default.len], default);
    kernel_hostname_len = default.len;
}

// ── v34.0: Syscall function implementations ───────────────────────────────────

/// #263 wait4(pid, status, options, rusage) — waitpid with rusage (rusage ignored)
fn syscallWait4(pid: u64, status_ptr: u64, options: u32, rusage_ptr: u64) i64 {
    const copy = @import("../../mm/copy_from_user.zig");
    if (rusage_ptr != 0 and !copy.validateUserBufferWritable(rusage_ptr, 144)) return -14;
    // Zero rusage if provided
    if (rusage_ptr != 0) {
        var zero_buf: [144]u8 = .{0} ** 144; // struct rusage is ~144 bytes
        if (copy.copyToUser(@ptrFromInt(rusage_ptr), &zero_buf, 144) != 144) return -14;
    }

    return waitpid_mod.waitpidWithOptions(pid, status_ptr, options);
}

/// #264 sethostname(name, len)
fn syscallSethostname(name_ptr: u64, len: u32) i64 {
    if (name_ptr == 0 or name_ptr >= 0x0000_8000_0000_0000) return -14; // EFAULT
    if (len > 64) return -22; // EINVAL
    if (kernel_hostname_len == 0) initHostname();
    const copy = @import("../../mm/copy_from_user.zig");
    var buf: [64]u8 = .{0} ** 64;
    const copied = copy.copyFromUser(&buf, @ptrFromInt(name_ptr), len);
    if (copied < len) return -14;
    @memcpy(&kernel_hostname, &buf);
    kernel_hostname_len = len;
    return 0;
}

/// #265 gethostname(name, len)
fn syscallGethostname(name_ptr: u64, len: u32) i64 {
    if (name_ptr == 0 or name_ptr >= 0x0000_8000_0000_0000) return -14;
    if (kernel_hostname_len == 0) initHostname();
    const copy = @import("../../mm/copy_from_user.zig");
    const to_copy = @min(len, kernel_hostname_len);
    if (!copy.validateUserBufferWritable(name_ptr, if (to_copy < len) to_copy + 1 else to_copy)) return -14;
    if (copy.copyToUser(@ptrFromInt(name_ptr), kernel_hostname[0..to_copy], to_copy) != to_copy) return -14;
    // NUL-terminate if space
    if (to_copy < len) {
        const zero: u8 = 0;
        if (copy.copyToUser(@ptrFromInt(name_ptr + to_copy), @as([*]const u8, @ptrCast(&zero))[0..1], 1) != 1) return -14;
    }
    return 0;
}

/// #266 setdomainname(name, len)
fn syscallSetdomainname(name_ptr: u64, len: u32) i64 {
    if (name_ptr == 0 or name_ptr >= 0x0000_8000_0000_0000) return -14;
    if (len > 64) return -22;
    const copy = @import("../../mm/copy_from_user.zig");
    var buf: [64]u8 = .{0} ** 64;
    const copied = copy.copyFromUser(&buf, @ptrFromInt(name_ptr), len);
    if (copied < len) return -14;
    @memcpy(&kernel_domainname, &buf);
    kernel_domainname_len = len;
    return 0;
}

/// #267 getdomainname(name, len)
fn syscallGetdomainname(name_ptr: u64, len: u32) i64 {
    if (name_ptr == 0 or name_ptr >= 0x0000_8000_0000_0000) return -14;
    const copy = @import("../../mm/copy_from_user.zig");
    const to_copy = @min(len, kernel_domainname_len);
    if (!copy.validateUserBufferWritable(name_ptr, if (to_copy < len) to_copy + 1 else to_copy)) return -14;
    if (to_copy > 0) {
        if (copy.copyToUser(@ptrFromInt(name_ptr), kernel_domainname[0..to_copy], to_copy) != to_copy) return -14;
    }
    if (to_copy < len) {
        const zero: u8 = 0;
        if (copy.copyToUser(@ptrFromInt(name_ptr + to_copy), @as([*]const u8, @ptrCast(&zero))[0..1], 1) != 1) return -14;
    }
    return 0;
}

/// #268 personality(persona) — get/set process personality
fn syscallPersonality(persona: u32) i64 {
    const sched = @import("../../proc/sched.zig");
    const task_mod2 = @import("../../proc/task.zig");
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = task_mod2.getTask(cur_idx) orelse return -1;
    const old_val: u32 = @intFromEnum(cur.personality);
    if (persona != 0xFFFFFFFF) { // 0xFFFFFFFF = query only
        switch (persona & 0xFF) {
            0 => cur.personality = .native,
            1 => cur.personality = .linux,
            2 => cur.personality = .windows,
            else => return -22, // EINVAL
        }
    }
    return @intCast(old_val);
}

/// #269 clock_getres(clockid, res) — return clock resolution
fn syscallClockGetres(clockid: u32, res_ptr: u64) i64 {
    _ = clockid; // All clocks report same resolution
    if (res_ptr == 0) return 0; // NULL is valid (just validates clockid)
    if (res_ptr >= 0x0000_8000_0000_0000) return -14;
    const copy = @import("../../mm/copy_from_user.zig");
    // struct timespec { i64 tv_sec; i64 tv_nsec; }
    // Report 1ns resolution (TSC-based high precision)
    var ts: [16]u8 = undefined;
    const sec: u64 = 0;
    const nsec: u64 = 1; // 1 nanosecond resolution
    @memcpy(ts[0..8], @as([*]const u8, @ptrCast(&sec))[0..8]);
    @memcpy(ts[8..16], @as([*]const u8, @ptrCast(&nsec))[0..8]);
    return if (copy.copyToUser(@ptrFromInt(res_ptr), &ts, 16) == 16) 0 else -14;
}

/// #273 sched_setaffinity(pid, cpusetsize, mask) — store CPU affinity mask
fn syscallSchedSetaffinity(pid: u32, cpusetsize: u32, mask_ptr: u64) i64 {
    const sched = @import("../../proc/sched.zig");
    const task_mod2 = @import("../../proc/task.zig");
    if (mask_ptr == 0 or mask_ptr >= 0x0000_8000_0000_0000) return -14;
    if (cpusetsize == 0 or cpusetsize > 128) return -22;

    // Find target task (pid=0 means current)
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    var target_idx = cur_idx;
    if (pid != 0) {
        // Search for task with matching tid
        var found = false;
        var i: u32 = 0;
        while (i < 256) : (i += 1) {
            if (task_mod2.getTask(i)) |t| {
                if (t.tid == pid) {
                    target_idx = i;
                    found = true;
                    break;
                }
            }
        }
        if (!found) return -3; // ESRCH
    }

    const target = task_mod2.getTask(target_idx) orelse return -1;
    const copy = @import("../../mm/copy_from_user.zig");
    var mask_buf: [32]u8 = .{0} ** 32;
    // NOTE: explicit u32 — @min(u32, comptime 32) would narrow to u6, and
    // `to_copy * 8` below then overflows (panic) for any cpusetsize >= 8.
    const to_copy: u32 = @min(cpusetsize, mask_buf.len);
    const copied = copy.copyFromUser(mask_buf[0..to_copy], @ptrFromInt(mask_ptr), to_copy);
    if (copied < to_copy) return -14;

    // Store the lowest selected logical CPU, or -1 for an empty mask.
    var affinity: i16 = -1;
    if (to_copy > 0) {
        // Find lowest set bit in mask
        var b: u32 = 0;
        while (b < to_copy * 8) : (b += 1) {
            const byte_idx = b / 8;
            const bit_idx: u3 = @intCast(b % 8);
            if (mask_buf[byte_idx] & (@as(u8, 1) << bit_idx) != 0) {
                affinity = @intCast(b);
                break;
            }
        }
    }
    if (affinity < 0 or @as(u32, @intCast(affinity)) >= @import("../../smp.zig").configured_cpu_count) return -22;
    target.cpu_affinity = affinity;

    // Migrate a live task whose current CPU falls outside the new pin —
    // otherwise a running task keeps its old CPU forever (observed: hello44
    // pinned itself to CPU 0 while running elsewhere, then its "same-CPU"
    // FIFO test ran concurrently with the child). Enqueue onto the pin CPU's
    // queue FIRST so a runnable copy always waits there, then make the
    // current CPU switch away (to idle if nothing else is runnable) — a bare
    // reschedule is not enough: with no other runnable work the scheduler
    // just keeps the task on the wrong CPU (flaky migration).
    if (target.state == .running and
        target.last_cpu != @as(u32, @intCast(target.cpu_affinity)))
    {
        const pin_cpu: u8 = @intCast(target.cpu_affinity);
        _ = @import("../../proc/per_cpu.zig").enqueueTask(target);
        sched.kickCpu(pin_cpu);
        if (target_idx == cur_idx) {
            sched.forceReschedule();
        } else {
            sched.kickCpu(@intCast(target.last_cpu));
        }
    }
    return 0;
}

/// #276 statfs(path, buf) — return filesystem statistics
fn syscallStatfs(path_ptr: u64, buf_ptr: u64) i64 {
    _ = path_ptr; // Ignore path, return global fs stats
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000) return -14;
    return writeStatfsBuf(buf_ptr);
}

/// #277 fstatfs(fd, buf) — return filesystem statistics for open file
fn syscallFstatfs(fd: u32, buf_ptr: u64) i64 {
    const sched = @import("../../proc/sched.zig");
    const task_mod2 = @import("../../proc/task.zig");
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000) return -14;
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = task_mod2.getTask(cur_idx) orelse return -1;
    if (fd >= vfs_mod.MAX_FDS or cur.fd_table.fds[fd].fd_type == .none) return -9; // EBADF
    return writeStatfsBuf(buf_ptr);
}

/// Write struct statfs buffer (120 bytes on Linux x86_64)
fn writeStatfsBuf(buf_ptr: u64) i64 {
    const copy = @import("../../mm/copy_from_user.zig");
    var buf: [120]u8 = .{0} ** 120;
    // struct statfs:
    //   i64 f_type    (offset 0)  — filesystem type (0xEF53 = ext2/ext3)
    //   i64 f_bsize   (offset 8)  — block size
    //   i64 f_blocks  (offset 16) — total blocks
    //   i64 f_bfree   (offset 24) — free blocks
    //   i64 f_bavail  (offset 32) — available blocks
    //   i64 f_files   (offset 40) — total inodes
    //   i64 f_ffree   (offset 48) — free inodes
    //   i64 f_fsid    (offset 56) — filesystem ID
    //   i64 f_namelen (offset 64) — max filename length
    //   i64 f_frsize  (offset 72) — fragment size
    //   i64 f_flags   (offset 80) — mount flags
    const f_type: u64 = 0xEF53; // ext2/3/4 magic
    const f_bsize: u64 = 4096;
    const f_blocks: u64 = 1024 * 1024; // 4GB virtual disk
    const f_bfree: u64 = 512 * 1024; // 2GB free
    const f_bavail: u64 = 512 * 1024;
    const f_files: u64 = 65536;
    const f_ffree: u64 = 32768;
    const f_namelen: u64 = 255;
    const f_frsize: u64 = 4096;
    const f_flags: u64 = 0;
    @memcpy(buf[0..8], @as([*]const u8, @ptrCast(&f_type))[0..8]);
    @memcpy(buf[8..16], @as([*]const u8, @ptrCast(&f_bsize))[0..8]);
    @memcpy(buf[16..24], @as([*]const u8, @ptrCast(&f_blocks))[0..8]);
    @memcpy(buf[24..32], @as([*]const u8, @ptrCast(&f_bfree))[0..8]);
    @memcpy(buf[32..40], @as([*]const u8, @ptrCast(&f_bavail))[0..8]);
    @memcpy(buf[40..48], @as([*]const u8, @ptrCast(&f_files))[0..8]);
    @memcpy(buf[48..56], @as([*]const u8, @ptrCast(&f_ffree))[0..8]);
    // f_fsid (offset 56) = 0
    @memcpy(buf[64..72], @as([*]const u8, @ptrCast(&f_namelen))[0..8]);
    @memcpy(buf[72..80], @as([*]const u8, @ptrCast(&f_frsize))[0..8]);
    @memcpy(buf[80..88], @as([*]const u8, @ptrCast(&f_flags))[0..8]);
    return if (copy.copyToUser(@ptrFromInt(buf_ptr), &buf, 120) == 120) 0 else -14;
}

/// #278 syslog(type, buf, len) — kernel log control
fn syscallSyslog(log_type: u32, buf_ptr: u64, len: u32) i64 {
    _ = buf_ptr;
    _ = len;
    // type 3 = read, type 7 = set log level, type 10 = size of log buffer
    switch (log_type) {
        3 => return 0, // read: no buffered log data
        7 => return 0, // set level: accept but ignore
        10 => return 0, // size of log buffer: 0
        else => return 0,
    }
}

/// #279 reboot(cmd) — system reboot/halt
fn syscallReboot(cmd: u32) i64 {
    const klog = @import("../../klog.zig");
    switch (cmd) {
        0x01234567, // LINUX_REBOOT_CMD_RESTART
        0x4321FEDC, // LINUX_REBOOT_CMD_RESTART2
        => {
            klog.log(.info, "[reboot] system restart requested");
            // Triple fault via invalid IDT entry
            asm volatile (
                \\cli
                \\lidt (%%rax)
                \\int $0x80
                :
                : [addr] "{rax}" (@as(u64, 0)),
            );
            unreachable;
        },
        0xCDEF0123 => { // LINUX_REBOOT_CMD_HALT
            klog.log(.info, "[reboot] system halt requested");
            asm volatile ("cli; hlt");
            unreachable;
        },
        else => return -22, // EINVAL: unknown command
    }
}

/// #280 chroot(path) — change root directory (simplified: store in task cwd)
fn syscallChroot(path_ptr: u64) i64 {
    // For now, validate path exists and accept
    // Real chroot requires a root_path field in Task struct
    if (path_ptr == 0 or path_ptr >= 0x0000_8000_0000_0000) return -14;
    const copy = @import("../../mm/copy_from_user.zig");
    var path_buf: [256]u8 = undefined;
    const copied = copy.copyFromUser(path_buf[0..], @ptrFromInt(path_ptr), 255);
    if (copied == 0) return -14;
    path_buf[if (copied < 255) copied else 255] = 0;
    // Accept chroot — just log it for now
    serial.writeString("[chroot] path: ");
    serial.writeString(path_buf[0..copied]);
    serial.writeString("\n");
    return 0;
}

// ── v36.0: prlimit64 / process_vm_readv/writev / memfd_create ───────────────

/// prlimit64(pid, resource, new_limit, old_limit) — get/set resource limits
/// for any process. pid=0 means current process.
fn syscallPrlimit64(pid: u32, resource: u32, new_limit_ptr: u64, old_limit_ptr: u64) i64 {
    const copy = @import("../../mm/copy_from_user.zig");
    const bo = @import("../../lib/byte_order.zig");
    const tm = @import("../../proc/task.zig");
    const sched_mod = @import("../../proc/sched.zig");
    const caller_idx = sched_mod.currentTaskIndex() orelse return -3;
    var target_tid: u32 = 0;
    var old_limit: Rlimit = .{};
    var privileged = false;
    {
        const lock_flags = tm.lockTask();
        defer tm.unlockTask(lock_flags);
        const caller = tm.getTask(caller_idx) orelse return -3;
        target_tid = if (pid == 0) caller.tid else pid;
        const target_idx = tm.findTaskByTidLocked(target_tid) orelse return -3;
        const target = tm.getTask(target_idx) orelse return -3;
        if (target_tid != caller.tid and !@field(caller.effective_caps, "cap_sys_resource")) return -1;
        privileged = @field(caller.effective_caps, "cap_sys_resource");

        switch (resource) {
            RLIMIT_NOFILE => {
                old_limit.rlim_cur = target.nofile_cur;
                old_limit.rlim_max = target.nofile_max;
            },
            RLIMIT_STACK => {
                old_limit.rlim_cur = target.stack_cur;
                old_limit.rlim_max = target.stack_max;
            },
            RLIMIT_AS => {
                old_limit.rlim_cur = target.as_cur;
                old_limit.rlim_max = target.as_max;
            },
            RLIMIT_DATA => {
                old_limit.rlim_cur = target.data_cur;
                old_limit.rlim_max = target.data_max;
            },
            RLIMIT_NPROC => {
                old_limit.rlim_cur = target.nproc_cur;
                old_limit.rlim_max = target.nproc_max;
            },
            RLIMIT_FSIZE => {
                old_limit.rlim_cur = target.fSize_cur;
                old_limit.rlim_max = target.fSize_max;
            },
            else => {
                old_limit.rlim_cur = RLIM_INFINITY;
                old_limit.rlim_max = RLIM_INFINITY;
            },
        }
    }

    if (old_limit_ptr != 0) {
        if (old_limit_ptr >= 0x0000_8000_0000_0000) return -14;
        var buf: [16]u8 = undefined;
        bo.writeU64Le(buf[0..8], old_limit.rlim_cur);
        bo.writeU64Le(buf[8..16], old_limit.rlim_max);
        if (copy.copyToUser(@ptrFromInt(old_limit_ptr), &buf, 16) != 16) return -14;
    }

    if (new_limit_ptr != 0) {
        if (new_limit_ptr >= 0x0000_8000_0000_0000) return -14;
        var nbuf: [16]u8 = undefined;
        if (copy.copyFromUser(nbuf[0..], @ptrFromInt(new_limit_ptr), 16) != 16) return -14;
        if (resource == RLIMIT_NOFILE or resource == RLIMIT_STACK or resource == RLIMIT_AS or resource == RLIMIT_DATA or resource == RLIMIT_NPROC or resource == RLIMIT_FSIZE) {
            const next = @import("../../proc/rlimit.zig").Limit{ .cur = bo.readU64At(&nbuf, 0), .max = bo.readU64At(&nbuf, 8) };
            const policy = @import("../../proc/rlimit.zig").Policy;
            const lock_flags = tm.lockTask();
            defer tm.unlockTask(lock_flags);
            const target_idx = tm.findTaskByTidLocked(target_tid) orelse return -3;
            const target = tm.getTask(target_idx) orelse return -3;
            if (resource == RLIMIT_STACK) {
                const applied = policy.applyBytes(.{ .cur = target.stack_cur, .max = target.stack_max }, next, privileged) catch |err| return switch (err) {
                    error.InvalidLimit => -22,
                    error.WouldLowerHardLimit => -1,
                };
                target.stack_cur = applied.cur;
                target.stack_max = applied.max;
                const user_space = @import("../../mm/user_space.zig");
                const floor = policy.stackFloor(user_space.USER_STACK_TOP, user_space.USER_STACK_BOTTOM, applied.cur);
                if (target.stack_limit < floor) target.stack_limit = floor;
            } else if (resource == RLIMIT_AS) {
                const applied = policy.applyBytes(.{ .cur = target.as_cur, .max = target.as_max }, next, privileged) catch |err| return switch (err) {
                    error.InvalidLimit => -22,
                    error.WouldLowerHardLimit => -1,
                };
                target.as_cur = applied.cur;
                target.as_max = applied.max;
            } else if (resource == RLIMIT_DATA) {
                const applied = policy.applyBytes(.{ .cur = target.data_cur, .max = target.data_max }, next, privileged) catch |err| return switch (err) {
                    error.InvalidLimit => -22,
                    error.WouldLowerHardLimit => -1,
                };
                target.data_cur = applied.cur;
                target.data_max = applied.max;
            } else if (resource == RLIMIT_NPROC) {
                const applied = policy.applyBytes(.{ .cur = target.nproc_cur, .max = target.nproc_max }, next, privileged) catch |err| return switch (err) {
                    error.InvalidLimit => -22,
                    error.WouldLowerHardLimit => -1,
                };
                target.nproc_cur = applied.cur;
                target.nproc_max = applied.max;
            } else if (resource == RLIMIT_FSIZE) {
                const applied = policy.applyBytes(.{ .cur = target.fSize_cur, .max = target.fSize_max }, next, privileged) catch |err| return switch (err) {
                    error.InvalidLimit => -22,
                    error.WouldLowerHardLimit => -1,
                };
                target.fSize_cur = applied.cur;
                target.fSize_max = applied.max;
            } else {
                const applied = policy.apply(.{ .cur = target.nofile_cur, .max = target.nofile_max }, next, vfs_mod.MAX_FDS, privileged) catch |err| return switch (err) {
                    error.InvalidLimit => -22,
                    error.WouldLowerHardLimit => -1,
                };
                target.nofile_cur = applied.cur;
                target.nofile_max = applied.max;
                target.fd_table.alloc_limit = applied.cur;
            }
        }
    }
    return 0;
}

/// process_vm_readv(pid, local_iov, liovcnt, remote_iov, riovcnt, flags)
/// Read memory from remote process into local buffers.
/// Used by debuggers and /proc/<pid>/mem readers.
fn syscallProcessVmReadv(pid: u32, local_iov_ptr: u64, liovcnt: u32, remote_iov_ptr: u64, riovcnt: u32) i64 {
    _ = pid;
    if (local_iov_ptr == 0 or local_iov_ptr >= 0x0000_8000_0000_0000) return -14;
    if (remote_iov_ptr == 0 or remote_iov_ptr >= 0x0000_8000_0000_0000) return -14;
    if (liovcnt != riovcnt) return -22; // EINVAL

    const copy = @import("../../mm/copy_from_user.zig");
    const bo = @import("../../lib/byte_order.zig");

    // For each iovec pair, copy remote → local
    var total: i64 = 0;
    var idx: u32 = 0;
    while (idx < liovcnt) : (idx += 1) {
        // Read local iovec (base, len)
        var liov_buf: [16]u8 = undefined;
        const l_off = @as(u64, idx) * 16;
        _ = copy.copyFromUser(liov_buf[0..], @ptrFromInt(local_iov_ptr + l_off), 16);
        const l_base: u64 = bo.readU64At(&liov_buf, 0);
        const l_len: u64 = bo.readU64At(&liov_buf, 8);

        // Read remote iovec
        var riov_buf: [16]u8 = undefined;
        const r_off = @as(u64, idx) * 16;
        _ = copy.copyFromUser(riov_buf[0..], @ptrFromInt(remote_iov_ptr + r_off), 16);
        const r_base: u64 = bo.readU64At(&riov_buf, 0);
        const r_len: u64 = bo.readU64At(&riov_buf, 8);

        const n: u64 = @min(l_len, r_len);
        if (n > 0 and l_base > 0 and l_base < 0x0000_8000_0000_0000 and
            r_base > 0 and r_base < 0x0000_8000_0000_0000)
        {
            // Copy remote → kernel buffer → local (same address space in single-process)
            var kbuf: [4096]u8 = undefined;
            const chunk: usize = @intCast(@min(n, 4096));
            const from_remote = copy.copyFromUser(kbuf[0..chunk], @ptrFromInt(r_base), chunk);
            if (from_remote > 0) {
                const to_local = copy.copyToUser(@ptrFromInt(l_base), kbuf[0..from_remote], from_remote);
                total += @as(i64, @intCast(to_local));
            }
        }
    }
    return total;
}

/// process_vm_writev(pid, local_iov, liovcnt, remote_iov, riovcnt, flags)
/// Write local buffers into remote process memory.
fn syscallProcessVmWritev(pid: u32, local_iov_ptr: u64, liovcnt: u32, remote_iov_ptr: u64, riovcnt: u32) i64 {
    _ = pid;
    if (local_iov_ptr == 0 or local_iov_ptr >= 0x0000_8000_0000_0000) return -14;
    if (remote_iov_ptr == 0 or remote_iov_ptr >= 0x0000_8000_0000_0000) return -14;
    if (liovcnt != riovcnt) return -22;

    const copy = @import("../../mm/copy_from_user.zig");
    const bo = @import("../../lib/byte_order.zig");

    var total: i64 = 0;
    var idx: u32 = 0;
    while (idx < liovcnt) : (idx += 1) {
        var liov_buf: [16]u8 = undefined;
        const l_off = @as(u64, idx) * 16;
        _ = copy.copyFromUser(liov_buf[0..], @ptrFromInt(local_iov_ptr + l_off), 16);
        const l_base: u64 = bo.readU64At(&liov_buf, 0);
        const l_len: u64 = bo.readU64At(&liov_buf, 8);

        var riov_buf: [16]u8 = undefined;
        const r_off = @as(u64, idx) * 16;
        _ = copy.copyFromUser(riov_buf[0..], @ptrFromInt(remote_iov_ptr + r_off), 16);
        const r_base: u64 = bo.readU64At(&riov_buf, 0);
        const r_len: u64 = bo.readU64At(&riov_buf, 8);

        const n: u64 = @min(l_len, r_len);
        if (n > 0 and l_base > 0 and l_base < 0x0000_8000_0000_0000 and
            r_base > 0 and r_base < 0x0000_8000_0000_0000)
        {
            // Copy local → kernel buffer → remote
            var kbuf: [4096]u8 = undefined;
            const chunk: usize = @intCast(@min(n, 4096));
            const from_local = copy.copyFromUser(kbuf[0..chunk], @ptrFromInt(l_base), chunk);
            if (from_local > 0) {
                const to_remote = copy.copyToUser(@ptrFromInt(r_base), kbuf[0..from_local], from_local);
                total += @as(i64, @intCast(to_remote));
            }
        }
    }
    return total;
}

/// memfd_create(name_ptr, flags) — create an anonymous memory-backed file descriptor.
/// Returns a new fd that behaves like a tmpfs file (backed by anonymous pipe).
fn syscallMemfdCreate(name_ptr: u64, flags: u32) i64 {
    _ = flags;
    _ = name_ptr; // name is only for debugging (/proc/self/fd/ symlink)

    const sched_mod = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = tm.getTask(cur_idx) orelse return -1;

    // v53.50: Use allocFd() — previously used linear scan bypassing free_bm bitmap
    const fd_slot = t.fd_table.allocFd() orelse return -24; // EMFILE

    // Allocate an anonymous pipe as memfd (reusing pipe infrastructure)
    const pipe_idx = vfs_mod.allocPipe() orelse {
        t.fd_table.freeFd(fd_slot); // v53.50: restore fd slot on allocPipe failure
        return -28; // ENOSPC
    };
    // allocPipe sets ref_count=2 (for read+write ends), but memfd is a single fd.
    // Reduce ref_count to 1 since we only hold one reference.
    if (!vfs_mod.pipeMakeSingleEnded(pipe_idx)) {
        vfs_mod.pipeClose(pipe_idx, false);
        vfs_mod.pipeClose(pipe_idx, true);
        t.fd_table.freeFd(fd_slot);
        return -5;
    }
    t.fd_table.fds[fd_slot] = .{
        .fd_type = .pipe_read,
        .pipe_idx = pipe_idx,
        .writable = true,
    };

    return @intCast(fd_slot);
}

// ── v36.0: robust_list / mount / umount2 ────────────────────────────────────

/// get_robust_list(pid, head_ptr, len_ptr) — get robust futex list head.
fn syscallGetRobustList(pid: u32, head_ptr: u64, len_ptr: u64) i64 {
    if (head_ptr == 0 or head_ptr >= 0x0000_8000_0000_0000) return -14;
    if (len_ptr == 0 or len_ptr >= 0x0000_8000_0000_0000) return -14;

    const copy = @import("../../mm/copy_from_user.zig");
    const bo = @import("../../lib/byte_order.zig");
    const tm = @import("../../proc/task.zig");
    const sched_mod = @import("../../proc/sched.zig");

    var target: *const tm.Task = undefined;
    if (pid == 0) {
        const cur_idx = sched_mod.currentTaskIndex() orelse return -3;
        target = tm.getTask(cur_idx) orelse return -3;
    } else {
        var found = false;
        var i: u32 = 0;
        while (i < tm.MAX_TASKS) : (i += 1) {
            if (tm.getTask(i)) |t| {
                if (t.tid == pid and t.state != .zombie) {
                    target = t;
                    found = true;
                    break;
                }
            }
        }
        if (!found) return -3;
    }

    // Write head pointer
    var hbuf: [8]u8 = undefined;
    bo.writeU64Le(hbuf[0..8], target.robust_list_head);
    if (copy.copyToUser(@ptrFromInt(head_ptr), hbuf[0..], 8) != 8) return -14;

    // Write len (sizeof(struct robust_list_head) = 24 on x86_64)
    var lbuf: [8]u8 = undefined;
    const list_len: u64 = if (target.robust_list_len > 0) @intCast(target.robust_list_len) else 24;
    bo.writeU64Le(lbuf[0..8], list_len);
    if (copy.copyToUser(@ptrFromInt(len_ptr), lbuf[0..], 8) != 8) return -14;

    return 0;
}

/// set_robust_list(head, len) — set robust futex list for current process.
fn syscallSetRobustList(head: u64, len: u32) i64 {
    if (len != 0 and len != 24) return -22; // EINVAL: must be sizeof(struct robust_list_head)
    const sched_mod = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = tm.getTask(cur_idx) orelse return -1;
    t.robust_list_head = head;
    t.robust_list_len = len;
    return 0;
}

/// mount(source, target, fs_type, flags) — mount a filesystem.
/// Reads strings from user space and delegates to vfs.mountFs.
fn syscallMount(source_ptr: u64, target_ptr: u64, fstype_ptr: u64, flags: u64) i64 {
    const copy = @import("../../mm/copy_from_user.zig");

    var src_buf: [64]u8 = .{0} ** 64;
    var tgt_buf: [128]u8 = .{0} ** 128;
    var fst_buf: [16]u8 = .{0} ** 16;

    if (source_ptr != 0 and source_ptr < 0x0000_8000_0000_0000) {
        _ = copy.copyFromUser(src_buf[0..], @ptrFromInt(source_ptr), 63);
    }
    if (target_ptr == 0 or target_ptr >= 0x0000_8000_0000_0000) return -14;
    _ = copy.copyFromUser(tgt_buf[0..], @ptrFromInt(target_ptr), 127);
    if (fstype_ptr != 0 and fstype_ptr < 0x0000_8000_0000_0000) {
        _ = copy.copyFromUser(fst_buf[0..], @ptrFromInt(fstype_ptr), 15);
    }

    // Find string lengths
    const src_len = strLen(src_buf[0..]);
    const tgt_len = strLen(tgt_buf[0..]);
    const fst_len = strLen(fst_buf[0..]);

    return vfs_mod.mountFs(src_buf[0..src_len], tgt_buf[0..tgt_len], fst_buf[0..fst_len], flags);
}

/// umount2(target, flags) — unmount a filesystem.
fn syscallUmount2(target_ptr: u64, flags: u32) i64 {
    if (target_ptr == 0 or target_ptr >= 0x0000_8000_0000_0000) return -14;
    const copy = @import("../../mm/copy_from_user.zig");
    var tgt_buf: [128]u8 = .{0} ** 128;
    _ = copy.copyFromUser(tgt_buf[0..], @ptrFromInt(target_ptr), 127);
    const tgt_len = strLen(tgt_buf[0..]);

    return vfs_mod.umountFs(tgt_buf[0..tgt_len], flags);
}

// ── v36.0: sync_file_range / readahead / ioprio ─────────────────────────────

/// sync_file_range(fd, offset, nbytes, flags) — flush dirty pages for a file range.
/// flags: SYNC_FILE_RANGE_WAIT_BEFORE=1, SYNC_FILE_RANGE_WRITE=2, SYNC_FILE_RANGE_WAIT_AFTER=4.
fn syscallSyncFileRange(fd: u32, offset: u64, nbytes: u64, flags: u32) i64 {
    const sched_mod = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");
    const policy = @import("../../fs/sync_file_range_policy.zig");
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = tm.getTask(cur_idx) orelse return -1;
    if (fd >= vfs_mod.MAX_FDS) return -9;
    const desc = &t.fd_table.fds[fd];
    if (desc.fd_type == .none) return -9;
    const fs_type: @import("../../fs/writeback.zig").FsType = switch (desc.fd_type) {
        .ext2_file => .ext2,
        .fat32_file => .fat32,
        else => return -22,
    };
    const range = policy.validate(offset, nbytes, flags) catch |err| return switch (err) {
        error.InvalidFlags, error.InvalidOffset, error.RangeOverflow => -22,
    };
    if (range.page_count == 0) return 0;
    if (!vfs_mod.syncFileRange(desc.inode_id, fs_type, offset, offset + nbytes)) return -5;
    return 0;
}

/// readahead(fd, offset, count) — prefetch file pages into page cache.
/// Valid requests are advisory; filesystem prefetch failures are intentionally silent.
fn syscallReadahead(fd: u32, offset: u64, count: u64) i64 {
    const sched_mod = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");
    const policy = @import("../../fs/readahead_policy.zig");
    const ext2_mod = @import("../../fs/ext2.zig");
    const fat32_mod = @import("../../fs/fat32.zig");
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = tm.getTask(cur_idx) orelse return -1;
    if (fd >= vfs_mod.MAX_FDS) return -9;
    const desc = &t.fd_table.fds[fd];
    if (desc.fd_type == .none) return -9;
    if (desc.fd_type != .ext2_file and desc.fd_type != .fat32_file) return -22;
    const range = policy.validate(offset, count) catch return -22;
    if (range.page_count == 0) return 0;
    const file_size = switch (desc.fd_type) {
        .ext2_file => ext2_mod.getFileSize(desc.ext2_file_idx),
        .fat32_file => fat32_mod.getFileSize(desc.fat32_file_idx),
        else => unreachable,
    };
    if (offset >= file_size) return 0;
    const end = @min(offset + @as(u64, count), file_size);
    const clipped = policy.validate(offset, end - offset) catch return -22;
    if (clipped.page_count != 0) {
        switch (desc.fd_type) {
            .ext2_file => ext2_mod.prefetchFilePages(desc.ext2_file_idx, clipped.first_page, clipped.page_count),
            .fat32_file => fat32_mod.prefetchFilePages(desc.fat32_file_idx, clipped.first_page, clipped.page_count, &desc.readahead_state),
            else => unreachable,
        }
    }
    return 0;
}

/// ioprio_set(which, who, ioprio) — set per-task I/O priority.
fn syscallIoprioSet(which: u32, who: u32, ioprio: u32) i64 {
    const tm = @import("../../proc/task.zig");
    const sched_mod = @import("../../proc/sched.zig");
    const policy = @import("../../proc/ioprio_policy.zig");
    if (policy.unsupportedWhich(which)) return -38;
    if (!policy.validWhich(which)) return -22;
    if (!policy.validValue(ioprio)) return -22;
    const lock_flags = tm.lockTask();
    defer tm.unlockTask(lock_flags);
    const current_idx = sched_mod.currentTaskIndex() orelse return -3;
    const current = tm.getTask(current_idx) orelse return -3;
    const target_tid: u32 = if (who == 0) blk: {
        break :blk current.tid;
    } else who;
    const target_idx = tm.findTaskByTidLocked(target_tid) orelse return -3;
    const target = tm.getTask(target_idx) orelse return -3;
    if (target.state == .zombie) return -3;
    if (target.tid != current.tid and target.uid != current.uid) return -1;
    target.ioprio = ioprio;
    return 0;
}

/// ioprio_get(which, who) — get a task's stored I/O priority.
fn syscallIoprioGet(which: u32, who: u32) i64 {
    const tm = @import("../../proc/task.zig");
    const sched_mod = @import("../../proc/sched.zig");
    const policy = @import("../../proc/ioprio_policy.zig");
    if (policy.unsupportedWhich(which)) return -38;
    if (!policy.validWhich(which)) return -22;
    const lock_flags = tm.lockTask();
    defer tm.unlockTask(lock_flags);
    const current_idx = sched_mod.currentTaskIndex() orelse return -3;
    const current = tm.getTask(current_idx) orelse return -3;
    const target_tid: u32 = if (who == 0) blk: {
        break :blk current.tid;
    } else who;
    const target_idx = tm.findTaskByTidLocked(target_tid) orelse return -3;
    const target = tm.getTask(target_idx) orelse return -3;
    if (target.state == .zombie) return -3;
    return target.ioprio;
}

// ── v36.0: vmsplice / name_to_handle_at / open_by_handle_at ──────────────────

/// vmsplice(fd, iov, nr_segs, flags) — splice user-space pages into a pipe.
fn syscallVmsplice(fd: u32, iov_ptr: u64, nr_segs: u32, flags: u32) i64 {
    _ = flags;
    if (iov_ptr == 0 or iov_ptr >= 0x0000_8000_0000_0000) return -14;
    if (nr_segs == 0 or nr_segs > 1024) return -22;

    const sched_mod = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const t = tm.getTask(cur_idx) orelse return -1;
    if (fd >= vfs_mod.MAX_FDS or t.fd_table.fds[fd].fd_type == .none) return -9;

    const copy = @import("../../mm/copy_from_user.zig");
    const bo = @import("../../lib/byte_order.zig");

    // Read each iovec and write to pipe via fd_table
    var total: i64 = 0;
    var idx: u32 = 0;
    while (idx < nr_segs) : (idx += 1) {
        var iov_buf: [16]u8 = undefined;
        const off = @as(u64, idx) * 16;
        _ = copy.copyFromUser(iov_buf[0..], @ptrFromInt(iov_ptr + off), 16);
        const base: u64 = bo.readU64At(&iov_buf, 0);
        const len: u64 = bo.readU64At(&iov_buf, 8);

        if (base > 0 and base < 0x0000_8000_0000_0000 and len > 0) {
            // Copy user data to kernel buffer, then write to fd
            var src_buf: [4096]u8 = undefined;
            const chunk: usize = @intCast(@min(len, 4096));
            const copied = copy.copyFromUser(src_buf[0..chunk], @ptrFromInt(base), chunk);
            if (copied > 0) {
                const written = t.fd_table.write(fd, &src_buf, copied);
                if (written > 0) total += written;
            }
        }
    }
    return total;
}

/// name_to_handle_at(dirfd, pathname, handle_ptr, mount_id_ptr, flags)
/// Simplified: fill handle with inode number and return mount_id=0.
fn syscallNameToHandleAt(dirfd: u32, path_ptr: u64, handle_ptr: u64, mount_id_ptr: u64) i64 {
    _ = dirfd;
    if (path_ptr == 0 or path_ptr >= 0x0000_8000_0000_0000) return -14;
    if (handle_ptr == 0 or handle_ptr >= 0x0000_8000_0000_0000) return -14;

    const copy = @import("../../mm/copy_from_user.zig");
    const bo = @import("../../lib/byte_order.zig");

    // Read pathname
    var path_buf: [256]u8 = .{0} ** 256;
    const copied = copy.copyFromUser(path_buf[0..], @ptrFromInt(path_ptr), 255);
    if (copied == 0) return -14;

    // Resolve to inode (simplified: just use path hash as handle)
    var hash: u64 = 0;
    for (path_buf[0..copied]) |c| {
        hash = hash *% 31 +% @as(u64, c);
    }

    // Write struct file_handle: { u32 handle_bytes; u32 handle_type; u8 f_handle[] }
    // Minimal: handle_bytes=8, handle_type=1, f_handle=hash
    var hbuf: [16]u8 = undefined;
    bo.writeU32Le(hbuf[0..4], 8); // handle_bytes
    bo.writeU32Le(hbuf[4..8], 1); // handle_type (EXT4=1)
    bo.writeU64Le(hbuf[8..16], hash);
    if (copy.copyToUser(@ptrFromInt(handle_ptr), hbuf[0..], 16) != 16) return -14;

    // Write mount_id = 0
    if (mount_id_ptr != 0 and mount_id_ptr < 0x0000_8000_0000_0000) {
        var mid: [4]u8 = .{ 0, 0, 0, 0 };
        if (copy.copyToUser(@ptrFromInt(mount_id_ptr), mid[0..], 4) != 4) return -14;
    }
    return 0;
}

/// open_by_handle_at(mount_fd, handle_ptr, flags) — open file by handle.
/// Simplified: not supported, returns EOPNOTSUPP.
fn syscallOpenByHandleAt(mount_fd: u32, handle_ptr: u64, flags: u32) i64 {
    _ = mount_fd;
    _ = handle_ptr;
    _ = flags;
    return -95; // EOPNOTSUPP
}

// ── v36.0: helpers ───────────────────────────────────────────────────────────

/// Null-terminated string length.
fn strLen(buf: []const u8) usize {
    var i: usize = 0;
    while (i < buf.len and buf[i] != 0) : (i += 1) {}
    return i;
}

// ── v37.0: msync / unsupported mlock / posix_fadvise ─────────────────────

/// msync(addr, length, flags) — flush dirty pages to backing store.
/// MS_ASYNC=1: schedule flush, return immediately.
/// MS_SYNC=4: flush synchronously before returning.
/// MS_INVALIDATE=2: invalidate cached data.
/// Uses page_cache.flushAll for file-backed pages via global writeback.
fn syscallMsync(addr: u64, length: u64, flags: u32) i64 {
    _ = flags;
    if (addr & 0xFFF != 0) return -22; // EINVAL: addr not page-aligned
    if (length == 0) return 0;

    // Flush all dirty buffers to disk (writeback + page_cache).
    // This is the simplest correct implementation: a full sync.
    const vfs = @import("../../fs/vfs.zig");
    if (!vfs.syncAll()) return -5; // EIO
    return 0;
}

/// mlock(addr, len) — user page pinning is not implemented.
fn syscallMlock(addr: u64, len: u64) i64 {
    _ = addr;
    _ = len;
    return if (@import("../../mm/mlock_policy.zig").userMlockUnsupported()) -38 else unreachable;
}

/// munlock(addr, len) — user page pinning is not implemented.
fn syscallMunlock(addr: u64, len: u64) i64 {
    _ = addr;
    _ = len;
    return if (@import("../../mm/mlock_policy.zig").userMlockUnsupported()) -38 else unreachable;
}

/// posix_fadvise(fd, offset, len, advice) — provide readahead hints.
/// POSIX_FADV_SEQUENTIAL=2: sequential access → increase readahead window.
/// POSIX_FADV_WILLNEED=3: pages will be needed soon → prefetch.
/// POSIX_FADV_DONTNEED=4: pages no longer needed → evict from cache.
/// POSIX_FADV_RANDOM=1: random access → disable readahead.
fn syscallPosixFadvise(fd: u32, offset: u64, len: u64, advice: u32) i64 {
    _ = len;
    const sched = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = tm.getTask(cur_idx) orelse return -1;
    if (fd >= cur.fd_table.fds.len) return -9; // EBADF
    if (cur.fd_table.fds[fd].fd_type == .none) return -9;

    const page_cache = @import("../../fs/page_cache.zig");
    const inode_id = cur.fd_table.fds[fd].inode_id;

    switch (advice) {
        2 => { // POSIX_FADV_SEQUENTIAL — boost readahead
            // Record access to trigger sequential detection in page cache
            const cur_page = offset / 4096;
            _ = page_cache.recordAccess(inode_id, cur_page);
            _ = page_cache.recordAccess(inode_id, cur_page + 1);
        },
        3 => { // POSIX_FADV_WILLNEED — prefetch hint (accept, readahead handles it)
            _ = page_cache.recordAccess(inode_id, offset / 4096);
        },
        4 => { // POSIX_FADV_DONTNEED — evict inode pages from page cache
            page_cache.invalidateInode(inode_id);
        },
        1 => { // POSIX_FADV_RANDOM — disable readahead hint
            // Mark inode as non-sequential so readahead won't prefetch
            // (already handled by default — accept hint)
        },
        else => return -22, // EINVAL
    }
    return 0;
}

// ── v37.0: MoQiOS native IPC syscalls ─────────────────────────────────────

/// moqipc_create_ep() — create an IPC endpoint for the current task.
/// Returns endpoint ID (>0) or negative errno.
fn syscallMoqipcCreateEp() i64 {
    const ipc = @import("../../ipc/ipc.zig");
    const sched = @import("../../proc/sched.zig");
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    if (ipc.createEndpoint(cur_idx)) |ep| {
        return @intCast(ep);
    }
    return -12; // ENOMEM
}

/// moqipc_destroy_ep(ep) — destroy an endpoint, unblock waiters.
fn syscallMoqipcDestroyEp(ep: u32) i64 {
    const ipc = @import("../../ipc/ipc.zig");
    if (ep == 0 or ep >= ipc.MAX_ENDPOINTS) return -22;
    ipc.destroyEndpoint(ep);
    return 0;
}

/// moqipc_send(target_ep, msg_ptr) — send a 256-byte Message to target endpoint.
/// Copies 256 bytes from user space, calls ipc.send.
fn syscallMoqipcSend(target_ep: u32, msg_ptr: u64) i64 {
    const ipc = @import("../../ipc/ipc.zig");
    const copy = @import("../../mm/copy_from_user.zig");

    if (msg_ptr == 0 or msg_ptr >= 0x0000_8000_0000_0000) return -14; // EFAULT

    var msg: ipc.Message = undefined;
    const copied = copy.copyFromUser(@as([*]u8, @ptrCast(&msg))[0..256], @ptrFromInt(msg_ptr), 256);
    if (copied != 256) return -14;

    const result = ipc.send(target_ep, &msg);
    return @intCast(@intFromEnum(result));
}

/// moqipc_recv(ep, msg_ptr) — receive a 256-byte Message from endpoint.
/// Blocks until a message arrives. Copies result to user space.
fn syscallMoqipcRecv(ep: u32, msg_ptr: u64) i64 {
    const ipc = @import("../../ipc/ipc.zig");
    const copy = @import("../../mm/copy_from_user.zig");

    if (msg_ptr == 0 or msg_ptr >= 0x0000_8000_0000_0000) return -14;

    var msg: ipc.Message = undefined;
    const result = ipc.receive(ep, &msg);
    if (result != .success) return @intCast(@intFromEnum(result));

    const written = copy.copyToUser(@ptrFromInt(msg_ptr), @as([*]const u8, @ptrCast(&msg))[0..256], 256);
    if (written != 256) return -14;
    return 0;
}

/// moqipc_call(target_ep, msg_ptr) — transactional IPC: send + wait for reply.
/// msg_ptr is both input (request) and output (reply).
fn syscallMoqipcCall(target_ep: u32, msg_ptr: u64) i64 {
    const ipc = @import("../../ipc/ipc.zig");
    const copy = @import("../../mm/copy_from_user.zig");

    if (msg_ptr == 0 or msg_ptr >= 0x0000_8000_0000_0000) return -14;

    var msg: ipc.Message = undefined;
    const copied = copy.copyFromUser(@as([*]u8, @ptrCast(&msg))[0..256], @ptrFromInt(msg_ptr), 256);
    if (copied != 256) return -14;

    const result = ipc.call(target_ep, &msg);
    if (result != .success) return @intCast(@intFromEnum(result));

    // Write reply back to user space
    const written = copy.copyToUser(@ptrFromInt(msg_ptr), @as([*]const u8, @ptrCast(&msg))[0..256], 256);
    if (written != 256) return -14;
    return 0;
}

/// moqipc_reply(caller_ep, msg_ptr) — reply to an IPC caller.
fn syscallMoqipcReply(caller_ep: u32, msg_ptr: u64) i64 {
    const ipc = @import("../../ipc/ipc.zig");
    const copy = @import("../../mm/copy_from_user.zig");

    if (msg_ptr == 0 or msg_ptr >= 0x0000_8000_0000_0000) return -14;

    var msg: ipc.Message = undefined;
    const copied = copy.copyFromUser(@as([*]u8, @ptrCast(&msg))[0..256], @ptrFromInt(msg_ptr), 256);
    if (copied != 256) return -14;

    const result = ipc.reply(caller_ep, &msg);
    return @intCast(@intFromEnum(result));
}

/// moqipc_notify(target_ep, bits) — async, non-blocking notification.
fn syscallMoqipcNotify(target_ep: u32, bits: u64) i64 {
    const ipc = @import("../../ipc/ipc.zig");
    const result = ipc.notify(target_ep, bits);
    return @intCast(@intFromEnum(result));
}

/// moqipc_get_notify(ep) — get and clear pending notification bitmap.
fn syscallMoqipcGetNotify(ep: u32) i64 {
    const ipc = @import("../../ipc/ipc.zig");
    const bits = ipc.getNotify(ep);
    return @bitCast(@as(u64, bits));
}

// ── v37.0: kcmp / capget / capset / sched_setattr / sched_getattr / membarrier ──

/// kcmp(pid1, pid2, type, idx1, idx2) — compare kernel resources of two processes.
/// type: 0=KCMP_FILE, 1=KCMP_VM, 2=KCMP_FILES, 3=KCMP_FS, 4=KCMP_SIGHAND, 5=KCMP_IO, 6=KCMP_SYSVSEM, 7=KCMP_EPOLL.
/// Returns 0 if equal, 1 if less, 2 if greater, 3 if not equal (unordered).
fn syscallKcmp(pid1: u32, pid2: u32, kcmp_type: u32, idx1: u64, idx2: u64) i64 {
    const t1 = findTaskByPid(pid1) orelse return -3; // ESRCH
    const t2 = findTaskByPid(pid2) orelse return -3;

    switch (kcmp_type) {
        0 => { // KCMP_FILE — compare fd tables
            _ = idx1;
            _ = idx2;
            // With CLONE_FILES, two tasks can share one pooled FdTable —
            // identical pointers mean equal (and a shared KCMP_FILE table
            // never aliases a different one).
            if (t1.fd_table == t2.fd_table) return 0;
            if (@intFromPtr(t1.fd_table) < @intFromPtr(t2.fd_table)) return 1;
            return 2;
        },
        1 => { // KCMP_VM — compare page tables
            if (t1.page_table_phys == t2.page_table_phys) return 0;
            if (t1.page_table_phys < t2.page_table_phys) return 1;
            return 2;
        },
        2 => { // KCMP_FILES — compare file descriptor tables
            if (t1.fd_table == t2.fd_table) return 0;
            if (@intFromPtr(t1.fd_table) < @intFromPtr(t2.fd_table)) return 1;
            return 2;
        },
        3 => { // KCMP_FS — compare filesystem info (cwd)
            if (&t1.cwd == &t2.cwd) return 0;
            if (@intFromPtr(&t1.cwd) < @intFromPtr(&t2.cwd)) return 1;
            return 2;
        },
        else => return -22, // EINVAL: unsupported type
    }
}

/// capget(hdr_ptr, data_ptr) — get process capabilities.
/// struct __user_cap_header_struct { u32 version; u32 pid; }
/// struct __user_cap_data_struct[2] { u32 effective; u32 permitted; u32 inheritable; } × 2
fn syscallCapget(hdr_ptr: u64, data_ptr: u64) i64 {
    const copy = @import("../../mm/copy_from_user.zig");
    const bo = @import("../../lib/byte_order.zig");
    const sched_local = @import("../../proc/sched.zig");

    // Read header (version + pid)
    var hdr: [8]u8 = undefined;
    if (hdr_ptr != 0) {
        const copied = copy.copyFromUser(&hdr, @ptrFromInt(hdr_ptr), 8);
        if (copied != 8) return -14;
    }
    const target_pid: u32 = if (hdr_ptr != 0)
        (@as(u32, hdr[4]) | (@as(u32, hdr[5]) << 8) | (@as(u32, hdr[6]) << 16) | (@as(u32, hdr[7]) << 24))
    else
        0;

    // Resolve target task: pid==0 means "current".
    var target_idx: u32 = 0;
    if (target_pid == 0) {
        target_idx = sched_local.currentTaskIndex() orelse return -3; // ESRCH
    } else {
        target_idx = task_mod_caps.findTaskByTid(target_pid) orelse return -3; // ESRCH
    }
    const t = task_mod_caps.getTask(target_idx) orelse return -3;

    if (data_ptr != 0) {
        var cap_data: [24]u8 = undefined;
        const eff: u32 = @bitCast(t.effective_caps);
        const per: u32 = @bitCast(t.permitted_caps);
        const inh: u32 = @bitCast(t.inheritable_caps);
        bo.writeU32Le(cap_data[0..4], eff);
        bo.writeU32Le(cap_data[4..8], per);
        bo.writeU32Le(cap_data[8..12], inh);
        // Second 32-bit set (caps 32-63): unused.
        @memset(cap_data[12..24], 0);
        const written = copy.copyToUser(@ptrFromInt(data_ptr), &cap_data, 24);
        if (written != 24) return -14;
    }
    return 0;
}

/// capset(hdr_ptr, data_ptr) — set process capabilities.
/// Enforces the POSIX rule: new effective \subseteq new permitted \subseteq old permitted.
/// Only the calling process (pid==0 or pid==self) may have its caps modified.
fn syscallCapset(hdr_ptr: u64, data_ptr: u64) i64 {
    const copy = @import("../../mm/copy_from_user.zig");
    const bo = @import("../../lib/byte_order.zig");
    const sched_local = @import("../../proc/sched.zig");

    var hdr: [8]u8 = undefined;
    if (hdr_ptr == 0) return -14;
    const hcopied = copy.copyFromUser(&hdr, @ptrFromInt(hdr_ptr), 8);
    if (hcopied != 8) return -14;
    const target_pid: u32 = (@as(u32, hdr[4]) | (@as(u32, hdr[5]) << 8) | (@as(u32, hdr[6]) << 16) | (@as(u32, hdr[7]) << 24));

    const cur_idx = sched_local.currentTaskIndex() orelse return -1;
    const cur = task_mod_caps.getTask(cur_idx) orelse return -1;
    if (target_pid != 0 and target_pid != cur.tid) return -1; // EPERM — cannot set other tasks

    if (data_ptr == 0) return -14;
    var cap_data: [24]u8 = undefined;
    const dcopied = copy.copyFromUser(&cap_data, @ptrFromInt(data_ptr), 24);
    if (dcopied != 24) return -14;
    const new_eff: u32 = bo.readU32Le(cap_data[0..4]);
    const new_per: u32 = bo.readU32Le(cap_data[4..8]);
    const new_inh: u32 = bo.readU32Le(cap_data[8..12]);

    const old_per: u32 = @bitCast(cur.permitted_caps);
    const old_inh: u32 = @bitCast(cur.inheritable_caps);

    // Cannot grant what we don't already have in permitted.
    if ((new_per & ~old_per) != 0) return -1; // EPERM
    // Effective must be a subset of new permitted.
    if ((new_eff & ~new_per) != 0) return -1; // EPERM
    // Inheritable must be a subset of (old_per | old_inh).
    if ((new_inh & ~(old_per | old_inh)) != 0) return -1; // EPERM

    cur.permitted_caps = @bitCast(new_per);
    cur.effective_caps = @bitCast(new_eff);
    cur.inheritable_caps = @bitCast(new_inh);
    return 0;
}

/// Look up the current task and return both the task pointer and its TID.
/// Returns null when there is no current task (early boot / kernel-only path).
fn currentTaskCaps() ?struct { t: *task_mod_caps.Task, tid: u32 } {
    const sched_local = @import("../../proc/sched.zig");
    const idx = sched_local.currentTaskIndex() orelse return null;
    const t = task_mod_caps.getTask(idx) orelse return null;
    return .{ .t = t, .tid = t.tid };
}

/// Capability gate for the current task. Returns true when the current task
/// has the named capability in its effective set, OR when there is no current
/// task (kernel-internal callers — should never reach a syscall path anyway).
fn checkCapForCurrent(comptime cap_field: []const u8) bool {
    const sched_local = @import("../../proc/sched.zig");
    const idx = sched_local.currentTaskIndex() orelse return true;
    const t = task_mod_caps.getTask(idx) orelse return true;
    return cap_check.capable(t, cap_field);
}

/// sched_attr structure for sched_setattr/sched_getattr:
///   u32 size; u32 sched_policy; u64 sched_flags;
///   i32 sched_nice; u32 sched_priority;
///   u64 sched_runtime; u64 sched_deadline; u64 sched_period;
const SchedAttr = extern struct {
    size: u32,
    sched_policy: u32,
    sched_flags: u64,
    sched_nice: i32,
    sched_priority: u32,
    sched_runtime: u64,
    sched_deadline: u64,
    sched_period: u64,
};

/// sched_setattr(pid, attr_ptr, flags) — set scheduling attributes.
/// pid=0 means current process.
fn syscallSchedSetattr(pid: u32, attr_ptr: u64, flags: u32) i64 {
    _ = flags;
    const copy = @import("../../mm/copy_from_user.zig");

    if (attr_ptr == 0) return -14;

    var attr: SchedAttr = undefined;
    const copied = copy.copyFromUser(@as([*]u8, @ptrCast(&attr))[0..@sizeOf(SchedAttr)], @ptrFromInt(attr_ptr), @sizeOf(SchedAttr));
    if (copied != @sizeOf(SchedAttr)) return -14;

    // Validate policy
    const policy: u8 = @truncate(attr.sched_policy);
    if (policy > 6) return -22; // EINVAL

    const target = findTaskByPid(pid) orelse return -3;
    target.sched_policy = policy;

    // Map sched_priority to kernel priority (0=highest, 255=lowest)
    // For SCHED_FIFO/RR (1,2): priority 1-99 → kernel priority 0-98
    // For SCHED_OTHER (0): nice value → kernel priority 100-139
    if (policy == 1 or policy == 2) { // FIFO or RR
        if (attr.sched_priority == 0 or attr.sched_priority > 99) return -22;
        target.priority = @truncate(99 - attr.sched_priority);
    } else {
        // SCHED_OTHER: nice -20..19 → priority 100..139
        const nice = attr.sched_nice;
        if (nice < -20 or nice > 19) return -22;
        target.priority = @intCast(@as(i32, 120) + nice);
    }
    return 0;
}

/// sched_getattr(pid, attr_ptr, size, flags) — get scheduling attributes.
fn syscallSchedGetattr(pid: u32, attr_ptr: u64, size: u32, flags: u32) i64 {
    _ = flags;
    const copy = @import("../../mm/copy_from_user.zig");
    const bo = @import("../../lib/byte_order.zig");

    if (attr_ptr == 0 or size == 0) return -22;

    const target = findTaskByPid(pid) orelse return -3;

    // Build sched_attr
    var attr: SchedAttr = .{
        .size = @sizeOf(SchedAttr),
        .sched_policy = target.sched_policy,
        .sched_flags = 0,
        .sched_nice = 0,
        .sched_priority = 0,
        .sched_runtime = 0,
        .sched_deadline = 0,
        .sched_period = 0,
    };

    // Reverse-map kernel priority to sched_priority/nice
    if (target.sched_policy == 1 or target.sched_policy == 2) {
        attr.sched_priority = @as(u32, 99) - target.priority;
    } else {
        attr.sched_nice = @as(i32, @intCast(target.priority)) - 120;
    }

    const write_size = @min(@as(u32, @sizeOf(SchedAttr)), size);
    const written = copy.copyToUser(@ptrFromInt(attr_ptr), @as([*]const u8, @ptrCast(&attr))[0..write_size], write_size);
    if (written == 0) return -14;
    _ = bo;
    return 0;
}

// ── F3: sched_setscheduler / sched_getscheduler / sched_get_priority_max/min ──
//
// Linux ABI numbering conflict: the MoQiOS dispatch table does not follow
// Linux syscall numbers — Linux #156/#157 (sched_setscheduler/getscheduler)
// are taken by msgget/msgsnd and #146/#147 (sched_get_priority_max/min) by
// epoll_create1/epoll_ctl. These four are therefore dispatched as MoQiOS
// #473-#476 (next free after arch_prctl #472).
//
// Permission model: MoQiOS has no uid-based privilege split (every task runs
// as uid 0 / root with full capabilities), so any task may set any policy on
// any pid — same model as the existing sched_setattr. If a uid system lands,
// gate FIFO/RR behind CAP_SYS_NICE here.

/// sched_setscheduler(pid, policy, param_ptr) — param = struct { i32 sched_priority }.
/// pid=0 means current task. OTHER requires priority 0; FIFO/RR require 1..99.
fn syscallSchedSetscheduler(pid: u32, policy: u32, param_ptr: u64) i64 {
    const copy = @import("../../mm/copy_from_user.zig");
    const sp = @import("../../proc/sched_policy.zig");

    if (param_ptr == 0) return -14; // EFAULT
    const pol: u8 = @truncate(policy);
    if (policy != pol or !sp.isValidClass(pol)) return -22; // EINVAL

    var param: i32 = 0;
    if (copy.copyFromUser(@as([*]u8, @ptrCast(&param))[0..4], @ptrFromInt(param_ptr), 4) != 4) return -14;

    if (!sp.validatePriority(pol, param)) return -22; // EINVAL

    const target = findTaskByPid(pid) orelse return -3; // ESRCH
    target.sched_policy = pol;
    if (sp.isRtClass(pol)) {
        target.priority = sp.rtToKernelPriority(@intCast(param));
    } else {
        // RT→OTHER (or OTHER→OTHER): reset to the default nice-0 kernel
        // priority used at task creation (setNice band, not the sched_setattr
        // 100..139 band — see docs/kernel-subsystems.md).
        target.priority = 20;
    }
    return 0;
}

/// sched_getscheduler(pid) — return the task's policy (0/1/2), -ESRCH if none.
fn syscallSchedGetscheduler(pid: u32) i64 {
    const target = findTaskByPid(pid) orelse return -3; // ESRCH
    return target.sched_policy;
}

/// sched_get_priority_max(policy) — FIFO/RR: 99, OTHER-like: 0.
fn syscallSchedGetPriorityMax(policy: u32) i64 {
    const sp = @import("../../proc/sched_policy.zig");
    const pol: u8 = @truncate(policy);
    if (policy != pol) return -22;
    if (sp.isRtClass(pol)) return sp.RT_PRIO_MAX;
    // OTHER plus the not-implemented fair/idle classes report 0 (Linux ABI).
    if (pol == sp.SCHED_OTHER or pol == 3 or pol == 5 or pol == 6) return 0;
    return -22; // EINVAL
}

/// sched_get_priority_min(policy) — FIFO/RR: 1, OTHER-like: 0.
fn syscallSchedGetPriorityMin(policy: u32) i64 {
    const sp = @import("../../proc/sched_policy.zig");
    const pol: u8 = @truncate(policy);
    if (policy != pol) return -22;
    if (sp.isRtClass(pol)) return sp.RT_PRIO_MIN;
    if (pol == sp.SCHED_OTHER or pol == 3 or pol == 5 or pol == 6) return 0;
    return -22; // EINVAL
}

/// membarrier(cmd, flags) — issue memory barriers across CPUs.
/// MEMBARRIER_CMD_QUERY=0: return supported commands bitmask.
/// MEMBARRIER_CMD_GLOBAL=1: full memory barrier on all CPUs.
/// MEMBARRIER_CMD_GLOBAL_EXPEDITED=2: expedited global barrier.
/// MEMBARRIER_CMD_REGISTER_GLOBAL_EXPEDITED=3: register for expedited.
/// MEMBARRIER_CMD_REGISTER_PRIVATE_EXPEDITED=4: register private expedited.
/// MEMBARRIER_CMD_PRIVATE_EXPEDITED=5: private expedited barrier.
fn syscallMembarrier(cmd: u32, flags: u32) i64 {
    _ = flags;
    switch (cmd) {
        0 => return 0x3F, // QUERY: report supported commands bitmask
        1, 2, 3, 4, 5 => {
            // Issue a full memory fence (MFENCE on x86_64)
            asm volatile ("mfence" ::: .{ .memory = true });
            return 0;
        },
        else => return -22, // EINVAL
    }
}

/// Find task by TID (linear scan). pid=0 → current task.
fn findTaskByPid(pid: u32) ?*@import("../../proc/task.zig").Task {
    const sched = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");
    if (pid == 0) {
        const cur_idx = sched.currentTaskIndex() orelse return null;
        return tm.getTask(cur_idx);
    }
    for (0..tm.MAX_TASKS) |idx| {
        const t = tm.getTask(@intCast(idx)) orelse continue;
        if (t.state == .zombie) continue;
        if (t.tid == pid) return t;
    }
    return null;
}

// ── v38.0: clock_settime / mlockall / munlockall ─────────────────────────

/// clock_settime(clockid, tp_ptr) — set wall-clock time.
/// Computes offset between requested time and TSC boot time, stores it.
fn syscallClockSettime(clockid: u32, tp_ptr: u64) i64 {
    _ = clockid; // Accept all clock IDs (CLOCK_REALTIME etc.)
    const copy = @import("../../mm/copy_from_user.zig");
    const bo = @import("../../lib/byte_order.zig");
    const tsc = @import("tsc.zig");

    if (tp_ptr == 0 or tp_ptr >= 0x0000_8000_0000_0000) return -14;

    var ts_buf: [16]u8 = undefined;
    const copied = copy.copyFromUser(&ts_buf, @ptrFromInt(tp_ptr), 16);
    if (copied != 16) return -14;

    const req_sec = bo.readU64Le(ts_buf[0..8]);
    const req_nsec = bo.readU64Le(ts_buf[8..16]);
    const req_ns: i64 = @intCast(req_sec * 1_000_000_000 + req_nsec);

    // offset = requested_ns - boot_ns
    const boot_ns: i64 = @intCast(tsc.nanos());
    const offset = req_ns - boot_ns;
    time_mod.setWallClockOffset(offset);
    return 0;
}

/// mlockall(flags) — user page pinning is not implemented.
fn syscallMlockall(flags: u32) i64 {
    _ = flags;
    return if (@import("../../mm/mlock_policy.zig").userMlockUnsupported()) -38 else unreachable;
}

/// munlockall() — user page pinning is not implemented.
fn syscallMunlockall() i64 {
    return if (@import("../../mm/mlock_policy.zig").userMlockUnsupported()) -38 else unreachable;
}

// ── v38.0: MoQiOS capability syscalls ────────────────────────────────────

/// moqipc_grant_cap(endpoint, rights) — grant a capability to current task.
/// rights: bitmask { send=1, receive=2, notify=4, manage=8 }
/// Returns cap slot (>=0) or negative errno.
fn syscallGrantCap(endpoint: u32, rights: u32) i64 {
    const cap = @import("../../ipc/capability.zig");
    const sched = @import("../../proc/sched.zig");
    const cur_idx = sched.currentTaskIndex() orelse return -1;

    const cap_rights: cap.CapRights = .{
        .send = (rights & 1) != 0,
        .receive = (rights & 2) != 0,
        .notify = (rights & 4) != 0,
        .manage = (rights & 8) != 0,
    };
    if (cap.grantCapability(cur_idx, endpoint, cap_rights)) |slot| {
        return @intCast(slot);
    }
    return -12; // ENOMEM: capability table full
}

/// moqipc_revoke_cap(cap_slot) — revoke a capability.
fn syscallRevokeCap(cap_slot: u32) i64 {
    const cap = @import("../../ipc/capability.zig");
    const sched = @import("../../proc/sched.zig");
    const cur_idx = sched.currentTaskIndex() orelse return -1;

    if (cap_slot >= cap.MAX_CAPS_PER_TASK) return -22; // EINVAL
    cap.revokeCapability(cur_idx, cap_slot);
    return 0;
}

/// moqipc_check_cap(endpoint, rights) — check if capability exists.
/// Returns 0 if capability grants the required rights, -EPERM otherwise.
fn syscallCheckCap(endpoint: u32, rights: u32) i64 {
    const cap = @import("../../ipc/capability.zig");
    const sched = @import("../../proc/sched.zig");
    const cur_idx = sched.currentTaskIndex() orelse return -1;

    const required: cap.CapRights = .{
        .send = (rights & 1) != 0,
        .receive = (rights & 2) != 0,
        .notify = (rights & 4) != 0,
        .manage = (rights & 8) != 0,
    };
    if (cap.checkCapability(cur_idx, endpoint, required)) return 0;
    return -1; // EPERM
}

// ── v38.0: close_range / pidfd / swap ────────────────────────────────────

/// close_range(first, last, flags) — close a range of file descriptors.
/// CLOSE_RANGE_CLOEXEC=4: set FD_CLOEXEC instead of closing.
fn syscallCloseRange(first: u32, last: u32, flags: u32) i64 {
    const sched = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = tm.getTask(cur_idx) orelse return -1;

    const max_fd = cur.fd_table.fds.len;
    const lo = @min(first, max_fd);
    const hi = @min(last + 1, max_fd);
    _ = flags; // CLOSE_RANGE_CLOEXEC not yet enforced

    var closed: u32 = 0;
    for (lo..hi) |fd| {
        if (cur.fd_table.fds[fd].fd_type != .none) {
            _ = cur.fd_table.close(@intCast(fd));
            closed += 1;
        }
    }
    return 0;
}

/// pidfd_open(pid, flags) — open a pid file descriptor.
/// Simplified: allocates a proc_file fd that references the target task's tid.
fn syscallPidfdOpen(pid: u32, flags: u32) i64 {
    _ = flags;
    const sched = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");

    // Verify target exists
    const target = findTaskByPid(pid) orelse return -3; // ESRCH

    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = tm.getTask(cur_idx) orelse return -1;

    // Allocate a fd slot
    const fd_slot = cur.fd_table.allocFd() orelse return -24; // EMFILE
    cur.fd_table.fds[fd_slot] = .{
        .fd_type = .proc_file,
        .inode_id = 0x4000_0000_0000_0000 + (@as(u64, target.tid) << 8),
    };
    return @intCast(fd_slot);
}

/// pidfd_send_signal(pidfd, sig, info_ptr, flags) — send signal via pidfd.
/// Simplified: extracts tid from fd inode_id and calls signal.sendSignal.
fn syscallPidfdSendSignal(pidfd: u32, sig: u32, info_ptr: u64, flags: u32) i64 {
    _ = info_ptr;
    _ = flags;
    const sched = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");
    const signal = @import("../../proc/signal.zig");

    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = tm.getTask(cur_idx) orelse return -1;

    if (pidfd >= cur.fd_table.fds.len) return -9; // EBADF
    const fd = &cur.fd_table.fds[pidfd];
    if (fd.fd_type != .proc_file) return -9;

    // Extract tid from inode_id
    const target_tid: u32 = @truncate(fd.inode_id >> 8);
    // Verify target exists
    _ = findTaskByPid(target_tid) orelse return -3;

    _ = signal.sendSignal(target_tid, sig);
    return 0;
}

/// pidfd_getfd(pidfd, targetfd, flags) — get fd from another process.
/// Simplified: not supported (requires fd table sharing).
fn syscallPidfdGetfd(pidfd: u32, targetfd: u32, flags: u32) i64 {
    _ = pidfd;
    _ = targetfd;
    _ = flags;
    return -95; // EOPNOTSUPP
}

/// swapon(path_ptr, flags) — enable swap on a block device.
/// Simplified: ignores path, enables swap on device 0 at LBA 0.
fn syscallSwapon(path_ptr: u64, flags: u32) i64 {
    _ = path_ptr;
    _ = flags;
    const swap = @import("../../mm/swap.zig");
    if (swap.isEnabled()) return -16; // EBUSY
    swap.init(0, 0);
    return 0;
}

/// swapoff(path_ptr) — disable swap.
fn syscallSwapoff(path_ptr: u64) i64 {
    _ = path_ptr;
    const swap = @import("../../mm/swap.zig");
    if (!swap.isEnabled()) return -22; // EINVAL: not enabled
    // Cannot truly disable swap without draining all swapped pages.
    // Accept the call (swap remains enabled).
    return 0;
}

// ── v39.0: New syscall implementations ─────────────────────────────────────

/// mremap(old_addr, old_size, new_size, flags, new_addr) — resize a memory mapping.
/// MREMAP_MAYMOVE (1): allow moving the mapping to a new address.
/// MREMAP_FIXED (2): use new_addr as the target (requires MAYMOVE).
/// Fast path grows/shrinks in place. With MREMAP_MAYMOVE, falls back to
/// allocating a new user range, copying mapped pages, and releasing the old
/// range when the adjacent virtual range is unavailable.
fn syscallMremap(old_addr: u64, old_size: u64, new_size: u64, flags: u32, new_addr: u64) i64 {
    return mmap_mod.mremap(old_addr, old_size, new_size, flags, new_addr);
}

/// getrusage(who, usage_ptr) — get resource usage.
/// who: 0 = RUSAGE_SELF, -1 = RUSAGE_CHILDREN.
/// Fills struct rusage (144 bytes on x86_64) with timing data.
fn syscallGetrusage(who: u32, usage_ptr: u64) i64 {
    _ = who;
    if (usage_ptr == 0 or usage_ptr >= 0x0000_8000_0000_0000) return -22; // EINVAL

    const copy = @import("../../mm/copy_from_user.zig");
    const tsc = @import("tsc.zig");
    const sched = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");

    // struct rusage: ru_utime(16) + ru_stime(16) + rest zeroed
    var buf: [144]u8 = @splat(0);

    const cur_idx = sched.currentTaskIndex() orelse {
        return if (copy.copyToUser(@ptrFromInt(usage_ptr), &buf, 144) == 144) 0 else -14;
    };
    const cur = tm.getTask(cur_idx) orelse {
        return if (copy.copyToUser(@ptrFromInt(usage_ptr), &buf, 144) == 144) 0 else -14;
    };

    // Use TSC nanos for total uptime as user+sys time split
    const total_ns: u64 = tsc.nanos();
    const total_us = total_ns / 1000;
    const user_us = total_us * 7 / 10;
    const sys_us = total_us - user_us;

    // ru_utime: timeval at offset 0 (tv_sec: i64, tv_usec: i64)
    const user_sec: u64 = user_us / 1_000_000;
    const user_usec: u64 = user_us % 1_000_000;
    @memcpy(buf[0..8], &@as([8]u8, @bitCast(user_sec)));
    @memcpy(buf[8..16], &@as([8]u8, @bitCast(user_usec)));

    // ru_stime: timeval at offset 16
    const sys_sec: u64 = sys_us / 1_000_000;
    const sys_usec: u64 = sys_us % 1_000_000;
    @memcpy(buf[16..24], &@as([8]u8, @bitCast(sys_sec)));
    @memcpy(buf[24..32], &@as([8]u8, @bitCast(sys_usec)));

    // ru_maxrss at offset 32 (long): estimate from mmap regions
    var total_pages: u64 = 0;
    var bits = cur.mmap_active_bm;
    while (bits != 0) {
        const i: usize = @intCast(@ctz(bits));
        bits &= bits - 1;
        total_pages += cur.mmap_regions[i].num_pages;
    }
    const maxrss_kb: u64 = total_pages * 4; // 4KB pages to KB
    @memcpy(buf[32..40], &@as([8]u8, @bitCast(maxrss_kb)));

    return if (copy.copyToUser(@ptrFromInt(usage_ptr), &buf, 144) == 144) 0 else -14;
}

/// dup(oldfd) — duplicate file descriptor, returns lowest available fd.
fn syscallDup(oldfd: u32) i64 {
    const sched = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = tm.getTask(cur_idx) orelse return -1;

    if (oldfd >= vfs_mod.MAX_FDS) return -9; // EBADF
    if (cur.fd_table.fds[oldfd].fd_type == .none) return -9; // EBADF

    const newfd = cur.fd_table.allocFdAtLeast(0) orelse return -24; // EMFILE
    return cur.fd_table.dup2(oldfd, newfd);
}

/// alarm(seconds) — schedule SIGALRM after `seconds` seconds.
/// Returns previous alarm remaining (0 if none).
fn syscallAlarm(seconds: u32) i64 {
    const sched = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");
    const tsc = @import("tsc.zig");

    const cur_idx = sched.currentTaskIndex() orelse return 0;
    const cur = tm.getTask(cur_idx) orelse return 0;

    const prev_deadline: u64 = cur.alarm_deadline;
    const now_ns: u64 = tsc.nanos();
    var prev_remaining: u64 = 0;
    if (prev_deadline > now_ns) {
        prev_remaining = (prev_deadline - now_ns) / 1_000_000_000;
    }

    if (seconds == 0) {
        cur.alarm_deadline = 0; // Cancel alarm
        // v53.47: Atomic RMW — alarm_bm is read by BSP timerTick on another CPU
        _ = @atomicRmw(u64, &sched.alarm_bm, .And, ~(@as(u64, 1) << @intCast(cur_idx)), .seq_cst);
    } else {
        cur.alarm_deadline = now_ns + @as(u64, seconds) * 1_000_000_000;
        _ = @atomicRmw(u64, &sched.alarm_bm, .Or, @as(u64, 1) << @intCast(cur_idx), .seq_cst);
        // SIGALRM will be delivered by BSP timer tick when deadline expires
    }

    return @intCast(prev_remaining);
}

/// getitimer(which, curr_value) — get interval timer values.
/// which: 0=ITIMER_REAL, 1=ITIMER_VIRTUAL, 2=ITIMER_PROF.
/// Fills struct itimerval (32 bytes): it_interval(tv_sec,tv_usec) + it_value(tv_sec,tv_usec).
fn syscallGetitimer(which: u32, curr_value_ptr: u64) i64 {
    if (curr_value_ptr == 0 or curr_value_ptr >= 0x0000_8000_0000_0000) return -22;
    const copy = @import("../../mm/copy_from_user.zig");
    const tsc = @import("tsc.zig");
    const sched = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");

    var buf: [32]u8 = @splat(0);
    const cur_idx = sched.currentTaskIndex() orelse {
        return if (copy.copyToUser(@ptrFromInt(curr_value_ptr), &buf, 32) == 32) 0 else -14;
    };
    const cur = tm.getTask(cur_idx) orelse {
        return if (copy.copyToUser(@ptrFromInt(curr_value_ptr), &buf, 32) == 32) 0 else -14;
    };

    if (which == 0) {
        // ITIMER_REAL
        const now_ns: u64 = tsc.nanos();
        var remaining_ns: u64 = 0;
        if (cur.itimer_real_value > now_ns) {
            remaining_ns = cur.itimer_real_value - now_ns;
        }
        const val_sec: u64 = remaining_ns / 1_000_000_000;
        const val_usec: u64 = (remaining_ns % 1_000_000_000) / 1000;
        const int_sec: u64 = cur.itimer_real_interval / 1_000_000_000;
        const int_usec: u64 = (cur.itimer_real_interval % 1_000_000_000) / 1000;
        // it_interval at offset 0
        @memcpy(buf[0..8], &@as([8]u8, @bitCast(int_sec)));
        @memcpy(buf[8..16], &@as([8]u8, @bitCast(int_usec)));
        // it_value at offset 16
        @memcpy(buf[16..24], &@as([8]u8, @bitCast(val_sec)));
        @memcpy(buf[24..32], &@as([8]u8, @bitCast(val_usec)));
    }
    // ITIMER_VIRTUAL/PROF: return zeros (not tracked per-task)

    return if (copy.copyToUser(@ptrFromInt(curr_value_ptr), &buf, 32) == 32) 0 else -14;
}

/// setitimer(which, new_value, old_value) — set interval timer.
/// which: 0=ITIMER_REAL, 1=ITIMER_VIRTUAL, 2=ITIMER_PROF.
fn syscallSetitimer(which: u32, new_value_ptr: u64, old_value_ptr: u64) i64 {
    if (new_value_ptr == 0 or new_value_ptr >= 0x0000_8000_0000_0000) return -22;
    const copy = @import("../../mm/copy_from_user.zig");
    const tsc = @import("tsc.zig");
    const sched = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");

    // Read old value first if requested
    if (old_value_ptr != 0 and old_value_ptr < 0x0000_8000_0000_0000) {
        _ = syscallGetitimer(which, old_value_ptr);
    }

    // Read new value
    var buf: [32]u8 = undefined;
    _ = copy.copyFromUser(&buf, @ptrFromInt(new_value_ptr), 32);

    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = tm.getTask(cur_idx) orelse return -1;

    if (which == 0) {
        // ITIMER_REAL
        const int_sec: u64 = @bitCast(buf[0..8].*);
        const int_usec: u64 = @bitCast(buf[8..16].*);
        const val_sec: u64 = @bitCast(buf[16..24].*);
        const val_usec: u64 = @bitCast(buf[24..32].*);

        cur.itimer_real_interval = int_sec * 1_000_000_000 + int_usec * 1000;
        const val_ns = val_sec * 1_000_000_000 + val_usec * 1000;

        if (val_ns == 0) {
            cur.itimer_real_value = 0; // Disarm
            // v53.47: Atomic RMW — itimer_bm is read by BSP timerTick on another CPU
            _ = @atomicRmw(u64, &sched.itimer_bm, .And, ~(@as(u64, 1) << @intCast(cur_idx)), .seq_cst);
        } else {
            cur.itimer_real_value = tsc.nanos() + val_ns;
            _ = @atomicRmw(u64, &sched.itimer_bm, .Or, @as(u64, 1) << @intCast(cur_idx), .seq_cst);
        }
    }
    // ITIMER_VIRTUAL/PROF: accept but don't track

    return 0;
}

// ── v42.0: cachestat ──────────────────────────────────────────────────

/// cachestat(fd, cachestat_range, cachestat, flags) — query page cache stats for file range.
/// struct cachestat_range { off: u64, len: u64 }
/// struct cachestat { nr_cache: u64, nr_dirty: u64, nr_writeback: u64, nr_evicted: u64, nr_recently_evicted: u64 }
fn syscallCachestat(fd: u32, range_ptr: u64, stat_ptr: u64, flags: u32) i64 {
    _ = flags;
    if (stat_ptr == 0 or stat_ptr >= 0x0000_8000_0000_0000) return -14; // EFAULT
    const sched = @import("../../proc/sched.zig");
    const tm = @import("../../proc/task.zig");
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = tm.getTask(cur_idx) orelse return -1;
    if (fd >= cur.fd_table.fds.len or cur.fd_table.fds[fd].fd_type == .none) return -9; // EBADF

    const page_cache = @import("../../fs/page_cache.zig");
    const stats = page_cache.getStats();
    const copy = @import("../../mm/copy_from_user.zig");
    const bo = @import("../../lib/byte_order.zig");

    // Fill 40-byte struct cachestat
    var buf: [40]u8 = undefined;
    bo.writeU64Le(buf[0..8], @intCast(stats.total)); // nr_cache
    bo.writeU64Le(buf[8..16], @intCast(stats.dirty)); // nr_dirty
    bo.writeU64Le(buf[16..24], 0); // nr_writeback
    bo.writeU64Le(buf[24..32], stats.misses); // nr_evicted (approximate)
    bo.writeU64Le(buf[32..40], 0); // nr_recently_evicted
    _ = range_ptr; // range ignored — return global stats
    return if (copy.copyToUser(@ptrFromInt(stat_ptr), &buf, 40) == 40) 0 else -14;
}
