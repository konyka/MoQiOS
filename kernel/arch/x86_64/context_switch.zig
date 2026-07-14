/// FPU/SSE context-switch support — lazy save/restore via CR0.TS + #NM.
///
/// Strategy (Task #1):
///   - On every context switch, if the outgoing task currently owns the FPU
///     we eagerly fxsave its state into Task.fpu_state. We then arm CR0.TS
///     so the next FPU/SSE instruction issued by the incoming task triggers
///     a Device Not Available (#NM, vector 7) exception.
///   - The #NM handler clears CR0.TS, restores the incoming task's FPU state
///     (or `fninit`s a fresh state on first use), records it as the new
///     per-CPU FPU owner and lets the offending instruction re-execute.
///
/// This makes FPU save/restore pay-for-what-you-use: kernel threads and
/// user tasks that never touch FPU/SSE state pay zero save/restore cost.
///
/// Hardware bits we drive:
///   CR4.OSFXSR   (bit 9)  — enable FXSAVE/FXRSTOR + SSE in OS
///   CR4.OSXMMEXCPT (bit 10) — route SSE FP exceptions to #XF (vector 19)
///   CR0.EM       (bit 2)  — must be 0 (no x87 emulation)
///   CR0.MP       (bit 1)  — set so WAIT/FWAIT honour TS
///   CR0.TS       (bit 3)  — toggled to drive lazy restore
const builtin = @import("builtin");
const task = @import("../../proc/task.zig");
const syscall_entry = @import("syscall_entry.zig");

/// x86 uses hardware iretq frames via commonStub (not software-only).
pub const uses_software_frame: bool = false;

/// Stub — shared-kernel software-frame enter is non-x86 (SK-14).
pub fn enterSoftwareFrame(frame_ptr: u64) void {
    _ = frame_ptr;
}

pub fn resumeAfterSoftwareEnter() noreturn {
    while (true) asm volatile ("hlt");
}

pub fn buildKernelTrapFrame(stack_top: u64, entry: u64) u64 {
    _ = stack_top;
    _ = entry;
    return 0;
}

pub fn armSharedPreemptTimer() void {}

pub fn enterTrapFrame(frame_ptr: u64) void {
    _ = frame_ptr;
}

/// Per-CPU current FPU owner. `null` = no task on this CPU has touched the
/// FPU since the last init. Indexed by logical cpu id (0 = BSP). Updated
/// only by the local CPU's #NM handler / context-switch path, so no lock
/// is required for the slot belonging to the running CPU.
pub var fpu_owners: [syscall_entry.MAX_CPUS]?*task.Task = .{null} ** syscall_entry.MAX_CPUS;

/// Set CR0.TS on the current CPU. After this, the next FPU/SSE instruction
/// will trap into #NM (vector 7).
inline fn setTs() void {
    asm volatile (
        \\movq %%cr0, %%rax
        \\bts $3, %%rax
        \\movq %%rax, %%cr0
        ::: .{ .rax = true, .memory = true });
}

/// Clear CR0.TS on the current CPU (allow FPU/SSE without trapping).
inline fn clearTs() void {
    asm volatile ("clts" ::: .{ .memory = true });
}

/// Per-CPU FPU initialization. Must be called once per CPU during bring-up.
///
/// Sets:
///   CR4.OSFXSR | CR4.OSXMMEXCPT
///   CR0.MP, CR0.TS, clears CR0.EM
///
/// After this, the very first FPU/SSE instruction on this CPU will fault
/// into the #NM handler, which performs the initial fninit + arms tracking.
pub fn initCpu() void {
    if (builtin.cpu.arch != .x86_64) return;
    asm volatile (
        \\movq %%cr4, %%rax
        \\bts $9,  %%rax       // CR4.OSFXSR
        \\bts $10, %%rax       // CR4.OSXMMEXCPT
        \\movq %%rax, %%cr4
        \\movq %%cr0, %%rax
        \\btr $2, %%rax        // clear CR0.EM (no x87 emulation)
        \\bts $1, %%rax        // set CR0.MP   (monitor coprocessor)
        \\bts $3, %%rax        // set CR0.TS   (lazy switch armed)
        \\movq %%rax, %%cr0
        ::: .{ .rax = true, .memory = true });
}

/// Called from the scheduler immediately before it reroutes the per-CPU
/// stack anchor from `old` to a new task. If `old` owns the FPU on this
/// CPU we fxsave its state, then arm CR0.TS so the incoming task takes a
/// lazy #NM the first time it touches FPU/SSE.
pub fn onContextSwitch(old: ?*task.Task) void {
    if (builtin.cpu.arch != .x86_64) return;
    if (old) |o| {
        if (o.fpu_owned) {
            asm volatile ("fxsave (%[buf])"
                :
                : [buf] "r" (@as([*]u8, @ptrCast(&o.fpu_state))),
                : .{ .memory = true });
        }
    }
    // Arm lazy-restore for the incoming task. The old task keeps its
    // fpu_owned flag set — the #NM handler clears it when a different task
    // first touches FPU on this CPU (so a re-scheduled `old` can short-
    // circuit straight back to its saved state without an extra fxsave).
    setTs();
}

/// #NM (vector 7 — Device Not Available) handler. Runs with interrupts
/// disabled on the offending CPU's kernel stack. We must NOT acquire the
/// scheduler/task locks here: this path can be entered while another lock
/// is already held by the same CPU (e.g. a kernel routine that briefly
/// uses SSE inside a critical section).
pub fn handleDeviceNotAvailable() void {
    if (builtin.cpu.arch != .x86_64) return;

    // Allow FPU/SSE to execute on this CPU.
    clearTs();

    const sched = @import("../../proc/sched.zig");
    const cur = sched.currentTask() orelse {
        // No current task on this CPU (very early boot / idle bootstrap).
        // Just initialize the FPU so the offending instruction can retry.
        asm volatile ("fninit" ::: .{ .memory = true });
        return;
    };

    const cpu_id = syscall_entry.getPerCpu().cpu_id;

    // Drop the previous owner's claim on this CPU's FPU. The previous
    // owner's saved state lives in its Task.fpu_state (eagerly written by
    // onContextSwitch), so clearing the flag is sufficient.
    if (fpu_owners[cpu_id]) |prev| {
        if (prev != cur) {
            prev.fpu_owned = false;
        }
    }

    if (cur.fpu_initialized) {
        asm volatile ("fxrstor (%[buf])"
            :
            : [buf] "r" (@as([*]u8, @ptrCast(&cur.fpu_state))),
            : .{ .memory = true });
    } else {
        asm volatile ("fninit" ::: .{ .memory = true });
        cur.fpu_initialized = true;
    }
    cur.fpu_owned = true;
    fpu_owners[cpu_id] = cur;
}
