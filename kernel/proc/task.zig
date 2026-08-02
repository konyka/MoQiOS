/// Task (kernel thread) management — task struct, state, create/destroy.
/// Each task has a kernel stack and is managed by the scheduler.
///
/// Lifecycle: created (ready) → running → ready → ... → blocked → ready → ... → zombie → reaped
/// State transitions:
///   createKernelThread  → ready
///   scheduler picks     → running
///   timeslice expires   → ready
///   task blocks (wait)  → blocked
///   resource available  → ready
///   task exits          → zombie
///   reapZombies         → freed
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const serial = @import("../arch/arch.zig").serial;
const paging = @import("../arch/arch.zig").paging;
const arch_cpu = @import("../arch/arch.zig").cpu;
const arch_irq = @import("../arch/arch.zig").interrupts;
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const sched_policy = @import("sched_policy.zig");
const builtin = @import("builtin");

const PAGE_SIZE: u64 = 4096;
const KERNEL_STACK_PAGES: u64 = 32;
const KERNEL_STACK_VIRT_BASE: u64 = 0xffffffff90000000;
const KERNEL_STACK_STRIDE: u64 = 256 * 1024;
// allocates large arrays on the stack (e.g., code_pages[256]?u64 = 2KB).
// The stack grows downward from kernel_stack_top.

/// SK-38: env storage sizes. Non-x86 bring-up has no exec/env syscalls, so a
/// minimal table avoids 3.8KB of dead BSS in every task slot.
pub const ENV_MAX_VARS: u32 = if (builtin.cpu.arch == .x86_64) 32 else 4;
pub const ENV_VAR_BYTES: u32 = if (builtin.cpu.arch == .x86_64) 128 else 64;

pub const TaskState = enum(u8) {
    ready = 0,
    running = 1,
    blocked = 2,
    zombie = 3,
};

pub const TaskFunc = *const fn () callconv(.c) void;

/// Kernel thread control block.
/// Wait queue node — stack-allocated on the waiter's kernel stack.
/// Same pattern used by eventfd, timerfd, epoll.
pub const WaitNode = struct {
    task_idx: u32,
    granted: bool = false,
    next: ?*WaitNode = null,
};

pub const Task = struct {
    tid: u32,
    /// v53.45: Slot index for O(1) reverse lookup (set by create functions).
    self_idx: u32 = 0,
    state: TaskState,
    priority: u8,
    /// CPU affinity. -1 = no pin (eligible for any CPU / work-stealing);
    /// >=0 = hard-pinned to that logical CPU (Task #2: pinned tasks are
    /// never stolen by another CPU's run queue).
    cpu_affinity: i16 = -1,
    /// Last CPU this task ran on. Used by Task #2 for run-queue placement
    /// preference (warm cache) and as the fallback target when not pinned.
    last_cpu: u8 = 0,
    /// Kernel stack base (lowest address, page-aligned).
    kernel_stack: u64,
    /// Kernel stack top (highest address — this is where RSP starts).
    kernel_stack_top: u64,
    /// Saved RSP for context switch (points into kernel stack where registers are saved).
    saved_rsp: u64,
    /// Entry function (for kernel threads).
    entry: ?TaskFunc,
    /// Whether this task has ever been scheduled.
    started: bool,
    /// Exit code (valid when state == .zombie).
    exit_code: i32,

    // --- User-space fields (M5) ---
    /// Physical address of the process's PML4 page table (0 for kernel threads).
    page_table_phys: u64,
    /// Personality: native, linux, or windows ABI.
    personality: @import("../arch/arch.zig").syscall.Personality,
    /// Whether this task runs in user mode.
    is_user: bool,
    /// User-space entry point (RIP).
    user_entry: u64,
    /// User-space stack top (RSP for ring3).
    user_stack_top: u64,
    /// User RSP saved across syscall/block (M8-5b-2d — per-task, not per-CPU).
    saved_user_rsp: u64,
    /// Stack limit (lowest address the stack may grow to). Auto-extended on page fault.
    stack_limit: u64,
    /// TID of the parent process (0 if spawned by kernel). Used by waitpid.
    parent_tid: u32,
    /// Whether this task is waiting for a child to exit (for blocking waitpid).
    waiting_for_child: bool,
    /// CPU where the task blocked in waitpid (for cross-core wake IPI).
    wait_cpu: u8,
    /// Current program break (end of heap). 0 = not initialized.
    /// brk syscall uses this to manage the heap region.
    brk_current: u64,
    /// Lowest address the break may return to — the initial break set by the
    /// loader. Shrinking past it would unmap the loaded image itself.
    brk_start: u64,
    /// Thread-local storage base for this task (x86_64 FS_BASE). Installed by
    /// the scheduler when the task is put on a CPU, so each thread sees its own
    /// TLS regardless of which CPU it lands on. 0 = no TLS.
    tls_base: u64,
    /// Per-process file descriptor table.
    fd_table: @import("../fs/vfs.zig").FdTable,

    /// Bitmask of pending signals (bit N = signal N+1 is pending).
    /// Signals 1-31 supported. Bit 0 = SIGHUP (1), bit 30 = SIGUSR2 (31).
    pending_signals: u32,

    /// Signal mask — blocked signals (bit N = signal N+1 is blocked).
    /// SIGKILL (9) and SIGSTOP (19) cannot be blocked.
    /// 64-bit to match the rt_* sigset_t ABI; only bits 0-30 are meaningful
    /// (pending_signals stays u32 — signals 1-31 are supported).
    signal_mask: u64,

    /// Signal handler addresses. 0 = default (terminate for now).
    /// Index 0 = signal 1 (SIGHUP), ..., index 30 = signal 31 (SIGUSR2).
    signal_handlers: [31]u64,

    /// Alternate signal stack base address (0 = not set, use user RSP).
    sigaltstack_base: u64,

    /// Alternate signal stack size.
    sigaltstack_size: u64,

    /// Environment variables (key=value pairs).
    env_vars: [ENV_MAX_VARS][ENV_VAR_BYTES]u8,
    env_count: u32,

    /// Current working directory (null-terminated, max 256 chars).
    cwd: [256]u8,
    cwd_len: u32,

    /// Process group ID (inherited from parent on fork).
    pgid: u16,
    /// Session ID (inherited from parent on fork).
    sid: u16,

    // --- Process credentials (POSIX) ---
    /// Real user ID. Default 0 (root). Inherited on fork.
    uid: u32 = 0,
    /// Real group ID. Default 0 (root). Inherited on fork.
    gid: u32 = 0,
    /// Effective user ID (used for permission checks). Default 0 (root).
    euid: u32 = 0,
    /// Effective group ID. Default 0 (root).
    egid: u32 = 0,
    /// Saved set-user-ID (for setuid programs). Default 0 (root).
    suid: u32 = 0,
    /// Saved set-group-ID. Default 0 (root).
    sgid: u32 = 0,

    /// Wait queue for blocking operations (waitpid, pipe, etc.).
    /// The task sleeps on this queue until woken.
    wait_queue: ?*?*WaitNode,

    /// Wait queue for parent waitpid — woken when this task exits.
    exit_waiters: ?*WaitNode,

    /// Per-process umask (file creation mode mask). Default 0o022.
    umask_val: u32 = 0o022,

    /// CPU time consumed in kernel mode (microseconds, accumulated on context switch).
    utime_us: u64 = 0,
    /// CPU time consumed in user mode (microseconds, approximated).
    stime_us: u64 = 0,
    /// Last TSC value when this task was scheduled in (for CPU time accounting).
    sched_in_tsc: u64 = 0,
    /// Number of voluntary context switches.
    nvcsw: u64 = 0,
    /// Number of involuntary context switches.
    nivcsw: u64 = 0,

    /// mmap region tracking — records all mmap'd address ranges for munmap.
    /// Each entry stores (base_addr, num_pages). Max 64 regions per process.
    mmap_regions: [64]MmapRegion = [_]MmapRegion{.{}} ** 64,
    mmap_count: u32 = 0,

    /// Process name (for prctl PR_SET_NAME / /proc/<pid>/comm).
    comm: [16]u8 = [_]u8{0} ** 16,

    /// Robust futex list head (set by set_robust_list syscall).
    robust_list_head: u64 = 0,
    /// Robust futex list length (set by set_robust_list syscall).
    robust_list_len: u32 = 0,

    /// Scheduling policy: 0=OTHER, 1=FIFO, 2=RR, 3=BATCH, 6=DEADLINE.
    /// F3: OTHER/FIFO/RR are honoured by the scheduler. For FIFO/RR the
    /// `priority` field holds the RT kernel band 0..98 (rtToKernelPriority,
    /// lower = better; sched_priority 1..99 maps to 98..0); for OTHER it
    /// stays in the nice band (see sched.setNice). See proc/sched_policy.zig.
    sched_policy: u8 = 0,

    /// alarm() deadline in TSC nanoseconds (0 = no alarm set).
    alarm_deadline: u64 = 0,

    /// ITIMER_REAL: next expiration deadline (ns) and recurring interval (ns).
    itimer_real_value: u64 = 0,
    itimer_real_interval: u64 = 0,

    /// Parent death signal (0 = none). Delivered to child when parent exits.
    pdeathsig: u32 = 0,

    // --- FPU / SSE state (Task #1: lazy save/restore via CR0.TS + #NM) ---
    /// FXSAVE/FXRSTOR area. Hardware requires 16-byte alignment; the
    /// `align(16)` directive forces Task itself to 16-byte alignment so the
    /// field is well-aligned in every slot of the static `tasks` array.
    fpu_state: [512]u8 align(16) = [_]u8{0} ** 512,
    /// Whether this task has ever issued an FPU/SSE instruction (and thus
    /// has meaningful state in `fpu_state`). Set on the first #NM, never
    /// cleared — once a task has used FPU it always restores from its area.
    fpu_initialized: bool = false,
    /// Whether this task currently "owns" the FPU on the CPU it last ran on.
    /// Drives onContextSwitch's eager fxsave: only set after a successful
    /// #NM lazy-restore; cleared by the #NM handler of a different task that
    /// claims the FPU on the same CPU.
    fpu_owned: bool = false,

    // --- POSIX system capabilities (Task #8) ---
    /// Effective capabilities — currently active permissions.
    effective_caps: @import("../ipc/capability.zig").SysCap = @import("../ipc/capability.zig").ALL_CAPS,
    /// Permitted capabilities — upper bound of what can be effective.
    permitted_caps: @import("../ipc/capability.zig").SysCap = @import("../ipc/capability.zig").ALL_CAPS,
    /// Inheritable capabilities — passed across fork/exec.
    inheritable_caps: @import("../ipc/capability.zig").SysCap = @import("../ipc/capability.zig").ALL_CAPS,
};

/// Tracked mmap region for munmap support.
pub const MmapRegion = struct {
    base: u64 = 0,
    num_pages: u64 = 0,
    /// 0 = free slot
    active: bool = false,
    /// Whether this region is mlock'd (non-swappable).
    locked: bool = false,
};

pub const MAX_TASKS: u32 = 64;

/// Task table. Slots are NOT optionals: a `Task` is ~62KB (dominated by the
/// per-fd readahead caches plus env/cwd buffers), and storing it in a `?Task`
/// forced the compiler to materialise a full-size temporary on the kernel
/// stack on every create/assign, which overflowed the boot stack. Occupancy is
/// tracked exclusively by `slot_bitmap`; an entry is only valid when its bit is
/// set. Tasks are built in place via `zeroSlot` + field writes — no large value
/// is ever copied through the stack.
var tasks: [MAX_TASKS]Task = undefined;
var next_tid: u32 = 1;
var task_count: u32 = 0;

// Kernel stacks live in the shared upper half of every user address space.
// Reusing a slot must therefore reuse its mapping as well: tearing a stack
// down and remapping it races with CPUs that still cache the old global TLB
// entry. The bounded cache costs at most MAX_TASKS * 128KiB (8MiB) and removes
// PMM/page-table/TLB work from the spawn/reap hot path.
var kernel_stack_mapped: [MAX_TASKS]bool = [_]bool{false} ** MAX_TASKS;

/// Zero a task slot in place (never via a stack temporary). All Task fields
/// have a valid all-zero representation, so callers only need to set the
/// handful of non-default fields afterwards.
fn zeroSlot(slot: u32) void {
    const bytes: [*]u8 = @ptrCast(&tasks[slot]);
    @memset(bytes[0..@sizeOf(Task)], 0);
}
var task_lock: IrqSpinlock = .{};

/// Bitmap of occupied task slots — bit N set means tasks[N] is non-null.
/// Enables O(1) skip of empty slot ranges in scheduler pickNext.
var slot_bitmap: u64 = 0;

/// Return bitmap of occupied task slots (for scheduler fast path).
pub fn getSlotBitmap() u64 {
    return slot_bitmap;
}

pub fn freeSlotCount() u32 {
    return MAX_TASKS - @popCount(slot_bitmap);
}

/// True if `t`'s affinity allows it to run on `cpu` (-1 = no pin).
fn matchesCpu(t: *Task, cpu: u8) bool {
    return t.cpu_affinity < 0 or t.cpu_affinity == @as(i16, cpu);
}

fn considerReady(idx: u32, cpu: u8, best_idx: *?u32, best_key: *u16) void {
    const t = getTask(idx) orelse return;
    if (t.state == .ready and matchesCpu(t, cpu)) {
        // F3: class-aware rank — any runnable FIFO/RR task outranks every
        // OTHER task. Within the OTHER class keys are monotonic in kernel
        // priority, so OTHER-only picks are identical to the pre-F3 raw
        // `t.priority < best_prio` comparison (strict < keeps scan order).
        const key = sched_policy.rankKey(t.sched_policy, t.priority);
        if (key >= best_key.*) return;
        // Never pick a task that another CPU is still running (see
        // isCurrentOnOtherCpu) — its kstack/context are live over there.
        if (isCurrentOnOtherCpu(idx, cpu)) return;
        best_key.* = key;
        best_idx.* = idx;
    }
}

/// Priority round-robin pick under one task_lock snapshot (SMP-safe).
pub fn pickReadyForCpu(cpu: u8, after_idx: ?u32) ?u32 {
    const flags = task_lock.acquire();
    defer task_lock.release(flags);

    const start = if (after_idx) |a| (a + 1) % MAX_TASKS else 0;
    var best_idx: ?u32 = null;
    // F3: MAX_PICK_KEY keeps idle-priority (255) OTHER tasks unpickable here,
    // exactly like the old `best_prio = 255` initialiser.
    var best_key: u16 = sched_policy.MAX_PICK_KEY;

    var pos: u32 = start;
    var remaining: u32 = MAX_TASKS;
    while (remaining > 0) {
        const mask: u64 = if (pos == 0) ~@as(u64, 0) else ~@as(u64, 0) << @intCast(pos);
        const available = slot_bitmap & mask;
        const next_slot = if (available != 0) @ctz(available) else null;
        if (next_slot == null or next_slot.? >= MAX_TASKS) break;
        const idx: u32 = @intCast(next_slot.?);
        remaining -= (idx - pos) + 1;
        pos = idx + 1;
        considerReady(idx, cpu, &best_idx, &best_key);
        if (best_key == 0) break; // RT sched_priority 99 — nothing can outrank it
    }

    if (best_idx == null and start > 0) {
        const wrap_mask: u64 = if (start >= 64) 0 else (~@as(u64, 0)) >> @intCast(64 - start);
        var bits = slot_bitmap & wrap_mask;
        while (bits != 0) {
            const idx: u32 = @intCast(@ctz(bits));
            bits &= bits - 1;
            considerReady(idx, cpu, &best_idx, &best_key);
            if (best_key == 0) break;
        }
    }

    return best_idx;
}

/// Prefer a ready kernel thread on `cpu` when this CPU has no current task.
pub fn pickKernelBootstrapForCpu(cpu: u8) ?u32 {
    const flags = task_lock.acquire();
    defer task_lock.release(flags);
    var bits = slot_bitmap;
    while (bits != 0) {
        const i: u32 = @intCast(@ctz(bits));
        bits &= bits - 1;
        const t = getTask(i) orelse continue;
        if (t.state == .ready and !t.is_user and matchesCpu(t, cpu)) {
            // Same double-current guard as considerReady/popRunnable: an
            // unpinned kernel thread just woken may still be another CPU's
            // current until that CPU switches away.
            if (isCurrentOnOtherCpu(i, cpu)) continue;
            return i;
        }
    }
    return null;
}

/// Count active (non-zombie/non-blocked) tasks on `cpu` under task_lock.
pub fn countActiveOnCpu(cpu: u8) u32 {
    const flags = task_lock.acquire();
    defer task_lock.release(flags);
    var n: u32 = 0;
    var bits = slot_bitmap;
    while (bits != 0) {
        const i: u32 = @intCast(@ctz(bits));
        bits &= bits - 1;
        const t = getTask(i) orelse continue;
        if (matchesCpu(t, cpu) and t.state != .zombie and t.state != .blocked) {
            n += 1;
        }
    }
    return n;
}

/// True if any ready task is pinned to `cpu` (scheduler fast-path helper).
pub fn hasReadyOnCpu(cpu: u8) bool {
    const flags = task_lock.acquire();
    defer task_lock.release(flags);
    var bits = slot_bitmap;
    while (bits != 0) {
        const i: u32 = @intCast(@ctz(bits));
        bits &= bits - 1;
        const t = getTask(i) orelse continue;
        if (t.state == .ready and matchesCpu(t, cpu)) return true;
    }
    return false;
}

/// Find a free task slot using bitmap fast-path.
fn allocSlot() ?u32 {
    const free_bits = ~slot_bitmap;
    if (free_bits == 0) return null;
    const slot = @ctz(free_bits);
    if (slot >= MAX_TASKS) return null;
    return @intCast(slot);
}

fn reserveSlotLocked() ?u32 {
    const slot = allocSlot() orelse return null;
    slot_bitmap |= @as(u64, 1) << @intCast(slot);
    return slot;
}

fn stackVirtForSlot(slot: u32) u64 {
    return KERNEL_STACK_VIRT_BASE + @as(u64, slot) * KERNEL_STACK_STRIDE;
}

/// Allocate a virtually contiguous kernel stack without requiring contiguous
/// physical pages. The stack lives in a fixed high-half virtual window per task
/// slot. Once allocated, a slot keeps its mapping for the life of the kernel so
/// user CR3s sharing the upper-half page tables never see a stack remap.
///
/// Non-x86 (SK-12): Sv39/EL1 bring-up uses identity maps (hhdm offset 0), so
/// allocate a contiguous physical run and treat phys==virt.
fn allocKernelStackForSlot(slot: u32) ?u64 {
    if (comptime builtin.cpu.arch != .x86_64) {
        const stack_phys = pmm.allocContiguous(KERNEL_STACK_PAGES) orelse return null;
        return hhdm.physToVirt(stack_phys);
    } else {
        const stack_virt = stackVirtForSlot(slot);
        if (kernel_stack_mapped[slot]) return stack_virt;

        var allocated: [KERNEL_STACK_PAGES]u64 = undefined;
        var count: usize = 0;
        while (count < KERNEL_STACK_PAGES) : (count += 1) {
            const phys = pmm.allocPage() orelse {
                freeKernelStackPages(stack_virt, allocated[0..count]);
                return null;
            };
            allocated[count] = phys;
            const page_virt = stack_virt + @as(u64, count) * PAGE_SIZE;
            paging.mapPage(paging.getKernelPml4(), page_virt, phys, .{
                .writable = true,
                .user = false,
                .no_execute = true,
                .global = true,
            }) catch {
                pmm.freePage(phys);
                freeKernelStackPages(stack_virt, allocated[0..count]);
                return null;
            };
        }
        kernel_stack_mapped[slot] = true;
        return stack_virt;
    }
}

/// Release a task's kernel stack.
///
/// x86_64 intentionally retains fixed-slot stacks. They are shared upper-half
/// mappings, so remapping them during task-slot reuse would require a costly
/// global TLB shootdown and can race with CPUs executing another user CR3.
fn freeKernelStack(stack_virt: u64) void {
    if (comptime builtin.cpu.arch != .x86_64) {
        var i: u64 = 0;
        while (i < KERNEL_STACK_PAGES) : (i += 1) {
            pmm.freePage(hhdm.virtToPhys(stack_virt + i * PAGE_SIZE));
        }
    }
}

fn freeKernelStackPages(stack_virt: u64, pages: []const u64) void {
    for (pages, 0..) |phys, i| {
        _ = paging.unmapPage(paging.getKernelPml4(), stack_virt + @as(u64, i) * PAGE_SIZE);
        pmm.freePage(phys);
    }
}

var next_assign_cpu: u32 = 0;

/// CPU pin for new user tasks: flat round-robin across online CPUs.
/// Each task gets its own PML4, so no cross-CPU TLB shootdown is needed.
/// fork inherits parent's affinity (handled in fork.zig).
pub fn assignCpuAffinity(elf: bool) u8 {
    const smp = @import("../smp.zig");
    _ = elf;
    const ncpus = smp.configured_cpu_count;
    if (ncpus <= 1) return 0;
    const cpu: u8 = @truncate(next_assign_cpu % ncpus);
    next_assign_cpu += 1;
    return cpu;
}

/// Create a kernel thread pinned to a specific CPU (M8-5b-2).
pub fn createKernelThreadAffinity(entry: TaskFunc, priority: u8, affinity: u8) ?u32 {
    const flags = task_lock.acquire();
    defer task_lock.release(flags);

    const slot = reserveSlotLocked() orelse {
        serial.writeString("[task] no free task slots\n");
        return null;
    };

    const stack_virt = allocKernelStackForSlot(slot) orelse {
        serial.writeString("[task] OOM allocating kernel stack\n");
        slot_bitmap &= ~(@as(u64, 1) << @intCast(slot));
        return null;
    };
    const stack_top = stack_virt + KERNEL_STACK_PAGES * PAGE_SIZE;

    const tid = next_tid;
    next_tid += 1;

    zeroSlot(slot);
    tasks[slot].self_idx = slot;
    tasks[slot].tid = tid;
    tasks[slot].state = .ready;
    tasks[slot].priority = priority;
    tasks[slot].kernel_stack = stack_virt;
    tasks[slot].kernel_stack_top = stack_top;
    tasks[slot].entry = entry;
    tasks[slot].personality = .native;
    @import("../fs/vfs.zig").FdTable.initInto(&tasks[slot].fd_table);
    tasks[slot].cwd[0] = '/';
    tasks[slot].cwd_len = 1;
    tasks[slot].cpu_affinity = affinity;
    tasks[slot].last_cpu = affinity;

    // Task #8: POSIX caps default to ALL_CAPS (zeroSlot would leave them at
    // NO_CAPS, which would break every existing capability-checked syscall).
    const _cap_init_kt_aff = @import("../ipc/capability.zig");
    tasks[slot].effective_caps = _cap_init_kt_aff.ALL_CAPS;
    tasks[slot].permitted_caps = _cap_init_kt_aff.ALL_CAPS;
    tasks[slot].inheritable_caps = _cap_init_kt_aff.ALL_CAPS;

    task_count += 1;
    asm volatile ("" ::: .{ .memory = true });
    return slot;
}

/// Roll back a kernel thread that has not entered the scheduler yet. Its fixed
/// stack mapping remains cached for the slot, matching normal task reuse.
pub fn cancelUnstartedKernelThread(slot: u32) void {
    const flags = task_lock.acquire();
    defer task_lock.release(flags);
    const t = getTask(slot) orelse return;
    if (t.is_user or t.started or t.state != .ready) return;
    slot_bitmap &= ~(@as(u64, 1) << @intCast(slot));
    task_count -= 1;
}

/// Create an unpinned kernel thread (cpu_affinity = -1, eligible for stealing).
/// Returns the task index or null on failure. Starts in .ready state.
pub fn createKernelThread(entry: TaskFunc, priority: u8) ?u32 {
    const flags = task_lock.acquire();
    defer task_lock.release(flags);

    const slot = reserveSlotLocked() orelse {
        serial.writeString("[task] no free task slots\n");
        return null;
    };
    const stack_virt = allocKernelStackForSlot(slot) orelse {
        serial.writeString("[task] OOM allocating kernel stack\n");
        slot_bitmap &= ~(@as(u64, 1) << @intCast(slot));
        return null;
    };
    const stack_top = stack_virt + KERNEL_STACK_PAGES * PAGE_SIZE;
    const tid = next_tid;
    next_tid += 1;
    zeroSlot(slot);
    tasks[slot].self_idx = slot;
    tasks[slot].tid = tid;
    tasks[slot].state = .ready;
    tasks[slot].priority = priority;
    tasks[slot].kernel_stack = stack_virt;
    tasks[slot].kernel_stack_top = stack_top;
    tasks[slot].entry = entry;
    tasks[slot].personality = .native;
    @import("../fs/vfs.zig").FdTable.initInto(&tasks[slot].fd_table);
    tasks[slot].cwd[0] = '/';
    tasks[slot].cwd_len = 1;
    tasks[slot].cpu_affinity = -1;
    tasks[slot].last_cpu = 0;
    // Task #8: POSIX caps default to ALL_CAPS (see createKernelThreadAffinity).
    const _cap_init_kt = @import("../ipc/capability.zig");
    tasks[slot].effective_caps = _cap_init_kt.ALL_CAPS;
    tasks[slot].permitted_caps = _cap_init_kt.ALL_CAPS;
    tasks[slot].inheritable_caps = _cap_init_kt.ALL_CAPS;
    task_count += 1;
    asm volatile ("" ::: .{ .memory = true });
    return slot;
}

/// Get task by index. Returns null if slot is empty or out of range.
pub fn getTask(idx: u32) ?*Task {
    if (idx >= MAX_TASKS) return null;
    if (slot_bitmap & (@as(u64, 1) << @intCast(idx)) == 0) return null;
    return &tasks[idx];
}

/// Mark the current task as exiting (zombie). Called from the task itself.
/// The scheduler will skip zombie tasks. Use reapZombies() to free resources.
/// If the parent is waiting (waitpid), unblock it so it can collect the exit code.
pub fn exitTask(exit_code: i32) void {
    const sched = @import("sched.zig");
    const idx = sched.currentTaskIndex() orelse return;
    const t = getTask(idx) orelse return;

    // v53.48: Close all open file descriptors before becoming a zombie.
    // Without this, TCP connections, pipes, ext2/fat32 files, and epoll
    // instances permanently leak their underlying resources.
    {
        const vfs = @import("../fs/vfs.zig");
        var fd: u32 = 3;
        while (fd < vfs.MAX_FDS) : (fd += 1) {
            if (t.fd_table.fds[fd].fd_type != .none) {
                _ = t.fd_table.close(fd);
            }
        }
    }

    // Detach any SysV SHM segments still attached (shmat without shmdt) —
    // otherwise attach_count leaks and IPC_RMID segments are never freed.
    if (t.page_table_phys != 0) {
        @import("../ipc/sysv_shm.zig").detachAllForTask(t.tid, t.page_table_phys);
    }

    const flags = task_lock.acquire();
    t.exit_code = exit_code;
    t.state = .zombie;
    asm volatile ("" ::: .{ .memory = true });

    // Wake parent if sleeping on our exit_waiters queue
    if (t.exit_waiters != null) {
        // wakeAll modifies the list, safe to call under task_lock
        sched.wakeAll(&t.exit_waiters);
    }

    // Legacy: also wake parent via waiting_for_child flag
    if (t.parent_tid != 0) {
        if (findTaskByTidLocked(t.parent_tid)) |parent_idx| {
            const parent = getTask(parent_idx) orelse {
                task_lock.release(flags);
                arch_irq.enableIrq();
                while (true) {
                    arch_cpu.waitForInterrupt();
                }
            };
            if (parent.waiting_for_child) {
                parent.waiting_for_child = false;
                parent.state = .ready;
                asm volatile ("" ::: .{ .memory = true });
                sched.kickCpu(parent.wait_cpu);
            }
        }
    }
    task_lock.release(flags);

    // Prompt the next timer interrupt to switch away from this zombie. Avoid
    // calling timerTick recursively from inside syscall/fault exit paths: that
    // can resume a different task while the current kernel stack is still deep
    // in exitTask.
    sched.requestReschedule();
    arch_irq.enableIrq();
    while (true) {
        arch_cpu.waitForInterrupt();
    }
}

/// True while some CPU's per-CPU `current_task_idx` still points at `idx`.
/// A zombie stays "current" on its CPU until that CPU's next timer tick
/// switches away. Freeing/reusing the slot (and its fixed kernel stack) inside
/// that window lets the next spawn overwrite IRQ frames the owning CPU is
/// still using — observed as iretq #GP at kstack top right after
/// "[exit] task exited" in SMP=2 stress smoke.
fn isCurrentOnAnyCpu(idx: u32) bool {
    if (comptime builtin.cpu.arch != .x86_64) return false;
    const se = @import("../arch/x86_64/syscall_entry.zig");
    for (se.configuredPerCpuSlice()) |*pc| {
        if (@atomicLoad(u32, &pc.current_task_idx, .acquire) == idx) return true;
    }
    return false;
}

/// True while a CPU other than `my_cpu` has `idx` as its current task.
/// A woken (.ready) task can still be another CPU's current (e.g. a blocked
/// waitpid parent keeps cur_idx until its CPU switches away). Picking it from
/// here would run one task on two CPUs — two live contexts on one kernel
/// stack. Pickers must skip such tasks; the owning CPU resumes them itself.
pub fn isCurrentOnOtherCpu(idx: u32, my_cpu: u32) bool {
    if (comptime builtin.cpu.arch != .x86_64) return false;
    const se = @import("../arch/x86_64/syscall_entry.zig");
    for (se.configuredPerCpuSlice(), 0..) |*pc, cpu| {
        if (cpu == my_cpu) continue;
        if (@atomicLoad(u32, &pc.current_task_idx, .acquire) == idx) return true;
    }
    return false;
}

/// Reap orphaned zombie tasks — those whose parent has already exited.
/// Zombies with a living parent are left for waitpid() to collect.
pub fn reapZombies() u32 {
    const flags = task_lock.acquire();
    defer task_lock.release(flags);

    var reaped: u32 = 0;
    var bits = slot_bitmap;
    while (bits != 0) {
        const i: u32 = @intCast(@ctz(bits));
        bits &= bits - 1;
        const t = &tasks[i];
        if (t.state != .zombie) continue;
        // Still current on some CPU (owner hasn't switched away yet) —
        // defer to the next reap interval instead of yanking a live kstack.
        if (isCurrentOnAnyCpu(i)) continue;

        // Check if parent is still alive
        if (t.parent_tid != 0) {
            if (findTaskByTidLocked(t.parent_tid) != null) {
                // Parent still alive — leave for waitpid
                continue;
            }
            // Parent gone — orphan, reap it
        }

        if (t.page_table_phys != 0) {
            @import("../mm/user_space.zig").destroyUserSpace(t.page_table_phys);
        }
        freeKernelStack(t.kernel_stack);
        slot_bitmap &= ~(@as(u64, 1) << @intCast(i));
        task_count -= 1;
        reaped += 1;
    }
    return reaped;
}

/// Find a task by its TID. Returns the task slot index or null.
/// Internal version — caller must hold task_lock.
/// Uses slot_bitmap to skip empty slots via @ctz.
fn findTaskByTidLocked(tid: u32) ?u32 {
    var bits = slot_bitmap;
    while (bits != 0) {
        const i: u32 = @intCast(@ctz(bits));
        bits &= bits - 1;
        const t = &tasks[i];
        if (t.tid == tid and t.state != .zombie) return i;
    }
    return null;
}

/// Find a task by its TID. Returns the task slot index or null.
/// Public version — acquires task_lock.
pub fn findTaskByTid(tid: u32) ?u32 {
    const flags = task_lock.acquire();
    defer task_lock.release(flags);
    return findTaskByTidLocked(tid);
}

/// Block a task — sets state to blocked. The scheduler will skip it.
pub fn blockTask(idx: u32) void {
    const flags = task_lock.acquire();
    defer task_lock.release(flags);
    const t = getTask(idx) orelse return;
    if (t.state == .running) {
        t.state = .blocked;
    }
}

/// Unblock a task — sets state back to ready.
pub fn unblockTask(idx: u32) void {
    const flags = task_lock.acquire();
    defer task_lock.release(flags);
    const t = getTask(idx) orelse return;
    if (t.state == .blocked) {
        t.state = .ready;
        // Task #2: republish to per-CPU queue (best-effort, full → bitmap fallback).
        const per_cpu = @import("per_cpu.zig");
        if (per_cpu.isAnyReady()) _ = per_cpu.enqueueTask(t);
    }
}

/// Get total task count.
pub fn getTaskCount() u32 {
    return task_count;
}

/// Create a user-space process. Returns the task index or null on failure.
/// The process will be entered via jump_to_user with the given entry point.
/// The kernel stack is allocated from PMM, the user stack and page table
/// must be set up by the caller.
pub fn createUserProcess(
    user_entry: u64,
    user_stack_top: u64,
    page_table_phys: u64,
    parent_tid_val: u32,
    elf: bool,
) ?u32 {
    const slot = blk: {
        const flags = task_lock.acquire();
        defer task_lock.release(flags);

        const slot = reserveSlotLocked() orelse {
            serial.writeString("[task] no free task slots\n");
            return null;
        };
        break :blk slot;
    };

    const stack_virt = allocKernelStackForSlot(slot) orelse {
        serial.writeString("[task] OOM allocating kernel stack\n");
        const flags = task_lock.acquire();
        slot_bitmap &= ~(@as(u64, 1) << @intCast(slot));
        task_lock.release(flags);
        return null;
    };
    const stack_top = stack_virt + KERNEL_STACK_PAGES * PAGE_SIZE;

    {
        const flags = task_lock.acquire();
        defer task_lock.release(flags);
        const tid = next_tid;
        next_tid += 1;

        // Build the large Task in place to avoid overflowing the kernel stack.
        zeroSlot(slot);
        tasks[slot].self_idx = slot;
        tasks[slot].tid = tid;
        // Not runnable yet. fork/clone still have to build the child's
        // interrupt frame, and the loader still has to set up brk; a picker
        // that grabbed the task now would run it with `started == false` and
        // enter it at the ELF entry instead of the fork return. The caller
        // hands it to the scheduler with publishRunnable() when it is ready.
        tasks[slot].state = .blocked;
        tasks[slot].priority = 1;
        tasks[slot].kernel_stack = stack_virt;
        tasks[slot].kernel_stack_top = stack_top;
        tasks[slot].entry = null;
        tasks[slot].page_table_phys = page_table_phys;
        tasks[slot].personality = .native;
        tasks[slot].is_user = true;
        tasks[slot].user_entry = user_entry;
        tasks[slot].user_stack_top = user_stack_top;
        tasks[slot].stack_limit = user_stack_top - 64 * 4096;
        tasks[slot].parent_tid = parent_tid_val;
        @import("../fs/vfs.zig").FdTable.initInto(&tasks[slot].fd_table);
        tasks[slot].cwd[0] = '/';
        tasks[slot].cwd_len = 1;
        // User processes are not pinned by default; last_cpu seeds placement.
        tasks[slot].cpu_affinity = -1;
        tasks[slot].last_cpu = assignCpuAffinity(elf);

        const _cap_init_up = @import("../ipc/capability.zig");
        tasks[slot].effective_caps = _cap_init_up.ALL_CAPS;
        tasks[slot].permitted_caps = _cap_init_up.ALL_CAPS;
        tasks[slot].inheritable_caps = _cap_init_up.ALL_CAPS;

        task_count += 1;
        asm volatile ("mfence" ::: .{ .memory = true });
    }

    @import("signal.zig").setupSigreturnTrampoline(page_table_phys);
    return slot;
}

/// Kick remote CPUs running live children of `parent_tid`.
/// Skips `parent_cpu` — same-CPU children rely on timer preemption of blocked parent.
pub fn kickChildCpus(parent_tid: u32, parent_cpu: u8) void {
    const sched = @import("sched.zig");
    const max_cpus = @import("../arch/arch.zig").syscall.MAX_CPUS;
    var cpus: [max_cpus]u8 = undefined;
    var cpu_count: usize = 0;
    {
        const flags = task_lock.acquire();
        defer task_lock.release(flags);
        var bits = slot_bitmap;
        while (bits != 0) {
            const i: u32 = @intCast(@ctz(bits));
            bits &= bits - 1;
            const t = &tasks[i];
            if (t.parent_tid != parent_tid) continue;
            if (t.state != .ready and t.state != .running) continue;
            // Task #2: prefer last_cpu (where the child actually runs) over
            // affinity, which may be -1 (unpinned) and tell us nothing.
            const cpu = if (t.cpu_affinity >= 0) @as(u8, @intCast(t.cpu_affinity)) else t.last_cpu;
            if (cpu == parent_cpu) continue;
            var seen = false;
            for (cpus[0..cpu_count]) |c| {
                if (c == cpu) {
                    seen = true;
                    break;
                }
            }
            if (!seen and cpu_count < cpus.len) {
                cpus[cpu_count] = cpu;
                cpu_count += 1;
            }
        }
    }
    for (cpus[0..cpu_count]) |cpu| {
        sched.kickCpu(cpu);
    }
}

/// After a user task is published ready, kick its remote affinity CPU.
/// Hand a freshly created task to the scheduler.
///
/// Marking a task `.ready` is not enough to get it run. `pickNext` drains the
/// per-CPU run queue first and only falls back to the bitmap scan when that
/// queue comes up empty — and every context switch re-enqueues the outgoing
/// task, so on a busy CPU the queue never empties. Nothing enqueued new tasks,
/// so a task nobody put in a queue was only ever discovered when the CPU
/// happened to run dry. fork survived on that: the parent normally blocks in
/// waitpid straight after, which drains the queue. A parent that keeps running
/// — a thread creator, say — starved its child indefinitely.
pub fn publishRunnable(slot: u32) void {
    const t = getTask(slot) orelse return;
    {
        const flags = task_lock.acquire();
        defer task_lock.release(flags);
        if (t.state != .blocked) return;
        t.state = .ready;
    }
    asm volatile ("" ::: .{ .memory = true });
    const sched = @import("sched.zig");
    sched.enqueue(t);
    kickRemoteForTask(slot);
}

pub fn kickRemoteForTask(slot: u32) void {
    const t = getTask(slot) orelse return;
    const sched = @import("sched.zig");
    const se = @import("../arch/arch.zig").syscall;
    // Task #2: target the queued CPU. Prefer hard affinity if set, else last_cpu.
    const target_cpu: u8 = if (t.cpu_affinity >= 0) @intCast(t.cpu_affinity) else t.last_cpu;
    const here: u8 = @intCast(se.getPerCpu().cpu_id);
    if (target_cpu == here) return;
    asm volatile ("mfence" ::: .{ .memory = true });
    sched.kickCpu(target_cpu);
}

/// Wait for a child process to exit. Returns the child's TID, or 0 if no
/// child has exited yet (WNOHANG behavior). Writes the exit code to *status.
/// pid == -1 means wait for any child; pid > 0 means wait for specific child.
pub fn waitpid(parent_idx: u32, pid: i32, status: *i32) ?u32 {
    // Retry loop: a zombie child may still be "current" on another CPU for up
    // to one timer tick after exit. Reaping in that window frees a kstack the
    // owner CPU is still executing on, so wait (lock released) until it has
    // switched away. Parent and child cannot share a CPU here — the parent is
    // the one running — so this never spins on itself.
    while (true) {
        const flags = task_lock.acquire();

        const parent = getTask(parent_idx) orelse {
            task_lock.release(flags);
            return null;
        };
        const parent_tid_val = parent.tid;

        // Search for a matching zombie child using bitmap
        var busy_child = false;
        var bits = slot_bitmap;
        while (bits != 0) {
            const i: u32 = @intCast(@ctz(bits));
            bits &= bits - 1;
            const t = &tasks[i];
            if (t.parent_tid != parent_tid_val) continue;
            if (t.state != .zombie) continue;
            if (pid > 0 and t.tid != @as(u32, @intCast(pid))) continue;

            if (isCurrentOnAnyCpu(i)) {
                busy_child = true;
                continue;
            }

            // Found a quiesced zombie child — collect its exit code and reap it
            status.* = t.exit_code;
            const child_tid = t.tid;
            if (t.page_table_phys != 0) {
                @import("../mm/user_space.zig").destroyUserSpace(t.page_table_phys);
            }
            freeKernelStack(t.kernel_stack);
            slot_bitmap &= ~(@as(u64, 1) << @intCast(i));
            task_count -= 1;
            task_lock.release(flags);
            return child_tid;
        }
        task_lock.release(flags);
        if (!busy_child) return null;
        @import("../arch/arch.zig").cpu.pause();
    }
}

/// Check if the given task has any children (for waitpid validation).
pub fn hasChildren(parent_idx: u32) bool {
    const flags = task_lock.acquire();
    defer task_lock.release(flags);
    const parent = getTask(parent_idx) orelse return false;
    const parent_tid_val = parent.tid;
    var bits = slot_bitmap;
    while (bits != 0) {
        const i: u32 = @intCast(@ctz(bits));
        bits &= bits - 1;
        const t = &tasks[i];
        if (t.parent_tid == parent_tid_val) return true;
    }
    return false;
}
