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
const paging = @import("../arch/x86_64/paging.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

const PAGE_SIZE: u64 = 4096;
const KERNEL_STACK_PAGES: u64 = 32;
const KERNEL_STACK_VIRT_BASE: u64 = 0xffffffff90000000;
const KERNEL_STACK_STRIDE: u64 = 256 * 1024;
// allocates large arrays on the stack (e.g., code_pages[256]?u64 = 2KB).
// NOTE: Pages are allocated via PMM and mapped contiguously via HHDM.
// The stack grows downward from kernel_stack_top.

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
    cpu_affinity: i8 = -1,
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
    personality: @import("../arch/x86_64/syscall_entry.zig").Personality,
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
    /// Per-process file descriptor table.
    fd_table: @import("../fs/vfs.zig").FdTable,

    /// Bitmask of pending signals (bit N = signal N+1 is pending).
    /// Signals 1-31 supported. Bit 0 = SIGHUP (1), bit 30 = SIGUSR2 (31).
    pending_signals: u32,

    /// Signal mask — blocked signals (bit N = signal N+1 is blocked).
    /// SIGKILL (9) and SIGSTOP (19) cannot be blocked.
    signal_mask: u32,

    /// Signal handler addresses. 0 = default (terminate for now).
    /// Index 0 = signal 1 (SIGHUP), ..., index 30 = signal 31 (SIGUSR2).
    signal_handlers: [31]u64,

    /// Alternate signal stack base address (0 = not set, use user RSP).
    sigaltstack_base: u64,

    /// Alternate signal stack size.
    sigaltstack_size: u64,

    /// Environment variables (key=value pairs).
    env_vars: [32][128]u8,
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

/// True if `t`'s affinity allows it to run on `cpu` (-1 = no pin).
fn matchesCpu(t: *Task, cpu: u8) bool {
    return t.cpu_affinity < 0 or t.cpu_affinity == @as(i8, @intCast(cpu));
}

fn considerReady(idx: u32, cpu: u8, best_idx: *?u32, best_prio: *u8) void {
    const t = getTask(idx) orelse return;
    if (t.state == .ready and matchesCpu(t, cpu) and t.priority < best_prio.*) {
        best_prio.* = t.priority;
        best_idx.* = idx;
    }
}

/// Priority round-robin pick under one task_lock snapshot (SMP-safe).
pub fn pickReadyForCpu(cpu: u8, after_idx: ?u32) ?u32 {
    const flags = task_lock.acquire();
    defer task_lock.release(flags);

    const start = if (after_idx) |a| (a + 1) % MAX_TASKS else 0;
    var best_idx: ?u32 = null;
    var best_prio: u8 = 255;

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
        considerReady(idx, cpu, &best_idx, &best_prio);
        if (best_prio == 0) break;
    }

    if (best_idx == null and start > 0) {
        const wrap_mask: u64 = if (start >= 64) 0 else (~@as(u64, 0)) >> @intCast(64 - start);
        var bits = slot_bitmap & wrap_mask;
        while (bits != 0) {
            const idx: u32 = @intCast(@ctz(bits));
            bits &= bits - 1;
            considerReady(idx, cpu, &best_idx, &best_prio);
            if (best_prio == 0) break;
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
        if (t.state == .ready and !t.is_user and matchesCpu(t, cpu)) return i;
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
/// slot, avoiding HHDM huge-page remapping while keeping task creation O(pages).
fn allocKernelStackForSlot(slot: u32) ?u64 {
    const stack_virt = stackVirtForSlot(slot);
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
    return stack_virt;
}

/// Free a kernel stack allocated by allocKernelStack.
fn freeKernelStack(stack_virt: u64) void {
    for (0..KERNEL_STACK_PAGES) |i| {
        const page_virt = stack_virt + @as(u64, i) * PAGE_SIZE;
        if (paging.unmapPage(paging.getKernelPml4(), page_virt)) |phys| {
            pmm.freePage(phys);
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
    const ncpus = @as(u32, @truncate(smp.cpu_count));
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
    tasks[slot].fd_table = @import("../fs/vfs.zig").FdTable.init();
    tasks[slot].cwd[0] = '/';
    tasks[slot].cwd_len = 1;
    tasks[slot].cpu_affinity = @intCast(affinity);
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
    tasks[slot].fd_table = @import("../fs/vfs.zig").FdTable.init();
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
                asm volatile ("sti" ::: .{ .memory = true });
                while (true) {
                    asm volatile ("hlt");
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
    asm volatile ("sti" ::: .{ .memory = true });
    while (true) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
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
        tasks[slot].state = .ready;
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
        tasks[slot].fd_table = @import("../fs/vfs.zig").FdTable.init();
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
    const max_cpus: u8 = @intCast(@import("../arch/x86_64/syscall_entry.zig").MAX_CPUS);
    var cpus: [4]u8 = undefined;
    var cpu_count: u8 = 0;
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
            if (!seen and cpu_count < max_cpus) {
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
pub fn kickRemoteForTask(slot: u32) void {
    const t = getTask(slot) orelse return;
    const sched = @import("sched.zig");
    const se = @import("../arch/x86_64/syscall_entry.zig");
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
    const flags = task_lock.acquire();
    defer task_lock.release(flags);

    const parent = getTask(parent_idx) orelse return null;
    const parent_tid_val = parent.tid;

    // Search for a matching zombie child using bitmap
    var bits = slot_bitmap;
    while (bits != 0) {
        const i: u32 = @intCast(@ctz(bits));
        bits &= bits - 1;
        const t = &tasks[i];
        if (t.parent_tid != parent_tid_val) continue;
        if (t.state != .zombie) continue;
        if (pid > 0 and t.tid != @as(u32, @intCast(pid))) continue;

        // Found a zombie child — collect its exit code and reap it
        status.* = t.exit_code;
        const child_tid = t.tid;
        if (t.page_table_phys != 0) {
            @import("../mm/user_space.zig").destroyUserSpace(t.page_table_phys);
        }
        freeKernelStack(t.kernel_stack);
        slot_bitmap &= ~(@as(u64, 1) << @intCast(i));
        task_count -= 1;
        return child_tid;
    }
    return null;
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
