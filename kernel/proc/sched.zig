/// Priority-aware round-robin scheduler.
///
/// Context switching strategy:
/// - On timer tick, commonStub has pushed an InterruptFrame on the current task's stack.
/// - We save the stack pointer (via saved_stack_anchor) in the old task struct.
/// - For a new task, we build a fake InterruptFrame at the top of its kernel stack.
/// - We modify saved_stack_anchor to point to the new task's saved frame.
/// - commonStub restores RSP from the anchor and pops/iretqs to the new task.
///
/// For user tasks (page_table_phys != 0):
/// - CR3 is switched to the user task's PML4
/// - TSS RSP0 is set to the user task's kernel_stack_top
/// - PerCpu.kernel_rsp is updated for SYSCALL stack switching
///
/// Priority: lower number = higher priority (0 = highest).
/// Among tasks of equal priority, round-robin is used.
const task = @import("task.zig");
const idt = @import("../arch/x86_64/idt.zig");
const gdt = @import("../arch/x86_64/gdt.zig");
const paging = @import("../arch/x86_64/paging.zig");
const syscall_entry = @import("../arch/x86_64/syscall_entry.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const fmt = @import("../lib/fmt.zig");

const TIMESLICE_TICKS: u64 = 10;

// M8-3: the context-switch stack anchor is now PER-CPU. `commonStub` reads/writes
// it directly via `%gs:16` (PerCpu.saved_stack_anchor); the scheduler reaches the
// same per-CPU slot through these accessors. GS_BASE always points at this CPU's
// PerCpu (set in init/apEntry, never swapped to a different value), so a single
// CPU's anchor is never touched by another CPU.
comptime {
    if (syscall_entry.PERCPU_ANCHOR_OFFSET != 16) {
        @compileError("commonStub hardcodes %gs:16 for PerCpu.saved_stack_anchor; offset changed — update idt.commonStub");
    }
}

pub fn getAnchor() u64 {
    const pc = thisCpu() orelse return 0;
    return pc.saved_stack_anchor;
}

pub fn setAnchor(v: u64) void {
    const pc = thisCpu() orelse return;
    pc.saved_stack_anchor = v;
}

pub const TIMESLICE_TICKS_PUB: u64 = TIMESLICE_TICKS;

var reap_counter: u64 = 0;
const REAP_INTERVAL: u64 = TIMESLICE_TICKS;
var sched_lock: IrqSpinlock = .{};

// M8-2: the running task index and remaining timeslice are now PER-CPU state,
// stored in syscall_entry.PerCpu (current_task_idx / slice_remaining) and reached
// via GS_BASE. In uniprocessor mode GS_BASE always points at percpu_array[0], so
// these accessors are behaviorally identical to the old module-global variables.
// `0xFFFFFFFF` is the "no current task" sentinel (maps to the old `?u32` null).
const NO_TASK_IDX: u32 = 0xFFFFFFFF;

inline fn thisCpu() ?*syscall_entry.PerCpu {
    return syscall_entry.getPerCpuOrNull();
}

fn getCurrentIdx() ?u32 {
    const pc = thisCpu() orelse return null;
    const v = pc.current_task_idx;
    return if (v == NO_TASK_IDX) null else v;
}

fn setCurrentIdx(v: ?u32) void {
    const pc = thisCpu() orelse return;
    pc.current_task_idx = v orelse NO_TASK_IDX;
}

fn getSlice() u64 {
    const pc = thisCpu() orelse return TIMESLICE_TICKS;
    return pc.slice_remaining;
}

fn setSlice(v: u64) void {
    const pc = thisCpu() orelse return;
    pc.slice_remaining = v;
}

/// Logical id of the CPU currently executing (0 = BSP). Used to target this
/// CPU's own TSS RSP0 on context switch (M8-4) rather than always the BSP's.
fn currentCpuId() u32 {
    const pc = thisCpu() orelse return 0;
    return pc.cpu_id;
}

/// Program per-CPU syscall/interrupt stack targets for a user task.
fn setupUserCpuState(t: *task.Task) void {
    const pc = syscall_entry.getPerCpu();
    gdt.setRsp0(currentCpuId(), t.kernel_stack_top);
    pc.kernel_rsp = t.kernel_stack_top;
    pc.current_tid = t.tid;
    syscall_entry.syncUserRspFromTask(t);
    syscall_entry.setPerCpuGsBase(currentCpuId());
}

pub fn currentTaskIndex() ?u32 {
    return getCurrentIdx();
}

pub fn currentTask() ?*task.Task {
    const idx = getCurrentIdx() orelse return null;
    return task.getTask(idx);
}

/// Count non-zombie/non-blocked tasks pinned to this CPU (for single-task fast-path).
fn countActiveOnThisCpu() u32 {
    return task.countActiveOnCpu(@intCast(currentCpuId()));
}

/// Called from timer IRQ handler on every tick (all online CPUs — M8-5b-2).
pub fn timerTick(frame: *idt.InterruptFrame) void {
    _ = frame;

    const flags = sched_lock.acquire();

    // Global periodic maintenance — BSP only (one tick source for the whole system).
    if (currentCpuId() == 0) {
        reap_counter +|= 1;
    }
    if (currentCpuId() == 0 and reap_counter >= REAP_INTERVAL) {
        reap_counter = 0;
        // reapZombies acquires task_lock internally — different lock, safe.
        // freeKernelStack → pmm.freePage also acquires pmm.lock — also safe.
        // Lock order: sched_lock → task_lock → pmm.lock (always this order).
        sched_lock.release(flags);
        _ = task.reapZombies();
        // Drive writeback timer (flush expired dirty buffers ~every 1 s)
        const vfs = @import("../fs/vfs.zig");
        _ = vfs.writebackTimerTick();
        // Drive timerfd expiration checks
        const timerfd = @import("../ipc/timerfd.zig");
        timerfd.timerTick(idt.getTickCount());
        // Drive POSIX timer expiration checks
        const posix_timer = @import("../ipc/posix_timer.zig");
        posix_timer.timerTick(idt.getTickCount());
        // v53.12: Drive TCP timer (retransmission, TIME_WAIT/FIN_WAIT_2 timeout, delayed ACK)
        // LAPIC fires at ~100Hz (10ms/tick), REAP_INTERVAL=10 ticks → ~100ms per maintenance pass
        const tcp = @import("../net/tcp.zig");
        tcp.timerTick(100);
        // Drive alarm() / setitimer(ITIMER_REAL) expiration checks
        {
            const tsc = @import("../arch/x86_64/tsc.zig");
            const signal = @import("signal.zig");
            const now_ns = tsc.nanos();
            for (0..task.MAX_TASKS) |i| {
                const t = task.getTask(@intCast(i)) orelse continue;
                if (t.state == .zombie) continue;
                // Check alarm() deadline
                if (t.alarm_deadline != 0 and now_ns >= t.alarm_deadline) {
                    t.alarm_deadline = 0; // One-shot: clear after firing
                    _ = signal.sendSignal(t.tid, 14); // SIGALRM
                }
                // Check ITIMER_REAL deadline
                if (t.itimer_real_value != 0 and now_ns >= t.itimer_real_value) {
                    _ = signal.sendSignal(t.tid, 14); // SIGALRM
                    if (t.itimer_real_interval != 0) {
                        // Recurring: reschedule next expiration
                        t.itimer_real_value = now_ns + t.itimer_real_interval;
                    } else {
                        // One-shot: clear after firing
                        t.itimer_real_value = 0;
                    }
                }
            }
        }
        // Force scheduling on the very next tick so the BSP doesn't idle a full
        // timeslice after this maintenance pass (which skipped scheduling).
        setSlice(1);
        return;
    }

    // Check for pending signals on current task
    if (getCurrentIdx()) |ci| {
        if (task.getTask(ci)) |ct| {
            // Exited tasks stay cur_idx until we switch away — don't burn timeslice.
            if (ct.state == .zombie) setSlice(0);
            if (ct.is_user and ct.pending_signals != 0 and ct.pending_signals & ~ct.signal_mask != 0) {
                sched_lock.release(flags);
                deliverSignalToRunningTask(ct);
                return;
            }
        }
    }

    const pc_force = thisCpu();
    const force_pick = pc_force != null and pc_force.?.force_reschedule != 0;

    if (task.getTaskCount() == 0) {
        sched_lock.release(flags);
        return;
    }

    if (getCurrentIdx()) |ci| {
        if (task.getTask(ci)) |ct| {
            const cpu: u8 = @intCast(currentCpuId());
            if (!force_pick and countActiveOnThisCpu() == 1 and ct.state != .zombie and ct.state != .blocked) {
                sched_lock.release(flags);
                return;
            }
            // Blocked parent in waitpid still holds cur_idx — run peers on this CPU.
            if (!force_pick and ct.state == .blocked) {
                if (task.hasReadyOnCpu(cpu)) {
                    setSlice(0);
                } else {
                    sched_lock.release(flags);
                    return;
                }
            }
        } else {
            setCurrentIdx(null);
        }
    }

    const new_slice = getSlice() -| 1;
    setSlice(new_slice);
    if (new_slice > 0) {
        sched_lock.release(flags);
        return;
    }
    setSlice(TIMESLICE_TICKS);

    const next_idx = pickNext() orelse {
        sched_lock.release(flags);
        return;
    };

    // First ever schedule
    if (getCurrentIdx() == null) {
        const t = task.getTask(next_idx) orelse {
            sched_lock.release(flags);
            return;
        };
        if (!t.started) {
            setupInitialFrame(t);
        }
        setAnchor(t.saved_rsp);
        t.state = .running;
        setCurrentIdx(next_idx);

        // Set up CPU state for the first scheduled task (mirror context-switch path).
        if (t.page_table_phys != 0) {
            sched_lock.release(flags);
            asm volatile ("movq %[cr3], %%rax\n\tmovq %%rax, %%cr3"
                :
                : [cr3] "r" (t.page_table_phys),
                : .{ .rax = true, .memory = true });
            setupUserCpuState(t);
            return;
        }
        sched_lock.release(flags);
        return;
    }

    const cur_idx = getCurrentIdx().?;
    if (next_idx == cur_idx) {
        sched_lock.release(flags);
        return;
    }

    const old_task = task.getTask(cur_idx) orelse {
        sched_lock.release(flags);
        return;
    };
    const new_task = task.getTask(next_idx) orelse {
        sched_lock.release(flags);
        return;
    };

    old_task.saved_rsp = getAnchor();
    if (old_task.is_user) syscall_entry.syncUserRspToTask(old_task);

    // CPU time accounting: accumulate time spent in this task
    const tsc_mod = @import("../arch/x86_64/tsc.zig");
    const now_tsc = tsc_mod.read();
    if (old_task.sched_in_tsc != 0 and tsc_mod.tsc_freq_mhz != 0) {
        const elapsed_tsc = now_tsc - old_task.sched_in_tsc;
        const elapsed_us = elapsed_tsc / tsc_mod.tsc_freq_mhz;
        if (old_task.is_user) {
            old_task.utime_us += elapsed_us;
        } else {
            old_task.stime_us += elapsed_us;
        }
        old_task.nivcsw += 1;
    }
    new_task.sched_in_tsc = now_tsc;

    if (old_task.state == .running) {
        old_task.state = .ready;
    }

    if (!new_task.started) {
        setupInitialFrame(new_task);
    }

    setAnchor(new_task.saved_rsp);
    new_task.state = .running;
    setCurrentIdx(next_idx);

    if (new_task.page_table_phys != 0) {
        if (old_task.page_table_phys != new_task.page_table_phys) {
            const pt = new_task.page_table_phys;
            sched_lock.release(flags);
            asm volatile ("movq %[cr3], %%rax\n\tmovq %%rax, %%cr3"
                :
                : [cr3] "r" (pt),
                : .{ .rax = true, .memory = true });
            setupUserCpuState(new_task);
            return;
        }
        sched_lock.release(flags);
        setupUserCpuState(new_task);
    } else {
        if (old_task.page_table_phys != 0) {
            const kernel_pml4 = paging.getKernelPml4();
            sched_lock.release(flags);
            asm volatile ("movq %[cr3], %%rax\n\tmovq %%rax, %%cr3"
                :
                : [cr3] "r" (kernel_pml4),
                : .{ .rax = true, .memory = true });
            return;
        }
        sched_lock.release(flags);
    }
}

/// Build a fake InterruptFrame at the top of a new task's kernel stack.
/// When commonStub restores from this frame and iretqs, it jumps to the task entry.
fn setupInitialFrame(t: *task.Task) void {
    const stack_top = t.kernel_stack_top;
    const frame_addr = stack_top - @sizeOf(idt.InterruptFrame);
    const new_frame: *idt.InterruptFrame = @ptrFromInt(frame_addr);

    const bytes: [*]u8 = @ptrCast(new_frame);
    @memset(bytes[0..@sizeOf(idt.InterruptFrame)], 0);

    if (t.is_user) {
        new_frame.rip = t.user_entry;
        new_frame.cs = 0x1B;
        new_frame.rflags = 0x202;
        new_frame.rsp = t.user_stack_top;
        new_frame.ss = 0x23;
        t.saved_user_rsp = t.user_stack_top;
    } else {
        new_frame.rip = @intFromPtr(t.entry);
        new_frame.cs = 0x08;
        new_frame.rflags = 0x202;
        new_frame.rsp = frame_addr;
        new_frame.ss = 0x10;
    }
    new_frame.vector = 0;
    new_frame.error_code = 0;

    t.saved_rsp = frame_addr;
    t.started = true;
}

/// When this CPU has no running task, prefer a ready kernel thread pinned here.
/// Avoids first-ever scheduling straight into user mode (unstable on AP bring-up).
fn pickBootstrapKernel() ?u32 {
    return task.pickKernelBootstrapForCpu(@intCast(currentCpuId()));
}

/// Pick the next ready task — priority-aware round-robin with bitmap fast-path.
fn pickNext() ?u32 {
    if (getCurrentIdx() == null) {
        if (pickBootstrapKernel()) |k| return k;
    }
    return task.pickReadyForCpu(@intCast(currentCpuId()), getCurrentIdx());
}

/// Called from the reschedule IPI — force an immediate scheduler pass.
pub fn forceRescheduleFromIpi(frame: *idt.InterruptFrame) void {
    const pc = thisCpu();
    if (pc) |p| p.force_reschedule = 1;
    setSlice(0);
    timerTick(frame);
    if (pc) |p| p.force_reschedule = 0;
}

/// Ask another CPU to run its scheduler (after a remote task becomes ready).
pub fn kickCpu(cpu_id: u8) void {
    const lapic_mod = @import("../arch/x86_64/lapic.zig");
    const se = @import("../arch/x86_64/syscall_entry.zig");
    if (cpu_id >= se.MAX_CPUS) return;
    const apic_id: u8 = @truncate(se.percpu_array[cpu_id].apic_id);
    asm volatile ("mfence" ::: .{ .memory = true });
    lapic_mod.sendIpi(apic_id, lapic_mod.RESCHEDULE_VECTOR);
}

/// Deliver a pending signal to the currently running user task.
/// Modifies the InterruptFrame on the kernel stack to redirect execution
/// to the signal handler with a signal frame pushed onto the user stack.
pub fn deliverSignalToRunningTask(t: *task.Task) void {
    // Only deliver to tasks returning to user mode.
    // Check this BEFORE dequeuing the signal to avoid losing it.
    const iframe: *idt.InterruptFrame = @ptrFromInt(getAnchor());
    if (iframe.cs != 0x1B) return;

    const sig_mod = @import("signal.zig");

    const signum = sig_mod.dequeueSignal(t) orelse return;

    const handler_addr = t.signal_handlers[signum - 1];

    if (handler_addr == 0) {
        if (!sig_mod.defaultSignalAction(signum)) {
            t.state = .zombie;
            t.exit_code = 128 + @as(i32, @intCast(signum));
        }
        return;
    }

    if (handler_addr == 1) return;

    const user_rsp = iframe.rsp;
    const user_rip = iframe.rip;
    const user_rflags = iframe.rflags;

    const result = sig_mod.pushSignalFrame(t, signum, user_rsp, user_rip, user_rflags);

    // Modify the InterruptFrame to jump to the signal handler
    iframe.rip = handler_addr;
    iframe.rsp = result.new_rsp;
    iframe.rdi = signum;
}

/// Shared kernel idle body — lowest priority, sti+hlt between timer ticks.
pub fn kernelIdleLoop() callconv(.c) void {
    while (true) {
        asm volatile ("sti");
        asm volatile ("hlt");
    }
}

/// Enter the per-CPU kernel idle task without waiting for a timer tick.
/// Called from apEntry after GS/LAPIC setup so cur_idx is never null when the
/// first user task is scheduled (context-switch path, not first-ever user).
pub fn apBootstrapIdle() noreturn {
    const idx = pickBootstrapKernel() orelse {
        const serial = @import("../arch/x86_64/serial.zig");
        serial.writeString("[sched] AP bootstrap: no kernel idle for this CPU\n");
        apIdleLoop();
    };

    const t = task.getTask(idx) orelse apIdleLoop();
    if (!t.started) setupInitialFrame(t);
    setCurrentIdx(idx);
    setSlice(TIMESLICE_TICKS);
    t.state = .running;
    setAnchor(t.saved_rsp);

    // Transfer into the idle task (same epilogue as commonStub).
    asm volatile (
        \\movq %%gs:16, %%rsp
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
        \\iretq
        ::: .{ .memory = true });
    unreachable;
}

/// AP idle loop — fallback when bootstrap cannot find a per-CPU kernel idle.
pub fn apIdleLoop() noreturn {
    while (true) {
        asm volatile ("sti");
        asm volatile ("hlt");
    }
}

/// Park an AP without participating in scheduling.
///
/// SMP migration status: the running-task index, timeslice (M8-2), the context-
/// switch stack anchor (M8-3) and the TSS RSP0 target (M8-4, per-CPU via
/// gdt.setRsp0(currentCpuId(), ..)) are now all PER-CPU. What remains for AP
/// scheduling participation (M8-5): a per-CPU/stealable run queue path and
/// enabling AP timers + `enable_ap_startup`. Until then, APs come online and halt
/// here — this proves multi-core bring-up works without destabilizing the
/// uniprocessor scheduler. Interrupts stay disabled so no timer IRQ drives the
/// scheduler from an AP.
pub fn apParkLoop() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

/// Try to steal a task from the global run queue.
/// Simple implementation: check for ready tasks and run them on this CPU.
fn tryStealTask() void {
    const count = task.getTaskCount();
    if (count == 0) return;

    const flags = sched_lock.acquire();

    // Find a ready task using bitmap fast-path
    var bits = task.getSlotBitmap();
    while (bits != 0) {
        const i: u32 = @intCast(@ctz(bits));
        bits &= bits - 1;
        const t = task.getTask(i) orelse continue;
        if (t.state == .ready and t.cpu_affinity == @as(u8, @truncate(currentCpuId()))) {
            const next_idx: u32 = i;

            if (!t.started) {
                setupInitialFrame(t);
            }

            setAnchor(t.saved_rsp);
            t.state = .running;
            setCurrentIdx(next_idx);
            setSlice(TIMESLICE_TICKS);

            // Set up CPU state for the task
            if (t.page_table_phys != 0) {
                sched_lock.release(flags);
                asm volatile ("movq %[cr3], %%rax\n\tmovq %%rax, %%cr3"
                    :
                    : [cr3] "r" (t.page_table_phys),
                    : .{ .rax = true, .memory = true });
                gdt.setRsp0(currentCpuId(), t.kernel_stack_top);
                syscall_entry.getPerCpu().kernel_rsp = t.kernel_stack_top;
                return;
            }
            sched_lock.release(flags);
            return;
        }
    }

    sched_lock.release(flags);
}

// ---------------------------------------------------------------------------
// Blocking wait / wake primitives
// ---------------------------------------------------------------------------

/// Sleep the current task on a wait queue.
/// The caller must allocate a WaitNode on its kernel stack.
/// After calling this, the task will not be scheduled until woken.
/// Calls forceReschedule() to ensure the scheduler runs ASAP (matching the
/// pattern used by futex/file_lock — other blocking paths call forceReschedule
/// directly). Returns true if woken normally, false if interrupted by a signal.
pub fn sleepOn(queue: *?*task.WaitNode, node: *task.WaitNode) bool {
    const cur_idx = currentTaskIndex() orelse return false;
    const cur = task.getTask(cur_idx) orelse return false;

    // Initialize wait node
    node.task_idx = cur_idx;
    node.granted = false;
    node.next = queue.*;
    queue.* = node;

    // Mark task as blocked
    cur.state = .blocked;
    cur.wait_queue = queue;

    // Force immediate reschedule: set force_reschedule so the next timerTick
    // bypasses the single-task fast-path and picks a different task.
    forceReschedule();

    // When we are woken, we return here. Check if granted.
    // The waker sets node.granted = true before making the task ready.
    return node.granted;
}

/// Wake one waiter from a wait queue (FIFO — wake the most recent waiter).
/// Returns the task index that was woken, or null if the queue was empty.
pub fn wakeOne(queue: *?*task.WaitNode) ?u32 {
    var prev: ?*task.WaitNode = null;
    var current = queue.*;

    // Walk to the end of the list (oldest waiter)
    while (current) |node| {
        if (node.next == null) {
            // This is the oldest waiter — wake it
            node.granted = true;
            const idx = node.task_idx;
            const t = task.getTask(idx) orelse return null;
            if (t.state == .blocked) {
                t.state = .ready;
                t.wait_queue = null;
            }
            // Remove from list
            if (prev) |p| {
                p.next = null;
            } else {
                queue.* = null;
            }
            return idx;
        }
        prev = node;
        current = node.next;
    }
    return null;
}

/// Wake all waiters from a wait queue.
pub fn wakeAll(queue: *?*task.WaitNode) void {
    var current = queue.*;
    while (current) |node| {
        node.granted = true;
        const idx = node.task_idx;
        const t = task.getTask(idx) orelse {
            current = node.next;
            continue;
        };
        if (t.state == .blocked) {
            t.state = .ready;
            t.wait_queue = null;
        }
        current = node.next;
    }
    queue.* = null;
}

/// Force an immediate reschedule. Used by blocking primitives (futex, etc.)
/// after marking the current task as blocked.
pub fn forceReschedule() void {
    setSlice(0);
    // Trigger a timer tick to force the scheduler to switch away from this task.
    // Since the current task is blocked, pickNext() will choose another.
    const iframe: *idt.InterruptFrame = @ptrFromInt(getAnchor());
    timerTick(iframe);
}

// ---------------------------------------------------------------------------
// Dynamic priority / nice support
// ---------------------------------------------------------------------------

/// nice → priority mapping:
///   nice -20 → priority  0 (highest)
///   nice   0 → priority 20 (default)
///   nice  19 → priority 39 (lowest)
///
/// Lower priority number = higher scheduling priority.
/// Set the nice value of a task, updating its internal priority.
pub fn setNice(t: *task.Task, nice: i32) void {
    const clamped: i32 = @max(-20, @min(19, nice));
    const new_prio: u8 = @intCast(clamped + 20);
    t.priority = new_prio;
}

/// Get the nice value of a task from its internal priority.
pub fn getNice(t: *task.Task) i32 {
    return @as(i32, @intCast(t.priority)) - 20;
}

/// Syscall #140: getpriority(which, who)
/// which: PRIO_PROCESS=0, PRIO_PGRP=1, PRIO_USER=2
/// Simplified: only supports PRIO_PROCESS + who=0 (current process).
/// Returns 20 - nice on success (range 1-40), negative errno on failure.
/// Linux convention: the raw syscall returns (20 - nice).
pub fn sysGetpriority(which: u64, who: u64) i64 {
    const PRIO_PROCESS: u64 = 0;
    if (which != PRIO_PROCESS) return -22; // -EINVAL

    const cur_idx = currentTaskIndex() orelse return -1;
    const cur = task.getTask(cur_idx) orelse return -1;

    // who == 0 means current process
    if (who != 0) {
        // Look up by TID
        const target_idx = task.findTaskByTid(@intCast(who)) orelse return -3; // -ESRCH
        const target = task.getTask(target_idx) orelse return -3;
        const nice_val: i32 = @as(i32, @intCast(target.priority)) - 20;
        return 20 - nice_val;
    }

    const nice_val: i32 = @as(i32, @intCast(cur.priority)) - 20;
    return 20 - nice_val;
}

/// Syscall #141: setpriority(which, who, prio)
/// which: PRIO_PROCESS=0, PRIO_PGRP=1, PRIO_USER=2
/// prio is the nice value (-20..19).
/// Simplified: only supports PRIO_PROCESS + who=0 (current process).
pub fn sysSetpriority(which: u64, who: u64, prio: i64) i64 {
    const PRIO_PROCESS: u64 = 0;
    if (which != PRIO_PROCESS) return -22; // -EINVAL

    const cur_idx = currentTaskIndex() orelse return -1;
    const cur = task.getTask(cur_idx) orelse return -1;

    if (who != 0) {
        const target_idx = task.findTaskByTid(@intCast(who)) orelse return -3; // -ESRCH
        const target = task.getTask(target_idx) orelse return -3;
        setNice(target, @intCast(prio));
        return 0;
    }

    setNice(cur, @intCast(prio));
    return 0;
}
