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
const serial = @import("../arch/x86_64/serial.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

const PAGE_SIZE: u64 = 4096;
const KERNEL_STACK_PAGES: u64 = 16;
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
    state: TaskState,
    priority: u8,
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
    /// Stack limit (lowest address the stack may grow to). Auto-extended on page fault.
    stack_limit: u64,
    /// TID of the parent process (0 if spawned by kernel). Used by waitpid.
    parent_tid: u32,
    /// Whether this task is waiting for a child to exit (for blocking waitpid).
    waiting_for_child: bool,
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
    wait_queue: ?*WaitNode,

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
};

/// Tracked mmap region for munmap support.
pub const MmapRegion = struct {
    base: u64 = 0,
    num_pages: u64 = 0,
    /// 0 = free slot
    active: bool = false,
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

/// Find a free task slot using bitmap fast-path.
fn allocSlot() ?u32 {
    const free_bits = ~slot_bitmap;
    if (free_bits == 0) return null;
    const slot = @ctz(free_bits);
    if (slot >= MAX_TASKS) return null;
    return @intCast(slot);
}

/// Allocate a virtually-contiguous kernel stack.
/// Allocate a virtually-contiguous kernel stack.
/// Maps KERNEL_STACK_PAGES physical pages into the kernel address space
/// at a contiguous virtual range using the kernel PML4.
fn allocKernelStack() ?u64 {
    // Allocate KERNEL_STACK_PAGES physically-contiguous pages and return the
    // HHDM virtual address of the run's base.
    //
    // The HHDM is a linear physical->virtual map set up by Limine, so a
    // contiguous physical run is automatically contiguous (and already mapped)
    // in the HHDM window. We therefore do NOT touch the page tables at all.
    //
    // (The previous implementation tried to remap individual HHDM pages with
    // mapPage(). That corrupted kernel memory: Limine maps the HHDM with huge
    // pages, and mapPage()/ensureTable() cannot descend into a huge-page
    // entry, so the "new" PTEs were written into the middle of huge-page data
    // frames — eventually causing a #PF during early boot.)
    const phys_base = pmm.allocContiguous(KERNEL_STACK_PAGES) orelse return null;
    return hhdm.physToVirt(phys_base);
}

/// Free a kernel stack allocated by allocKernelStack.
fn freeKernelStack(stack_virt: u64) void {
    // The stack is a contiguous physical run mapped through the HHDM, so each
    // page's physical address is a simple HHDM reverse-translation.
    const phys_base = hhdm.virtToPhys(stack_virt);
    for (0..KERNEL_STACK_PAGES) |i| {
        pmm.freePage(phys_base + i * PAGE_SIZE);
    }
}

/// Create a kernel thread. Returns the task index or null on failure.
/// The new task starts in .ready state with the given priority (0 = highest).
pub fn createKernelThread(entry: TaskFunc, priority: u8) ?u32 {
    const flags = task_lock.acquire();
    defer task_lock.release(flags);

    const slot = allocSlot() orelse {
        serial.writeString("[task] no free task slots\n");
        return null;
    };

    // Allocate kernel stack pages (PMM has its own lock)
    const stack_virt = allocKernelStack() orelse {
        serial.writeString("[task] OOM allocating kernel stack\n");
        return null;
    };
    const stack_top = stack_virt + KERNEL_STACK_PAGES * PAGE_SIZE;

    const tid = next_tid;
    next_tid += 1;

    // Build the (large) Task in place in its slot: zero it byte-wise and then
    // set only the non-default fields, so no multi-KB Task value is ever
    // materialised on the kernel stack.
    zeroSlot(slot);
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

    slot_bitmap |= @as(u64, 1) << @intCast(slot);
    task_count += 1;
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
                asm volatile ("" ::: .{ .memory = true });
                parent.state = .ready;
            }
        }
    }
    task_lock.release(flags);

    asm volatile ("sti" ::: .{ .memory = true });
    while (true) {
        asm volatile ("hlt");
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
) ?u32 {
    const flags = task_lock.acquire();
    defer task_lock.release(flags);

    const slot = allocSlot() orelse {
        serial.writeString("[task] no free task slots\n");
        return null;
    };

    // Allocate kernel stack (PMM has its own lock)
    const stack_virt = allocKernelStack() orelse {
        serial.writeString("[task] OOM allocating kernel stack\n");
        return null;
    };
    const stack_top = stack_virt + KERNEL_STACK_PAGES * PAGE_SIZE;

    const tid = next_tid;
    next_tid += 1;

    // Build the (large) Task in place in its slot (see the note on
    // createKernelThread) to avoid overflowing the kernel stack.
    zeroSlot(slot);
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
    tasks[slot].stack_limit = user_stack_top - 64 * 4096; // 64 pages below stack top
    tasks[slot].parent_tid = parent_tid_val;
    tasks[slot].fd_table = @import("../fs/vfs.zig").FdTable.init();
    tasks[slot].cwd[0] = '/';
    tasks[slot].cwd_len = 1;

    const sig_mod = @import("signal.zig");
    sig_mod.setupSigreturnTrampoline(page_table_phys);

    slot_bitmap |= @as(u64, 1) << @intCast(slot);
    task_count += 1;
    return slot;
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
