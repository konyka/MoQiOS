//! The kernel's sleeping lock: SleepLock over the task scheduler, using the
//! same blockOn / wakeOne / rescheduleAfterBlock sequence as the pipe readers
//! (oldest waiter is woken first).

const sleep_lock = @import("sleep_lock.zig");
const IrqSpinlock = @import("irq_spinlock.zig").IrqSpinlock;
const arch = @import("../arch/arch.zig");
const sched = @import("../proc/sched.zig");
const task = @import("../proc/task.zig");

const Env = struct {
    pub const Guard = IrqSpinlock;
    pub const Node = task.WaitNode;
    pub fn newNode() Node {
        return .{ .task_idx = 0 };
    }
    pub fn currentTask() ?u32 {
        return sched.currentTaskIndex();
    }
    pub fn enqueue(queue: *?*Node, node: *Node) bool {
        return sched.blockOn(queue, node);
    }
    pub fn wakeOne(queue: *?*Node) ?u32 {
        return sched.wakeOne(queue);
    }
    pub fn sleepAfterBlock() void {
        sched.rescheduleAfterBlock();
    }
    pub fn relax() void {
        arch.cpu.pause();
    }
};

pub const SleepLock = sleep_lock.SleepLock(Env);
