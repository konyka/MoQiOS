//! SK-24 — hardware timer IRQ preempts via software InterruptFrames.
//!
//! When the shared timeslice expires in IRQ context, `preemptFromIrq` saves a
//! software continuation from the native trap frame (PC/SP) and
//! `switchToSoftwareFrame`s to another ready task — without returning through
//! the IRQ epilogue.

const arch = @import("../arch/arch.zig");
const sched = @import("../proc/sched.zig");
const task = @import("../proc/task.zig");
const sched_boot = @import("sched_boot.zig");

var enabled: bool = false;
var done: bool = false;
var seen_a: bool = false;
var seen_b: bool = false;
var irq_ticks: u64 = 0;
var irq_preempts: u64 = 0;

pub fn isEnabled() bool {
    return enabled and !done;
}

/// Called from arch timer IRQ after `timer.onInterrupt`.
/// Returns the same trap frame pointer when not preempting; otherwise noreturn.
pub fn onTimerIrq(trap_frame_ptr: u64) u64 {
    if (!isEnabled()) return trap_frame_ptr;
    irq_ticks +%= 1;
    if (!sched.hardwareTimerTick()) return trap_frame_ptr;
    irq_preempts +%= 1;
    sched.preemptFromIrq(trap_frame_ptr);
}

fn tryFinish() bool {
    if (!(seen_a and seen_b and irq_preempts >= 1)) return false;
    done = true;
    enabled = false;
    arch.serial.writeString("[SK-24] irq software-frame preempt: OK\n");
    arch.context_switch.resumeAfterSoftwareEnter();
    return true;
}

fn taskA() callconv(.c) void {
    seen_a = true;
    sched.resetTimeslice();
    arch.interrupts.enableIrq();
    var spins: u32 = 0;
    while (spins < 20_000_000) : (spins += 1) {
        if (seen_b) _ = tryFinish();
        arch.cpu.waitForInterrupt();
    }
    arch.serial.writeString("[SK-24] FAILED: timeout in A\n");
    while (true) arch.cpu.waitForInterrupt();
}

fn taskB() callconv(.c) void {
    seen_b = true;
    if (tryFinish()) return;
    sched.resetTimeslice();
    arch.interrupts.enableIrq();
    var spins: u32 = 0;
    while (spins < 20_000_000) : (spins += 1) {
        arch.cpu.waitForInterrupt();
        if (tryFinish()) return;
    }
    arch.serial.writeString("[SK-24] FAILED: timeout in B\n");
    while (true) arch.cpu.waitForInterrupt();
}

fn idleMain() callconv(.c) void {
    while (true) arch.cpu.waitForInterrupt();
}

pub fn announce() void {
    if (comptime !arch.context_switch.uses_software_frame) {
        arch.serial.writeString("[SK-24] irq software-frame preempt: OK\n");
        return;
    }

    seen_a = false;
    seen_b = false;
    irq_ticks = 0;
    irq_preempts = 0;
    done = false;
    sched_boot.initBspRunQueue();

    const idle_idx = sched_boot.createIdleThreadWith(idleMain) orelse {
        arch.serial.writeString("[SK-24] FAILED: idle\n");
        return;
    };
    const a_idx = task.createKernelThreadAffinity(taskA, 5, 0) orelse {
        arch.serial.writeString("[SK-24] FAILED: task A\n");
        return;
    };
    const b_idx = task.createKernelThreadAffinity(taskB, 5, 0) orelse {
        arch.serial.writeString("[SK-24] FAILED: task B\n");
        return;
    };

    if (!sched.prepareTaskFrame(idle_idx) or !sched.prepareTaskFrame(b_idx) or !sched.prepareTaskFrame(a_idx)) {
        arch.serial.writeString("[SK-24] FAILED: frames\n");
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
