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
            syscallWrite(frame, fd, buf, count);
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
        6 => {
            syscallWaitpid(frame);
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
        96 => {
            syscallGettimeofday(frame);
        },
        228 => {
            syscallClock_gettime(frame);
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
/// Routes through VFS: stdout/stderr → serial, other fds → VFS write.
fn syscallWrite(frame: *SyscallFrame, fd: u64, buf: u64, count: u64) void {
    if (buf >= 0x0000_8000_0000_0000 or count > 0x7FFFFFFF) {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    }
    const n: usize = @intCast(count);

    var kbuf: [256]u8 = undefined;
    const copy = @import("../../mm/copy_from_user.zig");
    const copied = copy.copyFromUser(kbuf[0..], @ptrFromInt(buf), if (n > 256) @as(usize, 256) else n);
    if (copied == 0) {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    }

    if (fd == 1 or fd == 2) {
        for (0..copied) |i| {
            serial.writeByte(kbuf[i]);
        }
        frame.rax = @intCast(copied);
        return;
    }

    const sched = @import("../../proc/sched.zig");
    const task_mod = @import("../../proc/task.zig");
    if (sched.currentTaskIndex()) |cur_idx| {
        if (task_mod.getTask(cur_idx)) |cur| {
            const result = cur.fd_table.write(@intCast(fd), &kbuf, copied);
            frame.rax = @bitCast(result);
            return;
        }
    }
    frame.rax = @bitCast(@as(i64, -1));
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
    const sched = @import("../../proc/sched.zig");
    const task_mod = @import("../../proc/task.zig");

    // Get caller's TID for parent_tid
    var caller_tid: u32 = 0;
    if (sched.currentTaskIndex()) |idx| {
        if (task_mod.getTask(idx)) |cur| {
            caller_tid = cur.tid;
        }
    }

    if (loader.loadProgram(name, caller_tid)) |task_idx| {
        const t = @import("../../proc/task.zig");
        if (t.getTask(task_idx)) |new_task| {
            frame.rax = new_task.tid;
            return;
        }
    }

    serial.writeString("[spawn] failed\n");
    frame.rax = @bitCast(@as(i64, -1));
}

/// Syscall #6: waitpid(pid, status_ptr, options)
/// RDI = pid (-1 for any child, >0 for specific child)
/// RSI = pointer to i32 in user space to receive exit code
/// RDX = options (bit 0 = WNOHANG)
/// Returns child TID on success, 0 if WNOHANG and no child exited, -1 on error.
fn syscallWaitpid(frame: *SyscallFrame) void {
    const pid_raw: u64 = frame.rdi;
    const status_ptr: u64 = frame.rsi;
    _ = frame.rdx; // options — currently only supports WNOHANG-like behavior

    // pid: -1 (any child) or >0 (specific child). Treat as signed i64.
    const pid: i32 = if (pid_raw == @as(u64, @bitCast(@as(i64, -1))))
        @as(i32, -1)
    else if (pid_raw > 0x7FFFFFFF)
        @as(i32, -1) // invalid — treat as any child
    else
        @intCast(pid_raw);

    const sched_mod = @import("../../proc/sched.zig");
    const task_mod = @import("../../proc/task.zig");

    const cur_idx = sched_mod.currentTaskIndex() orelse {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    };

    // Check if caller has any children at all
    if (!task_mod.hasChildren(cur_idx)) {
        frame.rax = @bitCast(@as(i64, -10)); // -ECHILD
        return;
    }

    var exit_code: i32 = 0;
    if (task_mod.waitpid(cur_idx, pid, &exit_code)) |child_tid| {
        if (status_ptr != 0 and status_ptr < 0x0000_8000_0000_0000) {
            const copy = @import("../../mm/copy_from_user.zig");
            _ = copy.copyToUser(@ptrFromInt(status_ptr), @as([*]const u8, @ptrCast(&exit_code))[0..4], 4);
        }
        frame.rax = child_tid;
    } else {
        // No zombie child yet — busy-wait with hlt to yield CPU.
        // Timer ticks will context-switch to other tasks.
        asm volatile ("sti");
        while (true) {
            asm volatile ("hlt");
            if (task_mod.waitpid(cur_idx, pid, &exit_code)) |child_tid| {
                if (status_ptr != 0 and status_ptr < 0x0000_8000_0000_0000) {
                    const copy = @import("../../mm/copy_from_user.zig");
                    _ = copy.copyToUser(@ptrFromInt(status_ptr), @as([*]const u8, @ptrCast(&exit_code))[0..4], 4);
                }
                frame.rax = child_tid;
                return;
            }
        }
    }
}

/// Syscall #7: brk(addr)
/// RDI = new program break address (0 = return current break)
/// Returns new break on success, current break on failure.
fn syscallBrk(frame: *SyscallFrame) void {
    const addr: u64 = frame.rdi;
    const sched_mod = @import("../../proc/sched.zig");
    const task_mod = @import("../../proc/task.zig");

    const cur_idx = sched_mod.currentTaskIndex() orelse {
        frame.rax = 0;
        return;
    };
    const cur = task_mod.getTask(cur_idx) orelse {
        frame.rax = 0;
        return;
    };

    // If addr == 0, just return current brk
    if (addr == 0) {
        frame.rax = cur.brk_current;
        return;
    }

    // Validate: addr must be above code region and below user stack
    const user_space = @import("../../mm/user_space.zig");
    const code_end = user_space.USER_CODE_BASE + paging.PAGE_SIZE; // at least 1 page of code
    if (addr < code_end) {
        frame.rax = cur.brk_current;
        return;
    }
    // Don't let brk grow into the stack region
    const stack_base = user_space.USER_STACK_TOP - user_space.PAGE_SIZE;
    if (addr >= stack_base) {
        frame.rax = cur.brk_current;
        return;
    }

    // Allocate pages between current brk and new addr
    const old_page = (cur.brk_current + user_space.PAGE_SIZE - 1) / user_space.PAGE_SIZE;
    const new_page = (addr + user_space.PAGE_SIZE - 1) / user_space.PAGE_SIZE;

    const pmm_mod = @import("../../mm/pmm.zig");
    const paging_mod = @import("../../arch/x86_64/paging.zig");

    for (old_page..new_page) |p| {
        const virt = p * user_space.PAGE_SIZE;
        const phys = pmm_mod.allocPage() orelse {
            // OOM — return current brk (partial allocation)
            frame.rax = cur.brk_current;
            return;
        };
        const flags = paging_mod.MapFlags{
            .writable = true,
            .user = true,
            .no_execute = true,
            .global = false,
        };
        paging_mod.mapPage(cur.page_table_phys, virt, phys, flags) catch {
            pmm_mod.freePage(phys);
            frame.rax = cur.brk_current;
            return;
        };
    }

    cur.brk_current = addr;
    frame.rax = addr;
}

/// Syscall #8: mmap(addr, length, prot, flags, fd, offset)
/// RDI = addr (hint, 0 = kernel chooses), RSI = length, RDX = prot,
/// R10 = flags, R8 = fd (-1 for anonymous), R9 = offset
/// For now: only supports MAP_ANONYMOUS | MAP_PRIVATE with addr=0.
/// Returns mapped address or -1 on failure.
fn syscallMmap(frame: *SyscallFrame) void {
    _ = frame.rdi; // addr hint — not used, kernel chooses placement
    const length: u64 = frame.rsi;
    const prot: u64 = frame.rdx; // PROT_READ=1, PROT_WRITE=2, PROT_EXEC=4
    const flags: u64 = frame.r10;
    const fd: i64 = @bitCast(frame.r8);
    _ = frame.r9; // offset

    // Only support anonymous private mappings for now
    const MAP_ANONYMOUS: u64 = 0x20;
    const MAP_PRIVATE: u64 = 0x2;
    if (flags & MAP_ANONYMOUS == 0 or flags & MAP_PRIVATE == 0 or fd != -1) {
        frame.rax = @bitCast(@as(i64, -38)); // -ENOSYS
        return;
    }
    if (length == 0) {
        frame.rax = @bitCast(@as(i64, -22)); // -EINVAL
        return;
    }

    const sched_mod = @import("../../proc/sched.zig");
    const task_mod = @import("../../proc/task.zig");
    const cur_idx = sched_mod.currentTaskIndex() orelse {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    };
    const cur = task_mod.getTask(cur_idx) orelse {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    };

    const user_space = @import("../../mm/user_space.zig");
    const pmm_mod = @import("../../mm/pmm.zig");
    const paging_mod = @import("../../arch/x86_64/paging.zig");

    // Use brk_current as the allocation hint for where to place the mapping.
    // Align up to page boundary and allocate from there.
    const base = (cur.brk_current + user_space.PAGE_SIZE - 1) / user_space.PAGE_SIZE * user_space.PAGE_SIZE;
    const num_pages = (length + user_space.PAGE_SIZE - 1) / user_space.PAGE_SIZE;

    // Validate: don't overflow into stack
    const stack_base = user_space.USER_STACK_TOP - user_space.PAGE_SIZE;
    if (base + num_pages * user_space.PAGE_SIZE >= stack_base) {
        frame.rax = @bitCast(@as(i64, -12)); // -ENOMEM
        return;
    }

    // Allocate and map pages
    for (0..num_pages) |p| {
        const virt = base + p * user_space.PAGE_SIZE;
        const phys = pmm_mod.allocPage() orelse {
            // OOM — return what we have so far (partial mapping leaked, but OK for now)
            frame.rax = @bitCast(@as(i64, -12));
            return;
        };
        // Zero the page (security: don't leak kernel data)
        const hhdm_mod = @import("../../mm/hhdm.zig");
        const page_ptr: [*]u8 = @ptrFromInt(hhdm_mod.physToVirt(phys));
        @memset(page_ptr[0..user_space.PAGE_SIZE], 0);

        const writable = (prot & 2) != 0;
        const executable = (prot & 4) != 0;
        const map_flags = paging_mod.MapFlags{
            .writable = writable,
            .user = true,
            .no_execute = !executable,
            .global = false,
        };
        paging_mod.mapPage(cur.page_table_phys, virt, phys, map_flags) catch {
            pmm_mod.freePage(phys);
            frame.rax = @bitCast(@as(i64, -12));
            return;
        };
    }

    // Advance brk so subsequent allocations don't overlap
    cur.brk_current = base + num_pages * user_space.PAGE_SIZE;
    frame.rax = base;
}

/// Syscall #9: open(name, flags, mode)
/// RDI = filename pointer in user space, RSI = flags, RDX = mode
/// Returns fd on success, -1 on failure.
fn syscallOpen(frame: *SyscallFrame) void {
    const name_ptr: u64 = frame.rdi;
    _ = frame.rsi; // flags (O_RDONLY etc — ignored, always read-only)
    _ = frame.rdx; // mode

    if (name_ptr >= 0x0000_8000_0000_0000 or name_ptr == 0) {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    }

    // Copy filename from user space
    var name_buf: [256]u8 = undefined;
    const copy = @import("../../mm/copy_from_user.zig");
    const copied = copy.copyFromUser(name_buf[0..], @ptrFromInt(name_ptr), 255);
    if (copied == 0) {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    }
    name_buf[if (copied < 255) copied else 255] = 0;

    // Find null terminator
    var len: usize = 0;
    while (len < copied and name_buf[len] != 0) : (len += 1) {}
    const name = name_buf[0..len];

    const sched_mod = @import("../../proc/sched.zig");
    const task_mod = @import("../../proc/task.zig");
    const cur_idx = sched_mod.currentTaskIndex() orelse {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    };
    const cur = task_mod.getTask(cur_idx) orelse {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    };

    const result = cur.fd_table.open(name);
    frame.rax = @bitCast(result);
}

/// Syscall #10: read(fd, buf, count)
/// RDI = fd, RSI = buffer pointer in user space, RDX = count
/// Returns bytes read on success, 0 on EOF, -1 on error.
fn syscallRead(frame: *SyscallFrame) void {
    const fd: u32 = @intCast(frame.rdi);
    const buf_ptr: u64 = frame.rsi;
    const count: u64 = frame.rdx;

    if (fd < 0 or buf_ptr >= 0x0000_8000_0000_0000) {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    }

    const sched_mod = @import("../../proc/sched.zig");
    const task_mod = @import("../../proc/task.zig");
    const cur_idx = sched_mod.currentTaskIndex() orelse {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    };
    const cur = task_mod.getTask(cur_idx) orelse {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    };

    // Read into a kernel buffer, then copy to user
    var kbuf: [256]u8 = undefined;
    const to_read = if (count > 256) @as(usize, 256) else @as(usize, @intCast(count));

    const result = cur.fd_table.read(fd, &kbuf, to_read);
    if (result > 0) {
        const copy = @import("../../mm/copy_from_user.zig");
        _ = copy.copyToUser(@ptrFromInt(buf_ptr), kbuf[0..@intCast(result)], @intCast(result));
    }
    frame.rax = @bitCast(result);
}

/// Syscall #11: close(fd)
/// RDI = fd
/// Returns 0 on success, -1 on error.
fn syscallClose(frame: *SyscallFrame) void {
    const fd: u32 = @intCast(frame.rdi);

    const sched_mod = @import("../../proc/sched.zig");
    const task_mod = @import("../../proc/task.zig");
    const cur_idx = sched_mod.currentTaskIndex() orelse {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    };
    const cur = task_mod.getTask(cur_idx) orelse {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    };

    const result = cur.fd_table.close(fd);
    frame.rax = @bitCast(result);
}

const paging = @import("../../arch/x86_64/paging.zig");

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

/// Syscall #12: munmap(addr, length)
fn syscallMunmap(frame: *SyscallFrame) void {
    const addr: u64 = frame.rdi;
    const length: u64 = frame.rsi;
    _ = addr;
    _ = length;
    // Stub: always succeed
    frame.rax = 0;
}

/// Syscall #96: gettimeofday(tv, tz)
/// RDI = pointer to struct timeval in user space, RSI = timezone (ignored)
fn syscallGettimeofday(frame: *SyscallFrame) void {
    const tv_ptr: u64 = frame.rdi;
    _ = frame.rsi;

    if (tv_ptr == 0 or tv_ptr >= 0x0000_8000_0000_0000) {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    }

    const tsc = @import("../../arch/x86_64/tsc.zig");
    const ns = tsc.nanos();
    const sec = ns / 1_000_000_000;
    const usec = (ns % 1_000_000_000) / 1000;

    // struct timeval { tv_sec: i64, tv_usec: i64 }
    var tv_bytes: [16]u8 = undefined;
    @memcpy(tv_bytes[0..8], @as([*]const u8, @ptrCast(&sec))[0..8]);
    const usec_i64: i64 = @intCast(usec);
    @memcpy(tv_bytes[8..16], @as([*]const u8, @ptrCast(&usec_i64))[0..8]);

    const copy = @import("../../mm/copy_from_user.zig");
    _ = copy.copyToUser(@ptrFromInt(tv_ptr), tv_bytes[0..16], 16);
    frame.rax = 0;
}

/// Syscall #228: clock_gettime(clockid, tp)
/// RDI = clockid, RSI = pointer to struct timespec in user space
fn syscallClock_gettime(frame: *SyscallFrame) void {
    const clockid: u64 = frame.rdi;
    const tp_ptr: u64 = frame.rsi;
    _ = clockid;

    if (tp_ptr == 0 or tp_ptr >= 0x0000_8000_0000_0000) {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    }

    const tsc = @import("../../arch/x86_64/tsc.zig");
    const ns = tsc.nanos();
    const sec = ns / 1_000_000_000;
    const nsec = ns % 1_000_000_000;

    // struct timespec { tv_sec: i64, tv_nsec: i64 }
    var ts_bytes: [16]u8 = undefined;
    @memcpy(ts_bytes[0..8], @as([*]const u8, @ptrCast(&sec))[0..8]);
    const nsec_i64: i64 = @intCast(nsec);
    @memcpy(ts_bytes[8..16], @as([*]const u8, @ptrCast(&nsec_i64))[0..8]);

    const copy = @import("../../mm/copy_from_user.zig");
    _ = copy.copyToUser(@ptrFromInt(tp_ptr), ts_bytes[0..16], 16);
    frame.rax = 0;
}

/// Syscall #22: pipe(pipefd) — create a pipe
/// RDI = pointer to int[2] in user space: [0]=read_fd, [1]=write_fd
fn syscallPipe(frame: *SyscallFrame) void {
    const pipefd_ptr: u64 = frame.rdi;
    if (pipefd_ptr == 0 or pipefd_ptr >= 0x0000_8000_0000_0000) {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    }

    const sched = @import("../../proc/sched.zig");
    const task_mod = @import("../../proc/task.zig");

    if (sched.currentTaskIndex()) |cur_idx| {
        if (task_mod.getTask(cur_idx)) |cur| {
            const result = cur.fd_table.createPipe();
            if (result < 0) {
                frame.rax = @bitCast(@as(i64, -1));
                return;
            }
            const read_fd: u32 = @intCast(result & 0xFFFF);
            const write_fd: u32 = @intCast(@as(u64, @intCast(result)) >> 16);

            // Write [read_fd, write_fd] to user memory
            var pipefd_bytes: [8]u8 = undefined;
            @memcpy(pipefd_bytes[0..4], @as([*]const u8, @ptrCast(&read_fd))[0..4]);
            @memcpy(pipefd_bytes[4..8], @as([*]const u8, @ptrCast(&write_fd))[0..4]);

            const copy = @import("../../mm/copy_from_user.zig");
            _ = copy.copyToUser(@ptrFromInt(pipefd_ptr), pipefd_bytes[0..8], 8);
            frame.rax = 0;
            return;
        }
    }
    frame.rax = @bitCast(@as(i64, -1));
}

/// Syscall #33: dup2(oldfd, newfd)
/// RDI = oldfd, RSI = newfd
fn syscallDup2(frame: *SyscallFrame) void {
    const oldfd: u32 = @intCast(frame.rdi);
    const newfd: u32 = @intCast(frame.rsi);

    const sched = @import("../../proc/sched.zig");
    const task_mod = @import("../../proc/task.zig");
    if (sched.currentTaskIndex()) |cur_idx| {
        if (task_mod.getTask(cur_idx)) |cur| {
            const result = cur.fd_table.dup2(oldfd, newfd);
            frame.rax = @bitCast(result);
            return;
        }
    }
    frame.rax = @bitCast(@as(i64, -1));
}

/// Syscall #57: fork() — clone the current process
/// Returns child TID to parent, 0 to child
fn syscallFork(frame: *SyscallFrame) void {
    const sched = @import("../../proc/sched.zig");
    const task_mod = @import("../../proc/task.zig");
    const vfs_mod = @import("../../fs/vfs.zig");

    const parent_idx = sched.currentTaskIndex() orelse {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    };
    const parent = task_mod.getTask(parent_idx) orelse {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    };

    const child_pml4 = cloneUserPages(parent.page_table_phys) orelse {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    };

    const child_idx = task_mod.createUserProcess(
        parent.user_entry,
        parent.user_stack_top,
        child_pml4,
        parent.tid,
    ) orelse {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    };
    const child = task_mod.getTask(child_idx).?;

    child.brk_current = parent.brk_current;

    for (0..vfs_mod.MAX_FDS) |i| {
        child.fd_table.fds[i] = parent.fd_table.fds[i];
        if (child.fd_table.fds[i].fd_type == .pipe_read or child.fd_table.fds[i].fd_type == .pipe_write) {
            const pidx = child.fd_table.fds[i].pipe_idx;
            if (pidx < 16) {
                vfs_mod.pipes[pidx].ref_count += 1;
            }
        }
    }

    const child_stack_top = child.kernel_stack_top;
    const child_frame_addr = child_stack_top - @sizeOf(@import("idt.zig").InterruptFrame);
    const child_frame: *@import("idt.zig").InterruptFrame = @ptrFromInt(child_frame_addr);
    const frame_bytes: [*]u8 = @ptrCast(child_frame);
    @memset(frame_bytes[0..@sizeOf(@import("idt.zig").InterruptFrame)], 0);

    child_frame.rax = 0;
    child_frame.rbx = frame.rbx;
    child_frame.rcx = frame.rcx;
    child_frame.rdx = frame.rdx;
    child_frame.rsi = frame.rsi;
    child_frame.rdi = frame.rdi;
    child_frame.rbp = frame.rbp;
    child_frame.r8 = frame.r8;
    child_frame.r9 = frame.r9;
    child_frame.r10 = frame.r10;
    child_frame.r11 = frame.r11;
    child_frame.r12 = frame.r12;
    child_frame.r13 = frame.r13;
    child_frame.r14 = frame.r14;
    child_frame.r15 = frame.r15;

    child_frame.rip = frame.rcx;
    child_frame.cs = 0x1B;
    child_frame.rflags = frame.r11;
    child_frame.rsp = getPerCpu().saved_user_rsp;
    child_frame.ss = 0x23;
    child_frame.vector = 0;
    child_frame.error_code = 0;

    child.saved_rsp = child_frame_addr;
    child.started = true;

    serial.writeString("[fork] parent=");
    var buf: [16]u8 = undefined;
    serial.writeString(formatIntBuf(&buf, parent.tid));
    serial.writeString(" child=");
    serial.writeString(formatIntBuf(&buf, child.tid));
    serial.writeString("\n");

    frame.rax = child.tid;
}

/// Syscall #59: execve(filename) — replace current process with new program
fn syscallExecve(frame: *SyscallFrame) void {
    const name_ptr: u64 = frame.rdi;
    if (name_ptr >= 0x0000_8000_0000_0000) {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    }

    var name_buf: [64]u8 = undefined;
    const copy = @import("../../mm/copy_from_user.zig");
    const copied = copy.copyFromUser(name_buf[0..], @ptrFromInt(name_ptr), 63);
    if (copied == 0) {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    }
    name_buf[if (copied < 63) copied else 63] = 0;
    var len: usize = 0;
    while (len < copied and name_buf[len] != 0) : (len += 1) {}
    const name = name_buf[0..len];

    serial.writeString("[execve] loading '");
    serial.writeString(name);
    serial.writeString("'\n");

    const loader = @import("../../proc/loader.zig");
    const result = loader.loadProgramForExec(name) orelse {
        serial.writeString("[execve] failed\n");
        frame.rax = @bitCast(@as(i64, -1));
        return;
    };

    const sched = @import("../../proc/sched.zig");
    const task_mod = @import("../../proc/task.zig");
    const user_space = @import("../../mm/user_space.zig");
    const cur_idx = sched.currentTaskIndex() orelse {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    };
    const cur = task_mod.getTask(cur_idx) orelse {
        frame.rax = @bitCast(@as(i64, -1));
        return;
    };

    if (cur.page_table_phys != 0) {
        user_space.destroyUserSpace(cur.page_table_phys);
    }

    cur.page_table_phys = result.pml4;
    cur.user_entry = result.entry;
    cur.user_stack_top = result.stack_top;
    cur.brk_current = result.brk;

    asm volatile ("movq %[cr3], %%rax\n\tmovq %%rax, %%cr3"
        :
        : [cr3] "r" (result.pml4),
        : .{ .rax = true, .memory = true });
    @import("../../arch/x86_64/gdt.zig").setRsp0(cur.kernel_stack_top);
    getPerCpu().kernel_rsp = cur.kernel_stack_top;

    const stack_top = cur.kernel_stack_top;
    const frame_addr = stack_top - @sizeOf(@import("idt.zig").InterruptFrame);
    const new_frame: *@import("idt.zig").InterruptFrame = @ptrFromInt(frame_addr);
    const bytes: [*]u8 = @ptrCast(new_frame);
    @memset(bytes[0..@sizeOf(@import("idt.zig").InterruptFrame)], 0);

    new_frame.rip = result.entry;
    new_frame.cs = 0x1B;
    new_frame.rflags = 0x202;
    new_frame.rsp = result.stack_top;
    new_frame.ss = 0x23;
    new_frame.vector = 0;
    new_frame.error_code = 0;

    cur.saved_rsp = frame_addr;
    cur.started = true;

    getPerCpu().saved_user_rsp = result.stack_top;

    @import("../../proc/sched.zig").saved_stack_anchor = frame_addr;

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
        : .{ .memory = true }
    );
    unreachable;
}

fn cloneUserPages(parent_pml4_phys: u64) ?u64 {
    const pmm_mod = @import("../../mm/pmm.zig");
    const hhdm_mod = @import("../../mm/hhdm.zig");
    const paging_mod = @import("../../arch/x86_64/paging.zig");

    const ADDR_MASK: u64 = 0xFFFFFFFFF000;

    const child_pml4_phys = pmm_mod.allocPage() orelse return null;
    const child_pml4: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(child_pml4_phys));
    @memset(child_pml4[0..512], 0);

    const kernel_pml4_phys = paging_mod.getKernelPml4();
    const kernel_pml4: [*]const u64 = @ptrFromInt(hhdm_mod.physToVirt(kernel_pml4_phys));
    for (256..512) |i| {
        child_pml4[i] = kernel_pml4[i];
    }

    const parent_pml4: [*]const u64 = @ptrFromInt(hhdm_mod.physToVirt(parent_pml4_phys));

    for (0..256) |pml4_idx| {
        const pml4e = parent_pml4[pml4_idx];
        if (pml4e == 0) continue;
        if (pml4e & 1 == 0) continue;

        const parent_pdpt_phys = pml4e & ADDR_MASK;
        const child_pdpt_phys = pmm_mod.allocPage() orelse return null;
        const child_pdpt: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(child_pdpt_phys));
        @memset(child_pdpt[0..512], 0);
        child_pml4[pml4_idx] = child_pdpt_phys | 0x07;

        const parent_pdpt: [*]const u64 = @ptrFromInt(hhdm_mod.physToVirt(parent_pdpt_phys));

        for (0..512) |pdpt_idx| {
            const pdpte = parent_pdpt[pdpt_idx];
            if (pdpte == 0) continue;
            if (pdpte & 1 == 0) continue;

            const parent_pd_phys = pdpte & ADDR_MASK;
            const child_pd_phys = pmm_mod.allocPage() orelse return null;
            const child_pd: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(child_pd_phys));
            @memset(child_pd[0..512], 0);
            child_pdpt[pdpt_idx] = child_pd_phys | 0x07;

            const parent_pd: [*]const u64 = @ptrFromInt(hhdm_mod.physToVirt(parent_pd_phys));

            for (0..512) |pd_idx| {
                const pde = parent_pd[pd_idx];
                if (pde == 0) continue;
                if (pde & 1 == 0) continue;

                const parent_pt_phys = pde & ADDR_MASK;
                const child_pt_phys = pmm_mod.allocPage() orelse return null;
                const child_pt: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(child_pt_phys));
                @memset(child_pt[0..512], 0);
                child_pd[pd_idx] = child_pt_phys | 0x07;

                const parent_pt: [*]const u64 = @ptrFromInt(hhdm_mod.physToVirt(parent_pt_phys));

                for (0..512) |pt_idx| {
                    const pte = parent_pt[pt_idx];
                    if (pte == 0) continue;
                    if (pte & 1 == 0) continue;

                    const src_phys = pte & ADDR_MASK;
                    const dst_phys = pmm_mod.allocPage() orelse return null;

                    const src: [*]const u8 = @ptrFromInt(hhdm_mod.physToVirt(src_phys));
                    const dst: [*]u8 = @ptrFromInt(hhdm_mod.physToVirt(dst_phys));
                    @memcpy(dst[0..4096], src[0..4096]);

                    const flags = pte & 0xFFF;
                    child_pt[pt_idx] = dst_phys | flags;
                }
            }
        }
    }

    return child_pml4_phys;
}
