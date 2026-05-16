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
const KERNEL_STACK_PAGES: u64 = 1; // 4KB — keep small, use small buffers in syscall handlers
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
/// Maps KERNEL_STACK_PAGES physical pages into the kernel address space
/// at a contiguous virtual range.
fn allocKernelStack() ?u64 {
    // For now, use HHDM mapping of a single page (KERNEL_STACK_PAGES must be 1-2).
    // For larger stacks, we'd need a proper VM allocator.
    // With 2 pages: allocate 2 phys pages and map them contiguously.
    const phys0 = pmm.allocPage() orelse return null;
    if (KERNEL_STACK_PAGES <= 1) {
        return hhdm.physToVirt(phys0);
    }
    const phys1 = pmm.allocPage() orelse {
        pmm.freePage(phys0);
        return null;
    };

    // Map both pages contiguously using the HHDM virtual address of the first page.
    // This works because we map phys1 at virt0 + PAGE_SIZE in the kernel page table.
    const virt0 = hhdm.physToVirt(phys0);
    const kernel_pml4 = paging.getKernelPml4();
    const flags = paging.MapFlags{
        .writable = true,
        .user = false,
        .no_execute = true,
        .global = true,
    };
    paging.mapPage(kernel_pml4, virt0 + PAGE_SIZE, phys1, flags) catch {
        pmm.freePage(phys1);
        pmm.freePage(phys0);
        return null;
    };
    return virt0;
}

/// Free a kernel stack allocated by allocKernelStack.
fn freeKernelStack(stack_virt: u64) void {
    // For KERNEL_STACK_PAGES=1, the stack is a single HHDM-mapped page.
    // Reverse the HHDM mapping to get the physical address directly.
    // This avoids walking page tables (which may use huge pages from Limine).
    for (0..KERNEL_STACK_PAGES) |i| {
        const v = stack_virt + i * PAGE_SIZE;
        const phys = hhdm.virtToPhys(v);
        pmm.freePage(phys);
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
    };

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
    };

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
