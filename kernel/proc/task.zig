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
};

pub const MAX_TASKS: u32 = 64;

var tasks: [MAX_TASKS]?Task = [_]?Task{null} ** MAX_TASKS;
var next_tid: u32 = 1;
var task_count: u32 = 0;

/// Find a free task slot.
fn allocSlot() ?u32 {
    for (0..MAX_TASKS) |i| {
        if (tasks[i] == null) return @intCast(i);
    }
    return null;
}

/// Allocate a virtually-contiguous kernel stack.
/// Allocate a virtually-contiguous kernel stack.
/// Maps KERNEL_STACK_PAGES physical pages into the kernel address space
/// at a contiguous virtual range using the kernel PML4.
fn allocKernelStack() ?u64 {
    // Allocate first page — use its HHDM address as the base.
    const phys0 = pmm.allocPage() orelse return null;
    const virt0 = hhdm.physToVirt(phys0);

    if (KERNEL_STACK_PAGES <= 1) {
        return virt0;
    }

    // For multi-page stacks, map additional pages contiguously after virt0.
    // phys0 is already mapped via HHDM at virt0, but we need phys1..physN
    // mapped at virt0+PAGE_SIZE..virt0+(N-1)*PAGE_SIZE.
    // Note: these virtual addresses may not have HHDM mappings for those
    // specific physical pages, so we must explicitly map them in the kernel PML4.
    const kernel_pml4 = paging.getKernelPml4();
    const flags = paging.MapFlags{
        .writable = true,
        .user = false,
        .no_execute = true,
        .global = true,
    };

    // Allocate and map remaining pages
    var phys_pages: [KERNEL_STACK_PAGES]?u64 = [_]?u64{null} ** KERNEL_STACK_PAGES;
    phys_pages[0] = phys0;

    var i: u64 = 1;
    while (i < KERNEL_STACK_PAGES) : (i += 1) {
        const phys = pmm.allocPage() orelse {
            // Cleanup: free all allocated pages
            for (0..i) |j| {
                if (phys_pages[j]) |p| pmm.freePage(p);
            }
            // Unmap already-mapped pages from kernel PML4
            for (1..i) |j| {
                paging.unmapPage(kernel_pml4, virt0 + j * PAGE_SIZE);
            }
            return null;
        };
        phys_pages[i] = phys;
        paging.mapPage(kernel_pml4, virt0 + i * PAGE_SIZE, phys, flags) catch {
            pmm.freePage(phys);
            // Cleanup
            for (0..i) |j| {
                if (phys_pages[j]) |p| pmm.freePage(p);
            }
            for (1..i) |j| {
                paging.unmapPage(kernel_pml4, virt0 + j * PAGE_SIZE);
            }
            return null;
        };
    }

    return virt0;
}

/// Free a kernel stack allocated by allocKernelStack.
fn freeKernelStack(stack_virt: u64) void {
    // For KERNEL_STACK_PAGES=1, the stack is a single HHDM-mapped page.
    // For multi-page stacks, page 0 is HHDM-mapped and pages 1+ are
    // explicitly mapped in the kernel PML4. We track physical pages
    // by walking the page table for pages 1+.
    const kernel_pml4 = paging.getKernelPml4();
    const pml4: [*]u64 = @ptrFromInt(hhdm.physToVirt(kernel_pml4));

    for (0..KERNEL_STACK_PAGES) |i| {
        const v = stack_virt + i * PAGE_SIZE;
        if (i == 0) {
            // Page 0 is HHDM-mapped — use direct conversion
            const phys = hhdm.virtToPhys(v);
            pmm.freePage(phys);
        } else {
            // Pages 1+ were explicitly mapped via mapPage.
            // Walk page table to find the physical address.
            const pml4_idx = (v >> 39) & 0x1FF;
            if (pml4[pml4_idx] & 1 == 0) continue;
            const pdpt: [*]u64 = @ptrFromInt(hhdm.physToVirt(pml4[pml4_idx] & 0x000FFFFFFFFFF000));
            const pdpt_idx = (v >> 30) & 0x1FF;
            if (pdpt[pdpt_idx] & 1 == 0) continue;
            const pd: [*]u64 = @ptrFromInt(hhdm.physToVirt(pdpt[pdpt_idx] & 0x000FFFFFFFFFF000));
            const pd_idx = (v >> 21) & 0x1FF;
            if (pd[pd_idx] & 1 == 0) continue;
            const pt: [*]u64 = @ptrFromInt(hhdm.physToVirt(pd[pd_idx] & 0x000FFFFFFFFFF000));
            const pt_idx = (v >> 12) & 0x1FF;
            if (pt[pt_idx] & 1 == 0) continue;
            const phys = pt[pt_idx] & 0x000FFFFFFFFFF000;
            pmm.freePage(phys);
            pt[pt_idx] = 0; // unmap
        }
    }
}

const paging = @import("../arch/x86_64/paging.zig");

/// Create a kernel thread. Returns the task index or null on failure.
/// The new task starts in .ready state with the given priority (0 = highest).
pub fn createKernelThread(entry: TaskFunc, priority: u8) ?u32 {
    const slot = allocSlot() orelse {
        serial.writeString("[task] no free task slots\n");
        return null;
    };

    // Allocate kernel stack pages
    const stack_virt = allocKernelStack() orelse {
        serial.writeString("[task] OOM allocating kernel stack\n");
        return null;
    };
    const stack_top = stack_virt + KERNEL_STACK_PAGES * PAGE_SIZE;

    const tid = next_tid;
    next_tid += 1;

    tasks[slot] = Task{
        .tid = tid,
        .state = .ready,
        .priority = priority,
        .kernel_stack = stack_virt,
        .kernel_stack_top = stack_top,
        .saved_rsp = 0,
        .entry = entry,
        .started = false,
        .exit_code = 0,
        .page_table_phys = 0,
        .personality = .native,
        .is_user = false,
        .user_entry = 0,
        .user_stack_top = 0,
        .parent_tid = 0,
        .waiting_for_child = false,
        .brk_current = 0,
        .fd_table = @import("../fs/vfs.zig").FdTable.init(),
.pending_signals = 0,
.signal_mask = 0,
.signal_handlers = @splat(0),
.sigaltstack_base = 0,
.sigaltstack_size = 0,
.env_vars = @splat(@splat(0)),
.env_count = 0,
.cwd = @splat(0),
.cwd_len = 0,
    };

    tasks[slot].?.cwd[0] = '/';
    tasks[slot].?.cwd_len = 1;

    task_count += 1;
    return slot;
}

/// Get task by index. Returns null if slot is empty or out of range.
pub fn getTask(idx: u32) ?*Task {
    if (idx >= MAX_TASKS) return null;
    if (tasks[idx] == null) return null;
    return &tasks[idx].?;
}

/// Mark the current task as exiting (zombie). Called from the task itself.
/// The scheduler will skip zombie tasks. Use reapZombies() to free resources.
/// If the parent is waiting (waitpid), unblock it so it can collect the exit code.
pub fn exitTask(exit_code: i32) void {
    const sched = @import("sched.zig");
    const idx = sched.currentTaskIndex() orelse return;
    const t = getTask(idx) orelse return;
    t.exit_code = exit_code;
    t.state = .zombie;

    // If parent is waiting for a child, unblock it
    if (t.parent_tid != 0) {
        if (findTaskByTid(t.parent_tid)) |parent_idx| {
            const parent = getTask(parent_idx) orelse return;
            if (parent.waiting_for_child) {
                parent.waiting_for_child = false;
                parent.state = .ready;
            }
        }
    }

    asm volatile ("sti");
    while (true) {
        asm volatile ("hlt");
    }
}

/// Reap orphaned zombie tasks — those whose parent has already exited.
/// Zombies with a living parent are left for waitpid() to collect.
pub fn reapZombies() u32 {
    var reaped: u32 = 0;
    for (0..MAX_TASKS) |i| {
        if (tasks[i]) |*t| {
            if (t.state != .zombie) continue;

            // Check if parent is still alive
            if (t.parent_tid != 0) {
                if (findTaskByTid(t.parent_tid) != null) {
                    // Parent still alive — leave for waitpid
                    continue;
                }
                // Parent gone — orphan, reap it
            }

            if (t.page_table_phys != 0) {
                @import("../mm/user_space.zig").destroyUserSpace(t.page_table_phys);
            }
            freeKernelStack(t.kernel_stack);
            tasks[i] = null;
            task_count -= 1;
            reaped += 1;
        }
    }
    return reaped;
}

/// Find a task by its TID. Returns the task slot index or null.
pub fn findTaskByTid(tid: u32) ?u32 {
    for (0..MAX_TASKS) |i| {
        if (tasks[i]) |t| {
            if (t.tid == tid and t.state != .zombie) return @intCast(i);
        }
    }
    return null;
}

/// Block a task — sets state to blocked. The scheduler will skip it.
pub fn blockTask(idx: u32) void {
    const t = getTask(idx) orelse return;
    if (t.state == .running) {
        t.state = .blocked;
    }
}

/// Unblock a task — sets state back to ready.
pub fn unblockTask(idx: u32) void {
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
    const slot = allocSlot() orelse {
        serial.writeString("[task] no free task slots\n");
        return null;
    };

    // Allocate kernel stack
    const stack_virt = allocKernelStack() orelse {
        serial.writeString("[task] OOM allocating kernel stack\n");
        return null;
    };
    const stack_top = stack_virt + KERNEL_STACK_PAGES * PAGE_SIZE;

    const tid = next_tid;
    next_tid += 1;

    tasks[slot] = Task{
        .tid = tid,
        .state = .ready,
        .priority = 1,
        .kernel_stack = stack_virt,
        .kernel_stack_top = stack_top,
        .saved_rsp = 0,
        .entry = null,
        .started = false,
        .exit_code = 0,
        .page_table_phys = page_table_phys,
        .personality = .native,
        .is_user = true,
        .user_entry = user_entry,
        .user_stack_top = user_stack_top,
        .parent_tid = parent_tid_val,
        .waiting_for_child = false,
        .brk_current = 0,
        .fd_table = @import("../fs/vfs.zig").FdTable.init(),
.pending_signals = 0,
.signal_mask = 0,
.signal_handlers = @splat(0),
.sigaltstack_base = 0,
.sigaltstack_size = 0,
.env_vars = @splat(@splat(0)),
.env_count = 0,
.cwd = @splat(0),
.cwd_len = 0,
    };

    tasks[slot].?.cwd[0] = '/';
    tasks[slot].?.cwd_len = 1;

    const sig_mod = @import("signal.zig");
    sig_mod.setupSigreturnTrampoline(page_table_phys);

    task_count += 1;
    return slot;
}

/// Wait for a child process to exit. Returns the child's TID, or 0 if no
/// child has exited yet (WNOHANG behavior). Writes the exit code to *status.
/// pid == -1 means wait for any child; pid > 0 means wait for specific child.
pub fn waitpid(parent_idx: u32, pid: i32, status: *i32) ?u32 {
    const parent = getTask(parent_idx) orelse return null;
    const parent_tid_val = parent.tid;

    // Search for a matching zombie child
    for (0..MAX_TASKS) |i| {
        if (tasks[i]) |*t| {
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
            tasks[i] = null;
            task_count -= 1;
            return child_tid;
        }
    }
    return null;
}

/// Check if the given task has any children (for waitpid validation).
pub fn hasChildren(parent_idx: u32) bool {
    const parent = getTask(parent_idx) orelse return false;
    const parent_tid_val = parent.tid;
    for (0..MAX_TASKS) |i| {
        if (tasks[i]) |t| {
            if (t.parent_tid == parent_tid_val) return true;
        }
    }
    return false;
}
