//! SK-18 — portable `sched` wake/block without `forceReschedule` / `timerTick`.
//!
//! Manually parks tasks on a wait queue (same WaitNode link order as `sleepOn`),
//! then exercises `wakeOne` (FIFO oldest) and `wakeAll`. Proves the shared
//! block/wake state machine on non-x86 without entering the x86 switch path.

const arch = @import("../arch/arch.zig");
const sched = @import("../proc/sched.zig");
const task = @import("../proc/task.zig");
const per_cpu = @import("../proc/per_cpu.zig");

fn stubPark() callconv(.c) void {
    while (true) arch.cpu.waitForInterrupt();
}

pub fn announce() void {
    per_cpu.init(0);

    const idx_a = task.createKernelThreadAffinity(stubPark, 8, 0) orelse {
        arch.serial.writeString("[SK-18] FAILED: create a\n");
        return;
    };
    const idx_b = task.createKernelThreadAffinity(stubPark, 9, 0) orelse {
        arch.serial.writeString("[SK-18] FAILED: create b\n");
        return;
    };
    const t_a = task.getTask(idx_a) orelse return;
    const t_b = task.getTask(idx_b) orelse return;

    var queue: ?*task.WaitNode = null;
    var node_a: task.WaitNode = .{ .task_idx = 0 };
    var node_b: task.WaitNode = .{ .task_idx = 0 };

    // Mirror sleepOn insert order (newest at head): enqueue A then B → B head, A oldest.
    node_a.task_idx = idx_a;
    node_a.granted = false;
    node_a.next = queue;
    queue = &node_a;
    t_a.state = .blocked;
    t_a.wait_queue = &queue;

    node_b.task_idx = idx_b;
    node_b.granted = false;
    node_b.next = queue;
    queue = &node_b;
    t_b.state = .blocked;
    t_b.wait_queue = &queue;

    // Blocked tasks must not win a ready pick.
    if (task.pickReadyForCpu(0, null)) |p| {
        if (p == idx_a or p == idx_b) {
            arch.serial.writeString("[SK-18] FAILED: blocked still pickable\n");
            return;
        }
    }

    const woken = sched.wakeOne(&queue) orelse {
        arch.serial.writeString("[SK-18] FAILED: wakeOne empty\n");
        return;
    };
    if (woken != idx_a) {
        arch.serial.writeString("[SK-18] FAILED: wakeOne not FIFO oldest\n");
        return;
    }
    if (!node_a.granted or t_a.state != .ready or t_a.wait_queue != null) {
        arch.serial.writeString("[SK-18] FAILED: wakeOne state\n");
        return;
    }
    if (queue != &node_b or t_b.state != .blocked) {
        arch.serial.writeString("[SK-18] FAILED: wakeOne leftover\n");
        return;
    }

    sched.wakeAll(&queue);
    if (queue != null or !node_b.granted or t_b.state != .ready or t_b.wait_queue != null) {
        arch.serial.writeString("[SK-18] FAILED: wakeAll state\n");
        return;
    }

    arch.serial.writeString("[SK-18] shared sched wake+block: OK\n");
}
