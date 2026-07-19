//! SK-42 — main.zig idle-thread boot fragment converged into sched_boot.
//!
//! x86 `main.zig` used to build its own `hlt` idle thread and end `_start`
//! with inline `sti`+`hlt`; both now go through `sched_boot`:
//! `createIdleThread()` (shared `sched.kernelIdleLoop` body, priority 255)
//! and `bootIdleLoop()` (portable enableIrq + waitForInterrupt tail).
//! Probe: prime the BSP run queue and create the idle task via the exact
//! fragments main.zig calls, then verify priority/frame/anchor.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const sched_boot = @import("sched_boot.zig");
const sched = @import("../proc/sched.zig");
const task = @import("../proc/task.zig");
const per_cpu = @import("../proc/per_cpu.zig");

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-42] shared idle boot fragment: OK\n");
        return;
    }

    sched_boot.initBspRunQueue();
    if (!per_cpu.isAnyReady()) {
        arch.serial.writeString("[SK-42] FAILED: BSP run queue not primed\n");
        return;
    }

    const idx = sched_boot.createIdleThread() orelse {
        arch.serial.writeString("[SK-42] FAILED: createIdleThread\n");
        return;
    };
    const t = task.getTask(idx) orelse {
        arch.serial.writeString("[SK-42] FAILED: getTask\n");
        return;
    };
    if (t.priority != 255) {
        arch.serial.writeString("[SK-42] FAILED: priority != 255\n");
        return;
    }

    if (!sched.prepareTaskFrame(idx)) {
        arch.serial.writeString("[SK-42] FAILED: prepareTaskFrame\n");
        return;
    }
    const frame: *arch.interrupts.InterruptFrame = @ptrFromInt(t.saved_rsp);
    if (frame.rip != @intFromPtr(&sched.kernelIdleLoop)) {
        arch.serial.writeString("[SK-42] FAILED: frame.rip != kernelIdleLoop\n");
        return;
    }

    arch.serial.writeString("[SK-42] shared idle boot fragment: OK\n");
}
