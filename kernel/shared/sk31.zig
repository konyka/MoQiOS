//! SK-31 — default timer IRQ fallthrough → `nativeUserTimerPreempt`.
//!
//! Unlike SK-15..30, this is **not** gated by `isEnabled()` in the arch trap
//! ladder. After those probes, timer IRQs land here so the production path and
//! the SK-31 probe exercise the same code. M5/M9-7 still hit early `sk16`.

const arch = @import("../arch/arch.zig");
const task = @import("../proc/task.zig");
const sched = @import("../proc/sched.zig");
const sched_boot = @import("sched_boot.zig");
const fmt_core = @import("../lib/fmt_core.zig");

var probe_active: bool = false;
var done: bool = false;
var switches: u64 = 0;
var irq_ticks: u64 = 0;
var idx0: u32 = 0;
var idx1: u32 = 0;
var ran0: bool = false;
var ran1: bool = false;

/// Default timer fallthrough (always installed after sk15..sk30).
pub fn onDefaultTimer(frame_ptr: u64) u64 {
    if (!arch.context_switch.irqFromUserMode(frame_ptr)) return frame_ptr;
    // Bare M6/M9-6 user.enter has no sched current — leave the frame alone.
    if (sched.currentTaskIndex() == null) return frame_ptr;

    if (probe_active and !done) {
        irq_ticks +%= 1;
        if (sched.currentTaskIndex()) |cur| {
            if (cur == idx0) ran0 = true;
            if (cur == idx1) ran1 = true;
        }
    }

    const next_frame = sched.nativeUserTimerPreempt(frame_ptr) orelse return frame_ptr;

    if (probe_active and !done) {
        switches +%= 1;
        if (switches >= 2 and ran0 and ran1 and irq_ticks >= sched.TIMESLICE_TICKS_PUB) {
            done = true;
            probe_active = false;
            sched.setCurrentTaskIndex(null);
            arch.serial.writeString("[SK-31] switches=");
            var dec: [20]u8 = undefined;
            arch.serial.writeString(fmt_core.fmtDec(&dec, switches));
            arch.serial.writeString(" ticks=");
            arch.serial.writeString(fmt_core.fmtDec(&dec, irq_ticks));
            arch.serial.writeString("\n");
            arch.serial.writeString("[SK-31] default timer native-user preempt: OK\n");
            arch.context_switch.finishUserIrqProbe();
        }
    }

    return next_frame;
}

fn userStackHolder() callconv(.c) noreturn {
    while (true) arch.cpu.waitForInterrupt();
}

pub fn announce() void {
    if (comptime !arch.context_switch.uses_software_frame) {
        arch.serial.writeString("[SK-31] default timer native-user preempt: OK\n");
        return;
    }

    arch.interrupts.disableIrq();
    switches = 0;
    irq_ticks = 0;
    ran0 = false;
    ran1 = false;
    done = false;
    probe_active = false;

    sched_boot.initBspRunQueue();

    if (!arch.context_switch.prepareDualUserIrqProbe()) {
        arch.serial.writeString("[SK-31] FAILED: prepare dual user pages\n");
        return;
    }

    idx0 = task.createKernelThreadAffinity(userStackHolder, 5, 0) orelse {
        arch.serial.writeString("[SK-31] FAILED: task0\n");
        return;
    };
    idx1 = task.createKernelThreadAffinity(userStackHolder, 5, 0) orelse {
        arch.serial.writeString("[SK-31] FAILED: task1\n");
        return;
    };
    const t0 = task.getTask(idx0) orelse return;
    const t1 = task.getTask(idx1) orelse return;

    const entry = arch.context_switch.userProbeTextVa();
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
        arch.serial.writeString("[SK-31] FAILED: trap frames\n");
        return;
    }
    t0.started = true;
    t1.started = true;

    t1.state = .ready;
    sched.enqueue(t1);
    t0.state = .running;
    sched.setCurrentTaskIndex(idx0);
    sched.setAnchor(t0.saved_rsp);
    sched.resetTimeslice();

    arch.context_switch.armSharedPreemptTimer();
    // Probe uses the default fallthrough — no trap-ladder isEnabled gate.
    probe_active = true;
    arch.context_switch.enterTrapFrame(t0.saved_rsp);
}
