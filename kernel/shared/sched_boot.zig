//! Shared BSP scheduler bootstrap fragment (aligned with `main.zig`).
//!
//! Non-x86 bring-up and x86 `main.zig` both prime the BSP run queue the same
//! way before creating idle / ready tasks.

const arch = @import("../arch/arch.zig");
const per_cpu = @import("../proc/per_cpu.zig");
const sched = @import("../proc/sched.zig");
const task = @import("../proc/task.zig");

/// Initialise CPU 0's per-CPU run queue (idempotent). Same call site as main.zig.
pub fn initBspRunQueue() void {
    per_cpu.init(0);
}

/// Create the lowest-priority idle kernel thread (priority 255) on the shared
/// portable idle body (`sched.kernelIdleLoop`: enableIrq + waitForInterrupt).
/// SK-42: main.zig used to pass its own x86 `hlt` loop here — both worlds now
/// boot the exact same idle task.
pub fn createIdleThread() ?u32 {
    return task.createKernelThread(sched.kernelIdleLoop, 255);
}

/// Priority-255 idle thread with a custom body — probe-ladder milestones
/// (sk19/20/22/23/24) park on their own stubs instead of the shared loop.
pub fn createIdleThreadWith(entry: task.TaskFunc) ?u32 {
    return task.createKernelThread(entry, 255);
}

/// SK-42: portable tail of `_start` — enable IRQs and sleep between ticks so
/// the timer can schedule away from the boot context. Same body as the idle
/// task; kept separate so the boot context never needs a Task slot.
pub fn bootIdleLoop() noreturn {
    while (true) {
        arch.interrupts.enableIrq();
        arch.cpu.waitForInterrupt();
    }
}
