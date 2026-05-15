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
pub const PerCpu = extern struct {
    kernel_rsp: u64, // Kernel RSP0 to switch to on syscall
    saved_user_rsp: u64, // User RSP saved across syscall
};

/// Personality type for ABI routing.
pub const Personality = enum(u8) {
    native = 0,
    linux = 1,
    windows = 2,
};

/// Single BSP per-cpu data (single-core for now).
var bsp_percpu: PerCpu = .{
    .kernel_rsp = 0,
    .saved_user_rsp = 0,
};

/// Global pointer to syscall dispatch function, used by syscallEntry
/// to call the handler without clobbering any registers via input operands.
/// Exported with C linkage so the asm template can reference it by name.
export var dispatch_handler: *const fn (*SyscallFrame) callconv(.c) void = &syscallDispatch;

/// Get pointer to BSP per-cpu data.
pub fn getPerCpu() *PerCpu {
    return &bsp_percpu;
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
        \\// Restore user RSP from PerCpu.saved_user_rsp (offset 8)
        \\movq %%gs:8, %%rsp
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
            const fd: u64 = frame.rdi;
            const buf: u64 = frame.rsi;
            const count: u64 = frame.rdx;
            _ = fd;
            syscallWrite(buf, count);
            frame.rax = count;
        },
        2 => {
            const status: u64 = frame.rdi;
            syscallExit(status);
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
        else => {
            serial.writeString("[syscall] unknown syscall: 0x");
            writeHex(syscall_nr);
            serial.writeString("\n");
            frame.rax = @bitCast(@as(i64, -38));
        },
    }
}

/// Syscall #1: write(fd, buf, count)
/// For M5, writes directly to serial (fd ignored).
/// Uses copy_from_user for safe user memory access.
fn syscallWrite(buf: u64, count: u64) void {
    if (buf >= 0x0000_8000_0000_0000) return;
    const end = buf + count;
    if (end < buf or end > 0x0000_8000_0000_0000) return;

    const max_write: u64 = 4096;
    const n: usize = @intCast(if (count > max_write) max_write else count);

    // Copy to kernel buffer, then write to serial
    var kbuf: [256]u8 = undefined;
    const copy = @import("../../mm/copy_from_user.zig");
    const copied = copy.copyFromUser(kbuf[0..], @ptrFromInt(buf), n);
    if (copied == 0) return;

    for (0..copied) |i| {
        serial.writeByte(kbuf[i]);
    }
}

fn syscallExit(status: u64) void {
    const t = @import("../../proc/task.zig");
    var buf: [16]u8 = undefined;
    serial.writeString("[exit] task exited with code ");
    serial.writeString(formatIntBuf(&buf, status));
    serial.writeString("\n");
    t.exitTask(@intCast(status));
}

fn syscallGetpid(frame: *SyscallFrame) void {
    const s = @import("../../proc/sched.zig");
    const t = @import("../../proc/task.zig");
    if (s.currentTaskIndex()) |idx| {
        if (t.getTask(idx)) |current| {
            frame.rax = current.tid;
            return;
        }
    }
    frame.rax = 0;
}

/// Syscall #5: spawn(name_ptr) — load and start a program from ramdisk.
/// RDI = pointer to null-terminated program name in user space.
/// Returns new PID on success, or -1 on failure.
fn syscallSpawn(frame: *SyscallFrame) void {
    const name_ptr: u64 = frame.rdi;
    if (name_ptr >= 0x0000_8000_0000_0000) {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    }

    // Copy the name from user space (max 64 bytes)
    var name_buf: [64]u8 = undefined;
    const copy = @import("../../mm/copy_from_user.zig");
    const copied = copy.copyFromUser(name_buf[0..], @ptrFromInt(name_ptr), 63);
    if (copied == 0) {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    }
    // Null-terminate
    name_buf[if (copied < 63) copied else 63] = 0;

    // Find the null terminator to get actual string length
    var len: usize = 0;
    while (len < copied and name_buf[len] != 0) : (len += 1) {}
    const name = name_buf[0..len];

    serial.writeString("[spawn] loading '");
    serial.writeString(name);
    serial.writeString("'\n");

    // Load the program from ramdisk
    const loader = @import("../../proc/loader.zig");
    if (loader.loadProgram(name)) |task_idx| {
        const t = @import("../../proc/task.zig");
        if (t.getTask(task_idx)) |new_task| {
            frame.rax = new_task.tid;
            return;
        }
    }

    serial.writeString("[spawn] failed\n");
    frame.rax = @bitCast(@as(i64, -1));
}

fn writeHex(value: u64) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var v = value;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@as(usize, @intCast(v & 0xf))];
        v >>= 4;
    }
    serial.writeString(&buf);
}

fn formatIntBuf(buf: []u8, value: u64) []const u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var i: usize = 0;
    var v = value;
    while (v > 0) : (v /= 10) {
        buf[i] = @intCast(v % 10 + '0');
        i += 1;
    }
    var j: usize = 0;
    while (j < i / 2) : (j += 1) {
        const tmp = buf[j];
        buf[j] = buf[i - 1 - j];
        buf[i - 1 - j] = tmp;
    }
    return buf[0..i];
}

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

    // Set kernel GSBase to point to PerCpu struct.
    // swapgs swaps GS_BASE and KERNEL_GS_BASE.
    // In user mode: GS_BASE = user TLS (0 for now), KERNEL_GS_BASE = &bsp_percpu
    // In kernel mode (after swapgs): GS_BASE = &bsp_percpu
    // So we set KERNEL_GS_BASE to &bsp_percpu (loaded by swapgs in syscallEntry)
    wrmsr(MSR_KERNEL_GS_BASE, @intFromPtr(&bsp_percpu));

    serial.writeString("[syscall] SYSCALL/SYSRET enabled, GSBase configured\n");
}
