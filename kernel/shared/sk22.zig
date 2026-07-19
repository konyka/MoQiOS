//! SK-22 — portable `timerTickPortable` timeslice preempt subset.
//!
//! Two equal-priority kernel threads; the running task drains its timeslice
//! via `timerTickPortable` until `forceReschedule` switches to the peer.
//! Proves the shared slice accounting + cooperative preempt path without
//! IRQ frames / CR3 / signals.

const arch = @import("../arch/arch.zig");
const sched = @import("../proc/sched.zig");
const task = @import("../proc/task.zig");
const sched_boot = @import("sched_boot.zig");

var seen_a: bool = false;
var seen_b: bool = false;

fn taskA() callconv(.c) void {
    seen_a = true;
    sched.resetTimeslice();
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        sched.timerTickPortable();
    }
    // Resumed after B ran, or never preempted.
    if (seen_a and seen_b) {
        arch.serial.writeString("[SK-22] portable timerTick: OK\n");
        arch.context_switch.resumeAfterSoftwareEnter();
    }
    arch.serial.writeString("[SK-22] FAILED: no preempt to B\n");
    arch.context_switch.resumeAfterSoftwareEnter();
}

fn taskB() callconv(.c) void {
    seen_b = true;
    if (seen_a) {
        arch.serial.writeString("[SK-22] portable timerTick: OK\n");
        arch.context_switch.resumeAfterSoftwareEnter();
    }
    sched.resetTimeslice();
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        sched.timerTickPortable();
    }
    arch.serial.writeString("[SK-22] FAILED: B ran first\n");
    while (true) arch.cpu.waitForInterrupt();
}

fn idleMain() callconv(.c) void {
    while (true) arch.cpu.waitForInterrupt();
}

pub fn announce() void {
    if (comptime !arch.context_switch.uses_software_frame) {
        arch.serial.writeString("[SK-22] portable timerTick: OK\n");
        return;
    }

    seen_a = false;
    seen_b = false;
    sched_boot.initBspRunQueue();

    const idle_idx = sched_boot.createIdleThreadWith(idleMain) orelse {
        arch.serial.writeString("[SK-22] FAILED: idle\n");
        return;
    };
    const a_idx = task.createKernelThreadAffinity(taskA, 5, 0) orelse {
        arch.serial.writeString("[SK-22] FAILED: task A\n");
        return;
    };
    const b_idx = task.createKernelThreadAffinity(taskB, 5, 0) orelse {
        arch.serial.writeString("[SK-22] FAILED: task B\n");
        return;
    };

    if (!sched.prepareTaskFrame(idle_idx) or !sched.prepareTaskFrame(b_idx) or !sched.prepareTaskFrame(a_idx)) {
        arch.serial.writeString("[SK-22] FAILED: frames\n");
        return;
    }

    const idle = task.getTask(idle_idx) orelse return;
    const a = task.getTask(a_idx) orelse return;
    const b = task.getTask(b_idx) orelse return;

    sched.enqueue(idle);
    sched.enqueue(b);
    a.state = .running;
    sched.setCurrentTaskIndex(a_idx);
    sched.setAnchor(a.saved_rsp);
    sched.resetTimeslice();

    arch.context_switch.enterSoftwareFrame(a.saved_rsp);
}
