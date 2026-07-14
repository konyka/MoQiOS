//! Shared BSP scheduler bootstrap fragment (aligned with `main.zig`).
//!
//! Non-x86 bring-up and x86 `main.zig` both prime the BSP run queue the same
//! way before creating idle / ready tasks.

const per_cpu = @import("../proc/per_cpu.zig");
const task = @import("../proc/task.zig");

/// Initialise CPU 0's per-CPU run queue (idempotent). Same call site as main.zig.
pub fn initBspRunQueue() void {
    per_cpu.init(0);
}

/// Create the lowest-priority idle kernel thread (priority 255), matching main.zig.
pub fn createIdleThread(entry: task.TaskFunc) ?u32 {
    return task.createKernelThread(entry, 255);
}
