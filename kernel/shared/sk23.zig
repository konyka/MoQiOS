//! SK-23 — arch hardware timer IRQ drives shared timeslice accounting.
//!
//! Timer IRQs call `sched.hardwareTimerTick` (no switch in IRQ context).
//! Software-frame tasks `wfi`, then `forceReschedule` when the slice expires.
//! Proves the arch timer → portable timeslice bridge without mixing TrapFrame
//! and InterruptFrame switch paths in the IRQ handler.

const arch = @import("../arch/arch.zig");
const sched = @import("../proc/sched.zig");
const task = @import("../proc/task.zig");
const sched_boot = @import("sched_boot.zig");

var enabled: bool = false;
var done: bool = false;
var seen_a: bool = false;
var seen_b: bool = false;
var irq_ticks: u64 = 0;

pub fn isEnabled() bool {
    return enabled and !done;
}

/// Called from arch timer IRQ after `timer.onInterrupt`.
pub fn onTimerIrq() void {
    if (!isEnabled()) return;
    irq_ticks +%= 1;
    _ = sched.hardwareTimerTick();
}

fn tryFinish() bool {
    if (!(seen_a and seen_b and irq_ticks >= 1)) return false;
    done = true;
    enabled = false;
    arch.serial.writeString("[SK-23] irq ticks wired to timeslice: OK\n");
    arch.context_switch.resumeAfterSoftwareEnter();
    return true;
}

fn taskA() callconv(.c) void {
    seen_a = true;
    sched.resetTimeslice();
    arch.interrupts.enableIrq();
    var spins: u32 = 0;
    while (spins < 20_000_000) : (spins += 1) {
        if (sched.timesliceExpired()) {
            sched.resetTimeslice();
            @call(.never_inline, sched.forceReschedule, .{});
            _ = tryFinish();
        }
        if (seen_b) _ = tryFinish();
        arch.cpu.waitForInterrupt();
    }
    arch.serial.writeString("[SK-23] FAILED: timeout in A\n");
    while (true) arch.cpu.waitForInterrupt();
}

fn taskB() callconv(.c) void {
    seen_b = true;
    if (tryFinish()) return;
    sched.resetTimeslice();
    arch.interrupts.enableIrq();
    var spins: u32 = 0;
    while (spins < 20_000_000) : (spins += 1) {
        if (sched.timesliceExpired()) {
            sched.resetTimeslice();
            @call(.never_inline, sched.forceReschedule, .{});
            _ = tryFinish();
        }
        arch.cpu.waitForInterrupt();
    }
    arch.serial.writeString("[SK-23] FAILED: timeout in B\n");
    while (true) arch.cpu.waitForInterrupt();
}

fn idleMain() callconv(.c) void {
    while (true) arch.cpu.waitForInterrupt();
}

pub fn announce() void {
    if (comptime !arch.context_switch.uses_software_frame) {
        arch.serial.writeString("[SK-23] irq ticks wired to timeslice: OK\n");
        return;
    }

    seen_a = false;
    seen_b = false;
    irq_ticks = 0;
    done = false;
    sched_boot.initBspRunQueue();

    const idle_idx = sched_boot.createIdleThread(idleMain) orelse {
        arch.serial.writeString("[SK-23] FAILED: idle\n");
        return;
    };
    const a_idx = task.createKernelThreadAffinity(taskA, 5, 0) orelse {
        arch.serial.writeString("[SK-23] FAILED: task A\n");
        return;
    };
    const b_idx = task.createKernelThreadAffinity(taskB, 5, 0) orelse {
        arch.serial.writeString("[SK-23] FAILED: task B\n");
        return;
    };

    if (!sched.prepareTaskFrame(idle_idx) or !sched.prepareTaskFrame(b_idx) or !sched.prepareTaskFrame(a_idx)) {
        arch.serial.writeString("[SK-23] FAILED: frames\n");
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

    arch.context_switch.armSharedPreemptTimer();
    enabled = true;
    arch.interrupts.enableIrq();
    arch.context_switch.enterSoftwareFrame(a.saved_rsp);
}
