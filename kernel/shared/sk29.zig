//! SK-29 — shared sched pick drives U↔U native TrapFrame preempt.
//!
//! Same IRQ frame-pointer return as SK-15/28, but `next` comes from
//! `sched.nativeTrapFramePreempt` (enqueue/pick) instead of a probe-local
//! array. Does not wire `preemptFromIrq` / software InterruptFrames.

const arch = @import("../arch/arch.zig");
const task = @import("../proc/task.zig");
const sched = @import("../proc/sched.zig");
const sched_boot = @import("sched_boot.zig");
const fmt_core = @import("../lib/fmt_core.zig");

var enabled: bool = false;
var done: bool = false;
var switches: u64 = 0;
var idx0: u32 = 0;
var idx1: u32 = 0;
var ran0: bool = false;
var ran1: bool = false;

pub fn isEnabled() bool {
    return enabled and !done;
}

/// Timer IRQ: shared-sched native TrapFrame switch (returns next frame ptr).
pub fn onTimer(frame_ptr: u64) u64 {
    if (!enabled or done) return frame_ptr;
    if (!arch.context_switch.irqFromUserMode(frame_ptr)) return frame_ptr;

    if (sched.currentTaskIndex()) |cur| {
        if (cur == idx0) ran0 = true;
        if (cur == idx1) ran1 = true;
    }

    const next_frame = sched.nativeTrapFramePreempt(frame_ptr) orelse return frame_ptr;
    switches +%= 1;

    if (switches >= 2 and ran0 and ran1) {
        done = true;
        enabled = false;
        arch.serial.writeString("[SK-29] switches=");
        var dec: [20]u8 = undefined;
        arch.serial.writeString(fmt_core.fmtDec(&dec, switches));
        arch.serial.writeString("\n");
        arch.serial.writeString("[SK-29] sched native-user preempt: OK\n");
        arch.context_switch.finishUserIrqProbe();
    }

    return next_frame;
}

fn userStackHolder() callconv(.c) noreturn {
    while (true) arch.cpu.waitForInterrupt();
}

pub fn announce() void {
    if (comptime !arch.context_switch.uses_software_frame) {
        arch.serial.writeString("[SK-29] sched native-user preempt: OK\n");
        return;
    }

    arch.interrupts.disableIrq();
    switches = 0;
    ran0 = false;
    ran1 = false;
    done = false;
    enabled = false;

    sched_boot.initBspRunQueue();

    if (!arch.context_switch.prepareDualUserIrqProbe()) {
        arch.serial.writeString("[SK-29] FAILED: prepare dual user pages\n");
        return;
    }

    idx0 = task.createKernelThreadAffinity(userStackHolder, 5, 0) orelse {
        arch.serial.writeString("[SK-29] FAILED: task0\n");
        return;
    };
    idx1 = task.createKernelThreadAffinity(userStackHolder, 5, 0) orelse {
        arch.serial.writeString("[SK-29] FAILED: task1\n");
        return;
    };
    const t0 = task.getTask(idx0) orelse return;
    const t1 = task.getTask(idx1) orelse return;

    const entry = arch.context_switch.userProbeTextVa();
    // Install native user TrapFrames into saved_rsp — do not prepareTaskFrame
    // (that builds a software InterruptFrame).
    t0.saved_rsp = arch.context_switch.buildUserTrapFrame(
        t0.kernel_stack_top,
        entry,
        arch.context_switch.userProbeStackTop(),
    );
    t1.saved_rsp = arch.context_switch.buildUserTrapFrame(
        t1.kernel_stack_top,
        entry,
        arch.context_switch.userProbeStackTop1(),
    );
    if (t0.saved_rsp == 0 or t1.saved_rsp == 0) {
        arch.serial.writeString("[SK-29] FAILED: trap frames\n");
        return;
    }
    t0.started = true;
    t1.started = true;

    t1.state = .ready;
    sched.enqueue(t1);
    t0.state = .running;
    sched.setCurrentTaskIndex(idx0);
    sched.setAnchor(t0.saved_rsp);

    arch.context_switch.armSharedPreemptTimer();
    enabled = true;
    arch.context_switch.enterTrapFrame(t0.saved_rsp);
}
