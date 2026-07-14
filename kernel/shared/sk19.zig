//! SK-19 — portable `sleepOn` hook + shared `main.zig` BSP sched bootstrap.
//!
//! Installs a non-switching `forceReschedule` hook so `sleepOn` can park the
//! current task on non-x86 without `timerTick`. Also exercises
//! `shared/sched_boot.zig` (same `per_cpu.init` + idle create as main.zig).

const arch = @import("../arch/arch.zig");
const sched = @import("../proc/sched.zig");
const task = @import("../proc/task.zig");
const per_cpu = @import("../proc/per_cpu.zig");
const sched_boot = @import("sched_boot.zig");

var reschedule_hits: u32 = 0;

fn portableReschedule() void {
    reschedule_hits +%= 1;
}

fn stubPark() callconv(.c) void {
    while (true) arch.cpu.waitForInterrupt();
}

pub fn announce() void {
    sched_boot.initBspRunQueue();
    if (!per_cpu.isAnyReady()) {
        arch.serial.writeString("[SK-19] FAILED: bsp queue\n");
        return;
    }

    const idle_idx = sched_boot.createIdleThread(stubPark) orelse {
        arch.serial.writeString("[SK-19] FAILED: idle\n");
        return;
    };
    const idle = task.getTask(idle_idx) orelse return;
    if (idle.priority != 255) {
        arch.serial.writeString("[SK-19] FAILED: idle priority\n");
        return;
    }

    const waiter_idx = task.createKernelThreadAffinity(stubPark, 10, 0) orelse {
        arch.serial.writeString("[SK-19] FAILED: waiter\n");
        return;
    };
    const waiter = task.getTask(waiter_idx) orelse return;

    sched.setPortableReschedule(portableReschedule);
    defer sched.setPortableReschedule(null);

    sched.setCurrentTaskIndex(waiter_idx);
    defer sched.setCurrentTaskIndex(null);

    var queue: ?*task.WaitNode = null;
    var node: task.WaitNode = .{ .task_idx = 0 };

    // Hook is non-switching: sleepOn returns immediately with granted=false.
    const granted = sched.sleepOn(&queue, &node);
    if (granted or reschedule_hits != 1) {
        arch.serial.writeString("[SK-19] FAILED: sleepOn/hook\n");
        return;
    }
    if (waiter.state != .blocked or queue != &node or node.granted) {
        arch.serial.writeString("[SK-19] FAILED: blocked state\n");
        return;
    }

    // Clear "current" so wake path looks like a remote waker.
    sched.setCurrentTaskIndex(null);

    const woken = sched.wakeOne(&queue) orelse {
        arch.serial.writeString("[SK-19] FAILED: wakeOne\n");
        return;
    };
    if (woken != waiter_idx or !node.granted or waiter.state != .ready) {
        arch.serial.writeString("[SK-19] FAILED: wake after sleepOn\n");
        return;
    }

    arch.serial.writeString("[SK-19] shared sleepOn+sched_boot: OK\n");
}
