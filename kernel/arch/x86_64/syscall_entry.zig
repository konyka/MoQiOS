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
pub const MAX_CPUS: u32 = 4;

pub const PerCpu = extern struct {
    kernel_rsp: u64, // Kernel RSP0 to switch to on syscall
    saved_user_rsp: u64, // User RSP saved across syscall
    saved_stack_anchor: u64, // RSP anchor for context switch (commonStub)
    slice_remaining: u64, // Timeslice ticks remaining
    cpu_id: u32, // Logical CPU index (0 = BSP)
    apic_id: u32, // LAPIC APIC ID
    current_tid: u32, // Currently running task TID on this CPU (0 = idle)
    current_task_idx: u32, // Index of currently running task (0xFFFFFFFF = none)
};

/// Per-CPU data array, indexed by CPU logical ID.
/// slice_remaining starts at the scheduler timeslice (sched.TIMESLICE_TICKS = 10)
/// so a freshly-brought-up CPU behaves like the old global default.
pub var percpu_array: [MAX_CPUS]PerCpu = .{
    .{ .kernel_rsp = 0, .saved_user_rsp = 0, .saved_stack_anchor = 0, .slice_remaining = 10, .cpu_id = 0, .apic_id = 0, .current_tid = 0, .current_task_idx = 0xFFFFFFFF },
    .{ .kernel_rsp = 0, .saved_user_rsp = 0, .saved_stack_anchor = 0, .slice_remaining = 10, .cpu_id = 1, .apic_id = 0, .current_tid = 0, .current_task_idx = 0xFFFFFFFF },
    .{ .kernel_rsp = 0, .saved_user_rsp = 0, .saved_stack_anchor = 0, .slice_remaining = 10, .cpu_id = 2, .apic_id = 0, .current_tid = 0, .current_task_idx = 0xFFFFFFFF },
    .{ .kernel_rsp = 0, .saved_user_rsp = 0, .saved_stack_anchor = 0, .slice_remaining = 10, .cpu_id = 3, .apic_id = 0, .current_tid = 0, .current_task_idx = 0xFFFFFFFF },
};

/// Personality type for ABI routing.
pub const Personality = enum(u8) {
    native = 0,
    linux = 1,
    windows = 2,
};

pub const ExecResult = extern struct {
    pending: u64,
    new_entry: u64,
    new_stack: u64,
};

pub export var exec_result: ExecResult = .{ .pending = 0, .new_entry = 0, .new_stack = 0 };

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

/// Compile-time offset of saved_stack_anchor in PerCpu (used by commonStub asm).
pub const PERCPU_ANCHOR_OFFSET = @offsetOf(PerCpu, "saved_stack_anchor");

/// Set GS base for the given CPU (used during CPU init).
pub fn setPerCpuGsBase(cpu_id: u32) void {
    const addr = @intFromPtr(&percpu_array[cpu_id]);
    wrmsr(0xC0000101, addr); // GS_BASE (kernel mode)
    wrmsr(0xC0000102, addr); // KERNEL_GS_BASE (loaded by swapgs)
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
        \\movq exec_result(%%rip), %%rax
        \\testq %%rax, %%rax
        \\jz 2f
        \\addq $8, %%rsp   // discard saved RAX — exec/signal provides new context
        \\movq exec_result+8(%%rip), %%rcx
        \\movq exec_result+16(%%rip), %%rax
        \\movq $0x202, %%r11
        \\movq %%rax, %%rsp
        \\movq $0, exec_result(%%rip)
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

/// Central syscall dispatch — called from the entry stub with the frame.
/// Routes based on the current process's personality field.
pub fn syscallDispatch(frame: *SyscallFrame) callconv(.c) void {
    const syscall_nr = frame.rax;

    switch (syscall_nr) {
        1 => {
            syscallWrite(frame);
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
        else => {
            serial.writeString("[syscall] unknown syscall: 0x");
            fmt.writeHex(syscall_nr);
            serial.writeString("\n");
            frame.rax = @bitCast(errno.ENOSYS);
        },
    }
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
    frame.rax = @bitCast(waitpid_mod.waitpid(frame.rdi, frame.rsi));
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
    frame.rax = @bitCast(file_io_mod.open(frame.rdi, @truncate(frame.rsi)));
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

/// Initialize the syscall entry point.
/// Sets up IA32_STAR and IA32_LSTAR MSRs, enables EFER.SCE,
/// and configures kernel GSBase for per-CPU data.
pub fn init() void {
    // IA32_STAR[32:47] = kernel CS for SYSCALL
    // IA32_STAR[48:63] = user CS base for SYSRET (SYSRET adds 0 for CS, +8 for SS)
    // Standard: STAR = (0x08 << 32) | (0x1B << 48)
    const star: u64 = (@as(u64, 0x08) << 32) | (@as(u64, 0x1B) << 48);
    wrmsr(MSR_STAR, star);

    // LSTAR = address of syscallEntry
    wrmsr(MSR_LSTAR, @intFromPtr(&syscallEntry));

    // SFMASK = flags to clear on SYSCALL (clear IF and TF)
    wrmsr(MSR_SFMASK, 0x300); // TF (0x100) | IF (0x200)

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
    frame.rax = @bitCast(time_mod.clock_gettime(frame.rsi));
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

/// Syscall #59: execve(filename) — replace current process with new program
fn syscallExecve(frame: *SyscallFrame) void {
    const frame_addr = execve_mod.prepareExec(frame.rdi, frame.rsi) orelse {
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

fn syscallSigaction(frame: *SyscallFrame) void {
    frame.rax = @bitCast(signal_syscall_mod.sigaction(@truncate(frame.rdi), frame.rsi, frame.rdx));
}

fn syscallSigprocmask(frame: *SyscallFrame) void {
    frame.rax = @bitCast(signal_syscall_mod.sigprocmask(@truncate(frame.rdi), frame.rsi, frame.rdx));
}

fn syscallSigreturn(frame: *SyscallFrame) void {
    const r = signal_syscall_mod.sigreturn();
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
    frame.rax = @bitCast(lifecycle_mod.kill(@truncate(frame.rdi), @truncate(frame.rsi)));
}

fn syscallNetSend(frame: *SyscallFrame) void {
    frame.rax = @bitCast(raw_net_mod.netSend(frame.rdi, frame.rsi));
}

fn syscallNetRecv(frame: *SyscallFrame) void {
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
    if (current.pending_signals & ~current.signal_mask == 0) return;

    const signum = sig_mod.dequeueSignal(current) orelse return;

    const handler_addr = current.signal_handlers[signum - 1];

    if (handler_addr == 0) {
        if (!sig_mod.defaultSignalAction(signum)) {
            current.state = .zombie;
            current.exit_code = 128 + @as(i32, @intCast(signum));
        }
        return;
    }

    if (handler_addr == 1) return;

    const user_rsp = getPerCpu().saved_user_rsp;
    const user_rip = frame.rcx;
    const user_rflags = frame.r11;

    const result = sig_mod.pushSignalFrame(current, signum, user_rsp, user_rip, user_rflags);

    frame.rdi = signum;
    frame.rcx = handler_addr;
    exec_result.pending = 3;
    exec_result.new_entry = handler_addr;
    exec_result.new_stack = result.new_rsp;
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
    frame.rax = @bitCast(socket_mod.sendto(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx), @truncate(frame.rcx), frame.r8, @truncate(frame.r9)));
}

/// Syscall #122: recvfrom(fd, buf, len, flags, addr_ptr, addr_len_ptr)
/// For TCP sockets, ignores source address.
/// RDI = fd
/// RSI = buffer (user space)
/// RDX = buffer length
/// Returns bytes received (0 = none), -1 on error/closed.
fn syscallRecvfrom(frame: *SyscallFrame) void {
    frame.rax = @bitCast(socket_mod.recvfrom(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx), @truncate(frame.rcx), frame.r8, frame.r9));
}

/// Syscall #123: mkdir(path, mode)
/// RDI = path pointer (user space)
/// RSI = mode (ignored, always 0777 for dirs)
/// Returns 0 on success, -1 on failure.
fn syscallMkdir(frame: *SyscallFrame) void {
    frame.rax = @bitCast(dir_ops_mod.mkdir(frame.rdi));
}

/// Syscall #124: connect(fd, addr_ptr, addr_len)
/// RDI = fd (TCP socket)
/// RSI = pointer to sockaddr_in (user space)
/// RDX = addr_len
/// Returns 0 on success (SYN sent), -1 on failure.
fn syscallConnect(frame: *SyscallFrame) void {
    frame.rax = @bitCast(socket_mod.connect(@truncate(frame.rdi), frame.rsi, @truncate(frame.rdx)));
}
