//! SK-17 — shared `proc/sched` queue + priority pick (main.zig bootstrap slice).
//!
//! Aligns with `main.zig`'s early scheduler wiring: `per_cpu.init(0)` then
//! create ready tasks and `sched.enqueue`. Verifies the per-CPU LIFO queue and
//! the legacy priority bitmap pick — without calling `timerTick`.

const arch = @import("../arch/arch.zig");
const sched = @import("../proc/sched.zig");
const task = @import("../proc/task.zig");
const per_cpu = @import("../proc/per_cpu.zig");

fn stubPark() callconv(.c) void {
    while (true) arch.cpu.waitForInterrupt();
}

pub fn announce() void {
    // Same order as main.zig: prime BSP run queue before enqueue paths matter.
    per_cpu.init(0);
    if (!per_cpu.isAnyReady()) {
        arch.serial.writeString("[SK-17] FAILED: per_cpu not ready\n");
        return;
    }

    const idx_hi = task.createKernelThreadAffinity(stubPark, 5, 0) orelse {
        arch.serial.writeString("[SK-17] FAILED: create hi\n");
        return;
    };
    const idx_lo = task.createKernelThreadAffinity(stubPark, 40, 0) orelse {
        arch.serial.writeString("[SK-17] FAILED: create lo\n");
        return;
    };
    const t_hi = task.getTask(idx_hi) orelse return;
    const t_lo = task.getTask(idx_lo) orelse return;

    sched.enqueue(t_hi);
    sched.enqueue(t_lo);

    const q = per_cpu.getCurrent();
    if (q.nr_running < 2) {
        arch.serial.writeString("[SK-17] FAILED: queue depth\n");
        return;
    }

    // Local queue is FIFO — first enqueued (hi) pops first.
    const popped_hi = q.pop() orelse {
        arch.serial.writeString("[SK-17] FAILED: pop empty\n");
        return;
    };
    if (popped_hi.self_idx != idx_hi) {
        arch.serial.writeString("[SK-17] FAILED: FIFO order\n");
        return;
    }
    const popped_lo = q.pop() orelse {
        arch.serial.writeString("[SK-17] FAILED: second pop\n");
        return;
    };
    if (popped_lo.self_idx != idx_lo) {
        arch.serial.writeString("[SK-17] FAILED: FIFO second\n");
        return;
    }

    // Bitmap priority pick (lower priority number wins) — same fallback as pickNext.
    const picked = task.pickReadyForCpu(0, null) orelse {
        arch.serial.writeString("[SK-17] FAILED: pickReady\n");
        return;
    };
    if (picked != idx_hi) {
        arch.serial.writeString("[SK-17] FAILED: priority pick\n");
        return;
    }

    arch.serial.writeString("[SK-17] shared sched queue+pick: OK\n");
}
