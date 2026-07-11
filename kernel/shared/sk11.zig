//! SK-11 — paging/syscall facade gaps filled so sched/task/per_cpu link.
//!
//! Non-x86 backends expose PerCpu (anchor @ offset 16), MapFlags,
//! getKernelPml4, and Personality.native so the shared scheduler subset
//! type-checks without pulling Limine `main`.

const arch = @import("../arch/arch.zig");
const sched = @import("../proc/sched.zig");
const task = @import("../proc/task.zig");
const per_cpu = @import("../proc/per_cpu.zig");

pub fn announce() void {
    _ = arch.syscall.PERCPU_ANCHOR_OFFSET;
    _ = arch.paging.getKernelPml4();
    _ = arch.syscall.getPerCpuOrNull();
    _ = sched.TIMESLICE_TICKS_PUB;
    _ = @intFromEnum(arch.syscall.Personality.native);
    _ = task;
    _ = per_cpu.MAX_CPUS;

    arch.serial.writeString("[SK-11] sched/task via paging+syscall facade: OK\n");
}
