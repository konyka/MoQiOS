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

const TIMESLICE_TICKS: u64 = 10;

pub var saved_stack_anchor: u64 = 0;

var current_idx: ?u32 = null;
var slice_remaining: u64 = TIMESLICE_TICKS;
var reap_counter: u64 = 0;
const REAP_INTERVAL: u64 = TIMESLICE_TICKS;

pub fn currentTaskIndex() ?u32 {
    return current_idx;
}

pub fn currentTask() ?*task.Task {
    const idx = current_idx orelse return null;
    return task.getTask(idx);
}

/// Called from timer IRQ handler on every tick.
pub fn timerTick(frame: *idt.InterruptFrame) void {
    _ = frame;

    reap_counter +|= 1;
    if (reap_counter >= REAP_INTERVAL) {
        reap_counter = 0;
        _ = task.reapZombies();
    }

    const count = task.getTaskCount();
    if (count <= 1) return;

    slice_remaining -|= 1;
    if (slice_remaining > 0) return;
    slice_remaining = TIMESLICE_TICKS;

    const next_idx = pickNext() orelse {
        return;
    };

    // First ever schedule
    if (current_idx == null) {
        const t = task.getTask(next_idx) orelse return;
        if (!t.started) {
            setupInitialFrame(t);
        }
        saved_stack_anchor = t.saved_rsp;
        t.state = .running;
        current_idx = next_idx;

        // Set up CPU state for the first scheduled task
        if (t.page_table_phys != 0) {
            asm volatile ("movq %[cr3], %%rax\n\tmovq %%rax, %%cr3"
                :
                : [cr3] "r" (t.page_table_phys),
                : .{ .rax = true, .memory = true });
            gdt.setRsp0(t.kernel_stack_top);
            syscall_entry.getPerCpu().kernel_rsp = t.kernel_stack_top;
        }
        return;
    }

    const cur_idx = current_idx.?;
    if (next_idx == cur_idx) return;

    const old_task = task.getTask(cur_idx) orelse return;
    const new_task = task.getTask(next_idx) orelse return;

    old_task.saved_rsp = saved_stack_anchor;

    if (old_task.state == .running) {
        old_task.state = .ready;
    }

    if (!new_task.started) {
        setupInitialFrame(new_task);
    }

    saved_stack_anchor = new_task.saved_rsp;
    new_task.state = .running;
    current_idx = next_idx;

    if (new_task.page_table_phys != 0) {
        if (old_task.page_table_phys != new_task.page_table_phys) {
            asm volatile ("movq %[cr3], %%rax\n\tmovq %%rax, %%cr3"
                :
                : [cr3] "r" (new_task.page_table_phys),
                : .{ .rax = true, .memory = true });
        }
        gdt.setRsp0(new_task.kernel_stack_top);
        syscall_entry.getPerCpu().kernel_rsp = new_task.kernel_stack_top;

        // Ensure KERNEL_GS_BASE points to PerCpu struct before entering user mode.
        // When a new user task is first scheduled via iretq (not SYSRETQ), the
        // swapgs state may be incorrect, causing GS_BASE=0 in kernel after swapgs.
        // Fix: explicitly set KERNEL_GS_BASE = &bsp_percpu via WRMSR.
        syscall_entry.wrmsr(0xC0000102, @intFromPtr(syscall_entry.getPerCpu()));
    } else {
        if (old_task.page_table_phys != 0) {
            const kernel_pml4 = paging.getKernelPml4();
            asm volatile ("movq %[cr3], %%rax\n\tmovq %%rax, %%cr3"
                :
                : [cr3] "r" (kernel_pml4),
                : .{ .rax = true, .memory = true });
        }
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

/// Pick the next ready task — priority-aware round-robin.
/// Finds the highest priority (lowest number) among ready tasks.
/// Among equal priority, uses round-robin (start after current).
fn pickNext() ?u32 {
    const start = if (current_idx) |ci| (ci + 1) % task.MAX_TASKS else 0;

    var best_idx: ?u32 = null;
    var best_prio: u8 = 255;

    // Scan all task slots, starting after current for round-robin fairness
    var scan_pos: u32 = start;
    var count: u32 = 0;
    while (count < task.MAX_TASKS) : (count += 1) {
        const t = task.getTask(scan_pos) orelse {
            scan_pos = (scan_pos + 1) % task.MAX_TASKS;
            continue;
        };
        if (t.state == .ready and t.priority < best_prio) {
            best_prio = t.priority;
            best_idx = scan_pos;
        }
        scan_pos = (scan_pos + 1) % task.MAX_TASKS;
    }

    return best_idx;
}
