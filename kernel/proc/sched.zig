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
const sched_policy = @import("sched_policy.zig");
const per_cpu = @import("per_cpu.zig");
const idt = @import("../arch/arch.zig").interrupts;
const gdt = @import("../arch/arch.zig").gdt;
const paging = @import("../arch/arch.zig").paging;
const syscall_entry = @import("../arch/arch.zig").syscall;
const pcid = @import("../arch/arch.zig").pcid;
const context_switch = @import("../arch/arch.zig").context_switch;
const arch_cpu = @import("../arch/arch.zig").cpu;
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const fmt = @import("../lib/fmt.zig");
const builtin = @import("builtin");

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

// v53.46: Active timer bitmaps — timerTick only scans tasks with active timers
// instead of all 64 task slots. Set by alarm/setitimer syscalls, cleared on fire/cancel.
pub var alarm_bm: u64 = 0;
pub var itimer_bm: u64 = 0;

// M8-2: the running task index and remaining timeslice are now PER-CPU state,
// stored in syscall_entry.PerCpu (current_task_idx / slice_remaining) and reached
// via GS_BASE. In uniprocessor mode GS_BASE always points at percpu_array[0], so
// these accessors are behaviorally identical to the old module-global variables.
// `0xFFFFFFFF` is the "no current task" sentinel (maps to the old `?u32` null).
const NO_TASK_IDX: u32 = 0xFFFFFFFF;

inline fn thisCpu() ?*syscall_entry.PerCpu {
    return syscall_entry.getPerCpuOrNull();
}

// v53.48: Hot-path per-CPU accessors use %gs:offset inline asm (~5 cycles)
// instead of rdmsr via getPerCpuOrNull (~155 cycles). Safe after GS_BASE
// is set during sched.init() — all these functions are called post-init only.

fn getCurrentIdx() ?u32 {
    const v = syscall_entry.gsReadCurrentTaskIdx();
    return if (v == NO_TASK_IDX) null else v;
}

fn setCurrentIdx(v: ?u32) void {
    syscall_entry.gsWriteCurrentTaskIdx(v orelse NO_TASK_IDX);
}

fn getSlice() u64 {
    return syscall_entry.gsReadSliceRemaining();
}

fn setSlice(v: u64) void {
    syscall_entry.gsWriteSliceRemaining(v);
}

pub fn requestReschedule() void {
    setSlice(0);
}

/// SK-22: refill the current CPU timeslice (same value as x86 timer path).
pub fn resetTimeslice() void {
    setSlice(TIMESLICE_TICKS);
}

/// SK-22: portable timeslice tick without IRQ frames / CR3 / signals.
/// Decrements the slice; when it expires, cooperatively `forceReschedule`s if
/// another ready task exists. Safe on non-x86 software-frame backends.
pub fn timerTickPortable() void {
    if (comptime builtin.cpu.arch == .x86_64) return;
    if (comptime !context_switch.uses_software_frame) return;

    if (!hardwareTimerTick()) return;
    setSlice(TIMESLICE_TICKS);

    const cur = getCurrentIdx() orelse return;
    // Prefer another ready task (round-robin after current).
    const next = task.pickReadyForCpu(@intCast(currentCpuId()), cur) orelse return;
    if (next == cur) return;
    @call(.never_inline, forceReschedule, .{});
}

/// SK-23: account one hardware timer IRQ against the timeslice.
/// Returns true when the slice has expired (caller / task should preempt).
/// Safe to call from arch IRQ handlers — does not switch.
/// F3: a running SCHED_FIFO task never expires — the slice is refilled and
/// false is returned (FIFO yields the CPU only by blocking or exiting).
pub fn hardwareTimerTick() bool {
    const new_slice = getSlice() -| 1;
    setSlice(new_slice);
    if (new_slice != 0) return false;
    if (getCurrentIdx()) |ci| {
        if (task.getTask(ci)) |ct| {
            if (ct.state == .running and !sched_policy.hasQuantumExpiry(ct.sched_policy)) {
                setSlice(TIMESLICE_TICKS);
                return false;
            }
        }
    }
    return true;
}

/// SK-23: true when the current timeslice is exhausted.
pub fn timesliceExpired() bool {
    return getSlice() == 0;
}

/// Logical id of the CPU currently executing (0 = BSP). Used to target this
/// CPU's own TSS RSP0 on context switch (M8-4) rather than always the BSP's.
fn currentCpuId() u32 {
    return syscall_entry.gsReadCpuId();
}

/// Program per-CPU syscall/interrupt stack targets for a user task.
fn setupUserCpuState(t: *task.Task) void {
    const pc = syscall_entry.getPerCpu();
    gdt.setRsp0(currentCpuId(), t.kernel_stack_top);
    pc.kernel_rsp = t.kernel_stack_top;
    pc.current_tid = t.tid;
    syscall_entry.syncUserRspFromTask(t);
    syscall_entry.setPerCpuGsBase(currentCpuId());
    syscall_entry.setUserTlsBase(t.tls_base);
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
    // Cheap pre-check: any task sitting in this CPU's run queue means more than
    // the current task is active here, so the caller's `== 1` test already has
    // its answer — skip the task_lock + full slot-bitmap scan. The returned 2
    // is a lower-bound sentinel, not an exact count (the only caller compares
    // against 1). Stale queue entries can only make this over-report, which
    // costs one harmless extra schedule pass, never a wrong skip.
    if (per_cpu.isAnyReady()) {
        const q = per_cpu.getCurrent();
        if (@atomicLoad(u32, &q.nr_running, .monotonic) != 0) return 2;
    }
    return task.countActiveOnCpu(@intCast(currentCpuId()));
}

/// Called from timer IRQ handler on every tick (all online CPUs — M8-5b-2).
pub fn timerTick(frame: *idt.InterruptFrame) void {
    _ = frame;

    // sched_lock still serialises the whole pick/steal/switch path below.
    // Splitting it (lock-free per-CPU pick, sched_lock only around the anchor
    // switch) is deliberately NOT done: between a lock-free popRunnable /
    // pickReadyForCpu and the locked `state = .running` transition another CPU
    // could claim the same ready task — the isCurrentOnOtherCpu check is only
    // a snapshot — putting one task (and one kernel stack) on two CPUs at
    // once. Closing that TOCTOU needs an atomic claim protocol on Task.state,
    // which is too invasive for the win here. Cheaper subsets live in
    // countActiveOnThisCpu (queue-depth pre-check) and pickNext (steal skip).
    // Lock order unchanged: sched_lock → task_lock → queue lock (no ABBA).
    var flags = sched_lock.acquire();

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
        // Drive writeback expiry check (~every 1 s). Only the cheap scan runs
        // here (IRQ-off); the flush itself is deferred to the writeback kernel
        // thread — see vfs.writebackTimerTick.
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
        // SK-79: NDP incomplete Neighbor Solicitation retransmit (RetransTimer).
        const icmpv6 = @import("../net/icmpv6.zig");
        icmpv6.neighborTimerTick(100);
        // Drive alarm() / setitimer(ITIMER_REAL) expiration checks
        // v53.46: Bitmap scan — only check tasks with active timers (O(active) vs O(64)).
        {
            const tsc = @import("../arch/arch.zig").tsc;
            const now_ns = tsc.nanos();
            // Drive timed futex waits (FUTEX_WAIT/FUTEX_WAIT_BITSET with val2).
            const futex_mod = @import("../sync/futex.zig");
            futex_mod.timerTick(now_ns);
            // Drive timed POSIX mq waits (mq_timedsend/mq_timedreceive with
            // abs_timeout) — same deadline-bitmap pattern as the futex scan.
            const posix_mq_mod = @import("../ipc/posix_mq.zig");
            posix_mq_mod.timerTick(now_ns);
            // v53.47: Atomic load — alarm_bm/itimer_bm are modified from syscall context
            // on other CPUs. Non-atomic read-modify-write could lose newly set bits.
            var bm = @atomicLoad(u64, &alarm_bm, .acquire) |
                @atomicLoad(u64, &itimer_bm, .acquire);
            while (bm != 0) {
                const i: u6 = @truncate(@ctz(bm));
                bm &= bm - 1;
                const t = task.getTask(@intCast(i)) orelse continue;
                if (t.state == .zombie) continue;
                // Check alarm() deadline
                if (t.alarm_deadline != 0 and now_ns >= t.alarm_deadline) {
                    t.alarm_deadline = 0; // One-shot: clear after firing
                    _ = @atomicRmw(u64, &alarm_bm, .And, ~(@as(u64, 1) << i), .seq_cst);
                    _ = @atomicRmw(u32, &t.pending_signals, .Or, @as(u32, 1) << 13, .seq_cst);
                }
                // Check ITIMER_REAL deadline
                if (t.itimer_real_value != 0 and now_ns >= t.itimer_real_value) {
                    _ = @atomicRmw(u32, &t.pending_signals, .Or, @as(u32, 1) << 13, .seq_cst);
                    if (t.itimer_real_interval != 0) {
                        // Recurring: reschedule next expiration
                        t.itimer_real_value = now_ns + t.itimer_real_interval;
                    } else {
                        // One-shot: clear after firing
                        t.itimer_real_value = 0;
                        _ = @atomicRmw(u64, &itimer_bm, .And, ~(@as(u64, 1) << i), .seq_cst);
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
            if (ct.is_user and ct.pending_signals != 0 and ct.pending_signals & ~@as(u32, @truncate(ct.signal_mask)) != 0) {
                sched_lock.release(flags);
                // Resume through the frame when the handler was entered.
                // Otherwise fall through to a normal reschedule: returning here
                // would skip scheduling on every tick for as long as the signal
                // stays undeliverable, which stalls the CPU outright.
                if (deliverSignalToRunningTask(ct)) return;
                flags = sched_lock.acquire();
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

    // F3: SCHED_FIFO has no quantum — a running FIFO task is never preempted
    // by a plain timer tick; it leaves the CPU only by blocking, yielding or
    // exiting. A reschedule IPI (force_pick) still preempts, and a blocked /
    // zombie current task is switched out regardless.
    if (!force_pick) {
        if (getCurrentIdx()) |ci| {
            if (task.getTask(ci)) |ct| {
                if (ct.state == .running and !sched_policy.hasQuantumExpiry(ct.sched_policy)) {
                    setSlice(TIMESLICE_TICKS);
                    sched_lock.release(flags);
                    return;
                }
            }
        }
    }

    // F3: a reschedule IPI (force_pick) must not preempt a running RT task
    // for lower-ranked work — every remote wake would otherwise cut into
    // FIFO/RR execution. Preempt only when a strictly better-ranked runnable
    // exists on this CPU.
    if (force_pick) {
        if (getCurrentIdx()) |ci| {
            if (task.getTask(ci)) |ct| {
                if (ct.state == .running and sched_policy.isRtClass(ct.sched_policy)) {
                    const cur_key = sched_policy.rankKey(ct.sched_policy, ct.priority);
                    const best = peekBestRankKey();
                    if (best == null or best.? >= cur_key) {
                        setSlice(TIMESLICE_TICKS);
                        sched_lock.release(flags);
                        return;
                    }
                }
            }
        }
    }

    setSlice(TIMESLICE_TICKS);

    const next_idx = pickNext() orelse {
        sched_lock.release(flags);
        return;
    };

    // DIAG: pinned task scheduled on a foreign CPU (catches both first
    // schedule and switches).
    if (task.getTask(next_idx)) |nt| {
        if (nt.cpu_affinity >= 0 and nt.cpu_affinity != @as(i16, @intCast(currentCpuId()))) {
            var b1: [24]u8 = undefined;
            var b2: [24]u8 = undefined;
            var b3: [24]u8 = undefined;
            const serial = @import("../arch/arch.zig").serial;
            serial.writeString("[AFFDIAG] tid=");
            serial.writeString(fmt.fmtDec(&b1, nt.tid));
            serial.writeString(" pin=");
            serial.writeString(fmt.fmtDec(&b2, @as(u64, @intCast(nt.cpu_affinity))));
            serial.writeString(" cpu=");
            serial.writeString(fmt.fmtDec(&b3, currentCpuId()));
            serial.writeString("\n");
        }
    }

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
            pcid.switchCr3(t.page_table_phys);
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

    // Task #1: eager fxsave on context switch (only if old_task currently
    // owns the FPU on this CPU) + arm CR0.TS so the new task takes a lazy
    // #NM the first time it touches FPU/SSE state.
    context_switch.onContextSwitch(old_task);

    // CPU time accounting: accumulate time spent in this task
    const tsc_mod = @import("../arch/arch.zig").tsc;
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
        // Task #2: re-publish to its target per-CPU queue so the next
        // pickNext picks it up from the local fast-path. Best-effort —
        // a full queue just falls back to the bitmap scan.
        if (per_cpu.isAnyReady()) _ = per_cpu.enqueueTask(old_task);
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
            pcid.switchCr3(pt);
            setupUserCpuState(new_task);
            return;
        }
        sched_lock.release(flags);
        setupUserCpuState(new_task);
    } else {
        if (old_task.page_table_phys != 0) {
            const kernel_pml4 = paging.getKernelPml4();
            sched_lock.release(flags);
            pcid.switchCr3(kernel_pml4);
            return;
        }
        sched_lock.release(flags);
    }
}

/// Build a fake InterruptFrame at the top of a new task's kernel stack.
/// When the arch restore path loads this frame, it jumps to the task entry.
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

/// SK-13: build the initial InterruptFrame for a created kernel/user task and
/// publish it as this CPU's switch anchor (without entering the task).
pub fn prepareTaskFrame(idx: u32) bool {
    const t = task.getTask(idx) orelse return false;
    if (!t.started) setupInitialFrame(t);
    setAnchor(t.saved_rsp);
    return t.started and t.saved_rsp != 0;
}

/// When this CPU has no running task, prefer a ready kernel thread pinned here.
/// Avoids first-ever scheduling straight into user mode (unstable on AP bring-up).
fn pickBootstrapKernel() ?u32 {
    return task.pickKernelBootstrapForCpu(@intCast(currentCpuId()));
}

/// Pick the next ready task — priority-aware round-robin with bitmap fast-path.
fn pickNext() ?u32 {
    // Task #6: profiling — every scheduler pass on this CPU bumps schedule_calls
    // and contributes a queue-depth sample. Safe without locking: only this CPU
    // writes its own stats fields.
    if (per_cpu.isAnyReady()) {
        const pq = per_cpu.getCurrent();
        pq.stats.schedule_calls += 1;
        pq.stats.queue_depth_sum += @atomicLoad(u32, &pq.nr_running, .monotonic);
        pq.stats.sample_count += 1;
    }
    if (getCurrentIdx() == null) {
        if (pickBootstrapKernel()) |k| return k;
    }
    // Task #2: try the per-CPU run queue first. The queue holds *Task pointers;
    // we translate back to a slot index for the rest of the scheduler. If the
    // local queue is empty, attempt to steal from another CPU's queue. Only
    // when both fail do we fall back to the legacy bitmap scan, which still
    // serves as a safety net for tasks that became ready before per-CPU
    // queues were primed (e.g. early boot, blocked→ready transitions that
    // skip enqueueTask).
    if (per_cpu.isAnyReady()) {
        const q = per_cpu.getCurrent();
        var deferred_local = false;
        if (popRunnable(q, &deferred_local)) |i| return i;
        // Steal skip: when the pop set `deferred_local`, a .ready task pinned
        // here already exists (it is only unpickable until its owner CPU
        // switches away). The bitmap fallback below rediscovers it —
        // pickReadyForCpu re-checks isCurrentOnOtherCpu — so don't take two
        // remote queue locks in tryStealForCurrent for work we don't need.
        if (!deferred_local) {
            const stolen = per_cpu.tryStealForCurrent();
            if (stolen > 0) {
                if (popRunnable(q, &deferred_local)) |i| return i;
            }
        }
    }
    return task.pickReadyForCpu(@intCast(currentCpuId()), getCurrentIdx());
}

/// Best (lowest) rankKey among runnable tasks eligible for this CPU, without
/// dequeuing anything. Used to decide whether a reschedule IPI may preempt a
/// running RT task: the IPI must not cut into FIFO/RR execution for
/// lower-ranked work (observed as hello44 fifo-preemption flakiness on SMP).
fn peekBestRankKey() ?u16 {
    var best: ?u16 = null;
    // Per-CPU run queue (read-only scan).
    const q = per_cpu.getCurrent();
    const qflags = q.lock.acquire();
    var i: u32 = 0;
    while (i < q.nr_running) : (i += 1) {
        const slot = (q.tail + i) % per_cpu.QUEUE_SIZE;
        const t = q.tasks[slot] orelse continue;
        if (t.state != .ready) continue;
        const key = sched_policy.rankKey(t.sched_policy, t.priority);
        if (best == null or key < best.?) best = key;
    }
    q.lock.release(qflags);
    // Bitmap fallback (non-mutating pick).
    if (task.pickReadyForCpu(@intCast(currentCpuId()), null)) |idx| {
        if (task.getTask(idx)) |t| {
            const key = sched_policy.rankKey(t.sched_policy, t.priority);
            if (best == null or key < best.?) best = key;
        }
    }
    return best;
}

/// Pop queue entries until one is actually runnable *here*. Wake paths
/// (`unblockTask`/`wakeOne`/`wakeAll`) enqueue a task the moment it turns
/// `.ready`, but its owner CPU may not have switched away yet — running it
/// now would put one task (and one kernel stack) live on two CPUs at once
/// (P1 SMP=2 stress crash: from-user IRQ frame at kstack top shredded by the
/// second CPU's syscall entry). Skipped entries are NOT requeued: the task is
/// still `.ready`, so the bitmap fallback rediscovers it once its owner CPU
/// has moved on; stale non-ready entries are dropped the same way.
/// `deferred_local` is set when at least one entry was skipped solely because
/// it is still current on another CPU — i.e. real local work exists and the
/// caller should not bother stealing from remote queues.
/// F3: pops go through `popRtAware` so a queued SCHED_FIFO/RR task outranks
/// OTHER entries; with no RT task queued the pop is byte-identical LIFO.
fn popRunnable(q: *per_cpu.PerCpuRunQueue, deferred_local: *bool) ?u32 {
    const my_cpu = currentCpuId();
    while (q.popRtAware()) |t| {
        const i = taskIndexOf(t) orelse continue;
        if (t.state != .ready) continue;
        // J1: never run a task pinned to another CPU. Entries can predate the
        // pin (the task was queued while still unpinned, e.g. right after
        // fork before sched_setaffinity); the bitmap fallback on the pinned
        // CPU rediscovers the task via pickReadyForCpu's matchesCpu check.
        if (t.cpu_affinity >= 0 and t.cpu_affinity != @as(i16, @intCast(my_cpu))) continue;
        if (task.isCurrentOnOtherCpu(i, my_cpu)) {
            deferred_local.* = true;
            continue;
        }
        return i;
    }
    return null;
}

/// v53.45: O(1) reverse lookup via Task.self_idx (set at creation time).
inline fn taskIndexOf(t: *task.Task) ?u32 {
    return t.self_idx;
}

/// Place a ready task on its target CPU's run queue (Task #2). Falls back
/// silently when the queue is full — the legacy bitmap scan inside
/// `task.pickReadyForCpu` will still find the task.
pub fn enqueue(t: *task.Task) void {
    if (!per_cpu.isAnyReady()) return;
    _ = per_cpu.enqueueTask(t);
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
    if (comptime builtin.cpu.arch == .x86_64) {
        kickCpuX86(cpu_id);
    }
}

fn kickCpuX86(cpu_id: u8) void {
    const lapic_mod = @import("../arch/arch.zig").timer;
    const se = @import("../arch/arch.zig").syscall;
    if (cpu_id >= se.MAX_CPUS) return;
    if (!@import("../smp.zig").isCpuOnline(cpu_id)) return;
    const apic_id: u8 = @truncate(se.percpu_array[cpu_id].apic_id);
    asm volatile ("mfence" ::: .{ .memory = true });
    _ = lapic_mod.sendIpi(apic_id, lapic_mod.RESCHEDULE_VECTOR);
}

/// Deliver a pending signal to the currently running user task.
/// Modifies the InterruptFrame on the kernel stack to redirect execution
/// to the signal handler with a signal frame pushed onto the user stack.
///
/// Returns true when the caller should resume through the frame (handler
/// entered, default ignored, or exitTask was invoked for default terminate).
/// Returns false when delivery failed and the caller should fall back.
pub fn deliverSignalToRunningTask(t: *task.Task) bool {
    // Only deliver to tasks returning to user mode.
    // Check this BEFORE dequeuing the signal to avoid losing it.
    // Both user code selectors have to be accepted: a task resumed with iretq
    // runs on USER_CS, but one that last returned through sysret runs on
    // USER_CS_SYSRET, which is most of the time for anything that makes
    // syscalls. Testing only USER_CS made this path silently give up.
    const iframe: *idt.InterruptFrame = @ptrFromInt(getAnchor());
    if (iframe.cs != gdt.USER_CS and iframe.cs != gdt.USER_CS_SYSRET) return false;

    const sig_mod = @import("signal.zig");

    const signum = sig_mod.dequeueSignal(t) orelse return false;

    const handler_addr = t.signal_handlers[signum - 1];

    if (handler_addr == 0) {
        if (!sig_mod.defaultSignalAction(signum)) {
            // v53.49: Route through exitTask for proper fd cleanup and parent
            // wakeup. Previously this directly set zombie state, leaking all
            // open fds and deadlocking any parent blocked in waitpid().
            task.exitTask(128 + @as(i32, @intCast(signum)));
            // exitTask never returns (ends in sti+hlt loop)
        }
        return true;
    }

    if (handler_addr == 1) return true;

    const user_rsp = iframe.rsp;
    const user_rip = iframe.rip;
    const user_rflags = iframe.rflags;

    const result = sig_mod.pushSignalFrame(t, signum, user_rsp, user_rip, user_rflags);

    // v53.45: Drop signal if delivery fails — avoids livelock when user stack
    // is permanently unmapped. Signal was already dequeued by dequeueSignal.
    if (result.new_rsp == 0) return false;

    // Modify the InterruptFrame to jump to the signal handler
    iframe.rip = handler_addr;
    iframe.rsp = result.new_rsp;
    iframe.rdi = signum;
    return true;
}

/// Shared kernel idle body — lowest priority, enable IRQs + wait between ticks.
pub fn kernelIdleLoop() callconv(.c) void {
    while (true) {
        idt.enableIrq();
        arch_cpu.waitForInterrupt();
    }
}

/// Enter the per-CPU kernel idle task without waiting for a timer tick.
/// Called from apEntry after GS/LAPIC setup so cur_idx is never null when the
/// first user task is scheduled (context-switch path, not first-ever user).
pub fn apBootstrapIdle() noreturn {
    const idx = pickBootstrapKernel() orelse {
        const serial = @import("../arch/arch.zig").serial;
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
        idt.enableIrq();
        arch_cpu.waitForInterrupt();
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
        arch_cpu.waitForInterrupt();
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
        const my_cpu: u8 = @truncate(currentCpuId());
        const ok = t.cpu_affinity < 0 or t.cpu_affinity == @as(i16, my_cpu);
        if (t.state == .ready and ok) {
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
                pcid.switchCr3(t.page_table_phys);
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
    if (!blockOn(queue, node)) return false;

    // When we are woken, we return here. Check if granted.
    // The waker sets node.granted = true before making the task ready.
    @call(.never_inline, forceReschedule, .{});
    return node.granted;
}

/// Portable half of `sleepOn`: link WaitNode + mark current task blocked.
/// Does not switch away — callers that need a reschedule invoke `forceReschedule`
/// (or install `setPortableReschedule` on non-x86 bring-up).
pub fn blockOn(queue: *?*task.WaitNode, node: *task.WaitNode) bool {
    const cur_idx = currentTaskIndex() orelse return false;
    const cur = task.getTask(cur_idx) orelse return false;

    node.task_idx = cur_idx;
    node.granted = false;
    node.next = queue.*;
    queue.* = node;

    cur.state = .blocked;
    cur.wait_queue = queue;
    return true;
}

/// Optional hook replacing the x86 `timerTick` path inside `forceReschedule`.
/// Used by non-x86 probes (SK-19) until a portable switch backend exists.
var portable_reschedule: ?*const fn () void = null;

pub fn setPortableReschedule(hook: ?*const fn () void) void {
    portable_reschedule = hook;
}

/// Publish the running task index (bring-up / probes). `null` clears current.
pub fn setCurrentTaskIndex(idx: ?u32) void {
    setCurrentIdx(idx);
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
                if (per_cpu.isAnyReady()) _ = per_cpu.enqueueTask(t);
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
            if (per_cpu.isAnyReady()) _ = per_cpu.enqueueTask(t);
        }
        current = node.next;
    }
    queue.* = null;
}

/// Force an immediate reschedule. Used by blocking primitives (futex, etc.)
/// after marking the current task as blocked.
pub fn forceReschedule() void {
    // Capture caller continuation before any further calls clobber ra/lr (SK-20).
    const cont_rip: u64 = if (comptime builtin.cpu.arch == .riscv64)
        asm volatile ("mv %[r], ra"
            : [r] "=r" (-> u64),
        )
    else if (comptime builtin.cpu.arch == .aarch64)
        asm volatile ("mov %[r], x30"
            : [r] "=r" (-> u64),
        )
    else
        @returnAddress();
    const caller_sp: u64 = arch_cpu.readStackPointer();
    forceRescheduleContinue(cont_rip, caller_sp);
}

fn forceRescheduleContinue(cont_rip: u64, caller_sp: u64) void {
    setSlice(0);
    if (portable_reschedule) |h| {
        h();
        return;
    }
    if (comptime builtin.cpu.arch == .x86_64) {
        // Raise the yield trap instead of driving the scheduler from this stack.
        // The scheduler hands the CPU over by rewriting the per-CPU stack anchor
        // and switching CR3, and only an interrupt return consumes that anchor.
        // Called from a syscall, the switch therefore never happened: the
        // syscall returned through `sysretq` on its own stack while CR3 already
        // belonged to the next task, so the caller resumed in another address
        // space — with no user mappings at all when that task was a kernel one.
        comptime {
            if (idt.YIELD_TRAP_VECTOR != 252) @compileError("update the int immediate below");
        }
        asm volatile ("int $252" ::: .{ .memory = true });
    } else if (comptime context_switch.uses_software_frame) {
        portableKernelSwitch(cont_rip, caller_sp);
    }
}

/// SK-20: cooperative switch on software InterruptFrames (non-x86).
///
/// * `.running` → save a continuation frame (yield) then enqueue.
/// * `.blocked` → leave `saved_rsp` alone (caller installed a resume frame).
fn portableKernelSwitch(cont_rip: u64, caller_sp: u64) noreturn {
    const next_idx = pickNext() orelse {
        while (true) arch_cpu.waitForInterrupt();
    };

    if (getCurrentIdx()) |cur_idx| {
        if (cur_idx == next_idx) {
            while (true) arch_cpu.waitForInterrupt();
        }
        const cur = task.getTask(cur_idx) orelse {
            while (true) arch_cpu.waitForInterrupt();
        };
        if (cur.state == .running) {
            const frame_addr = (cur.kernel_stack_top -% 2 * @sizeOf(idt.InterruptFrame)) & ~@as(u64, 15);
            const frame: *idt.InterruptFrame = @ptrFromInt(frame_addr);
            const bytes: [*]u8 = @ptrCast(frame);
            @memset(bytes[0..@sizeOf(idt.InterruptFrame)], 0);
            frame.rip = cont_rip;
            frame.rsp = caller_sp;
            frame.cs = 0x08;
            frame.rflags = 0x202;
            frame.ss = 0x10;
            cur.saved_rsp = frame_addr;
            setAnchor(frame_addr);
            cur.state = .ready;
            enqueue(cur);
        }
        // .blocked: resume frame already in saved_rsp (SK-20 sleepOn path).
    }

    const new_task = task.getTask(next_idx) orelse {
        while (true) arch_cpu.waitForInterrupt();
    };
    if (!new_task.started) setupInitialFrame(new_task);
    new_task.state = .running;
    setCurrentIdx(next_idx);
    setAnchor(new_task.saved_rsp);
    context_switch.switchToSoftwareFrame(new_task.saved_rsp);
}

/// SK-24: preempt from a hardware timer IRQ. Builds a software continuation
/// from the native trap frame (interrupted PC/SP) and switches away — never
/// returns to the IRQ epilogue.
pub fn preemptFromIrq(trap_frame_ptr: u64) noreturn {
    const cont_rip = context_switch.irqInterruptedPc(trap_frame_ptr);
    const caller_sp = context_switch.irqInterruptedSp(trap_frame_ptr);
    setSlice(TIMESLICE_TICKS);
    portableKernelSwitch(cont_rip, caller_sp);
}

/// SK-29: IRQ-safe native TrapFrame preempt driven by shared enqueue/pick.
///
/// Relocates the live TrapFrame onto the current task's kernel stack when it
/// still sits on a shared U-mode trap stack (riscv), then picks the next ready
/// task **before** enqueueing the current one (per-CPU queue is LIFO), and
/// returns the next task's TrapFrame pointer for the arch IRQ epilogue.
/// Does **not** call `switchToSoftwareFrame` / `preemptFromIrq`.
pub fn nativeTrapFramePreempt(frame_ptr: u64) ?u64 {
    const cur_idx = getCurrentIdx() orelse return null;
    const cur = task.getTask(cur_idx) orelse return null;

    // Pick while current is still `.running` and not on the ready queue.
    // Resolve `next` before mutating `cur`, so a bad pick cannot leave the
    // running task marked `.ready` on the queue.
    const next_idx = pickNext() orelse return null;
    if (next_idx == cur_idx) return null;
    const next = task.getTask(next_idx) orelse return null;

    // Relocate only when a switch actually happens: the no-switch case above
    // is the common idle path, and relocation may memcpy the live frame.
    // Must precede `enqueue(cur)` so a stealing CPU sees a valid saved_rsp.
    cur.saved_rsp = context_switch.relocateNativeTrapFrame(
        frame_ptr,
        cur.kernel_stack,
        cur.kernel_stack_top,
    );

    cur.state = .ready;
    enqueue(cur);

    next.state = .running;
    setCurrentIdx(next_idx);
    setAnchor(next.saved_rsp);
    return next.saved_rsp;
}

/// SK-30: account one hardware timer tick; when the timeslice expires, preempt
/// via native TrapFrame switch (not software `preemptFromIrq`).
/// Returns `null` when the slice has not expired (caller resumes same frame).
pub fn nativeUserTimerPreempt(frame_ptr: u64) ?u64 {
    if (!hardwareTimerTick()) return null;
    setSlice(TIMESLICE_TICKS);
    return nativeTrapFramePreempt(frame_ptr);
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
/// F3: no-op for SCHED_FIFO/RR tasks — nice is orthogonal to the realtime
/// classes (Linux: nice only affects SCHED_OTHER/BATCH/IDLE).
pub fn setNice(t: *task.Task, nice: i32) void {
    if (sched_policy.isRtClass(t.sched_policy)) return;
    const clamped: i32 = @max(-20, @min(19, nice));
    const new_prio: u8 = @intCast(clamped + 20);
    t.priority = new_prio;
}

/// Get the nice value of a task from its internal priority.
/// F3: RT tasks report nice 0 (their `priority` field holds the RT band
/// 0..98, which is meaningless as a nice value).
pub fn getNice(t: *task.Task) i32 {
    if (sched_policy.isRtClass(t.sched_policy)) return 0;
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
