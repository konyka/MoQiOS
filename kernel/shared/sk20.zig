//! SK-20 — portable cooperative `sleepOn` switch via software InterruptFrames.
//!
//! Waiter parks with `blockOn`, installs a resume entry frame, then
//! `forceReschedule` switches to the waker. Waker `wakeOne`s and switches
//! back into the resume entry (`granted=true`).

const arch = @import("../arch/arch.zig");
const sched = @import("../proc/sched.zig");
const task = @import("../proc/task.zig");
const sched_boot = @import("sched_boot.zig");

var wait_q: ?*task.WaitNode = null;
var wait_node: task.WaitNode = .{ .task_idx = 0 };

fn waiterResume() callconv(.c) void {
    if (!wait_node.granted) {
        arch.serial.writeString("[SK-20] FAILED: resume not granted\n");
        arch.context_switch.resumeAfterSoftwareEnter();
    }
    arch.serial.writeString("[SK-20] portable sleepOn switch: OK\n");
    arch.context_switch.resumeAfterSoftwareEnter();
}

fn waiterMain() callconv(.c) void {
    if (!sched.blockOn(&wait_q, &wait_node)) {
        arch.serial.writeString("[SK-20] FAILED: blockOn\n");
        arch.context_switch.resumeAfterSoftwareEnter();
    }
    // Install resume frame before switching away (blocked tasks keep saved_rsp).
    const t = sched.currentTask() orelse {
        arch.serial.writeString("[SK-20] FAILED: no current\n");
        while (true) arch.cpu.waitForInterrupt();
    };
    t.entry = waiterResume;
    t.started = false;
    if (!sched.prepareTaskFrame(t.self_idx)) {
        arch.serial.writeString("[SK-20] FAILED: resume frame\n");
        while (true) arch.cpu.waitForInterrupt();
    }
    @call(.never_inline, sched.forceReschedule, .{});
    while (true) arch.cpu.waitForInterrupt();
}

fn wakerMain() callconv(.c) void {
    var spins: u32 = 0;
    while (wait_q == null and spins < 10_000_000) : (spins += 1) {
        arch.cpu.pause();
    }
    if (wait_q == null) {
        arch.serial.writeString("[SK-20] FAILED: waiter never blocked\n");
        while (true) arch.cpu.waitForInterrupt();
    }
    _ = sched.wakeOne(&wait_q) orelse {
        arch.serial.writeString("[SK-20] FAILED: wakeOne\n");
        while (true) arch.cpu.waitForInterrupt();
    };
    @call(.never_inline, sched.forceReschedule, .{});
    while (true) arch.cpu.waitForInterrupt();
}

fn idleMain() callconv(.c) void {
    while (true) arch.cpu.waitForInterrupt();
}

pub fn announce() void {
    if (comptime !arch.context_switch.uses_software_frame) {
        arch.serial.writeString("[SK-20] portable sleepOn switch: OK\n");
        return;
    }

    sched_boot.initBspRunQueue();
    wait_q = null;
    wait_node = .{ .task_idx = 0 };

    const idle_idx = sched_boot.createIdleThread(idleMain) orelse {
        arch.serial.writeString("[SK-20] FAILED: idle\n");
        return;
    };
    const waiter_idx = task.createKernelThreadAffinity(waiterMain, 10, 0) orelse {
        arch.serial.writeString("[SK-20] FAILED: waiter\n");
        return;
    };
    const waker_idx = task.createKernelThreadAffinity(wakerMain, 5, 0) orelse {
        arch.serial.writeString("[SK-20] FAILED: waker\n");
        return;
    };

    if (!sched.prepareTaskFrame(idle_idx) or !sched.prepareTaskFrame(waker_idx) or !sched.prepareTaskFrame(waiter_idx)) {
        arch.serial.writeString("[SK-20] FAILED: prepare frames\n");
        return;
    }

    const idle = task.getTask(idle_idx) orelse return;
    const waiter = task.getTask(waiter_idx) orelse return;
    const waker = task.getTask(waker_idx) orelse return;

    sched.enqueue(idle);
    sched.enqueue(waker);
    waiter.state = .running;
    sched.setCurrentTaskIndex(waiter_idx);
    sched.setAnchor(waiter.saved_rsp);

    arch.context_switch.enterSoftwareFrame(waiter.saved_rsp);
}
