//! SK-16 — shared dual-thread timer preempt for arch milestones (M5 / M9-7).
//!
//! Converges the arch-local BSS mini-schedulers onto `proc/task` stacks +
//! facade TrapFrames (same path as SK-15). Arch code only supplies the
//! milestone banner and a noreturn completion hook (shutdown / halt).

const arch = @import("../arch/arch.zig");
const task = @import("../proc/task.zig");
const fmt_core = @import("../lib/fmt_core.zig");

var frame_ptrs: [2]u64 = .{ 0, 0 };
var entries: [2]u64 = .{ 0, 0 };
var current: u8 = 0;
var switches: u64 = 0;
var enabled: bool = false;
var done: bool = false;
var on_complete: ?*const fn () callconv(.c) noreturn = null;

pub fn isEnabled() bool {
    return enabled and !done;
}

/// Timer IRQ hook. Returns the TrapFrame pointer to resume (or never returns
/// once the milestone completion hook runs).
pub fn onTimer(frame_ptr: u64) u64 {
    if (!enabled or done) return frame_ptr;

    frame_ptrs[current] = frame_ptr;
    current ^= 1;
    switches +%= 1;

    if (switches >= 8 and entries[0] >= 1 and entries[1] >= 1) {
        done = true;
        enabled = false;
        arch.serial.writeString("  [sched] preemptive switches=");
        var dec: [20]u8 = undefined;
        arch.serial.writeString(fmt_core.fmtDec(&dec, switches));
        arch.serial.writeString(" t0_entries=");
        arch.serial.writeString(fmt_core.fmtDec(&dec, entries[0]));
        arch.serial.writeString(" t1_entries=");
        arch.serial.writeString(fmt_core.fmtDec(&dec, entries[1]));
        arch.serial.writeString("\n");
        arch.serial.writeString("[SK-16] shared milestone preempt: OK\n");
        if (on_complete) |f| f();
        while (true) arch.cpu.waitForInterrupt();
    }

    return frame_ptrs[current];
}

fn thread0() callconv(.c) noreturn {
    entries[0] +%= 1;
    arch.serial.writeString("  [sched] thread0 start\n");
    while (!done) {
        arch.cpu.waitForInterrupt();
    }
    while (true) arch.cpu.waitForInterrupt();
}

fn thread1() callconv(.c) noreturn {
    entries[1] +%= 1;
    arch.serial.writeString("  [sched] thread1 start\n");
    while (!done) {
        arch.cpu.waitForInterrupt();
    }
    while (true) arch.cpu.waitForInterrupt();
}

/// Create two shared kernel threads and `enterTrapFrame` into thread0 (noreturn).
pub fn run(complete: *const fn () callconv(.c) noreturn) noreturn {
    arch.interrupts.disableIrq();
    on_complete = complete;

    const idx0 = task.createKernelThread(thread0, 255) orelse {
        arch.serial.writeString("[SK-16] FAILED: create t0\n");
        while (true) arch.cpu.waitForInterrupt();
    };
    const idx1 = task.createKernelThread(thread1, 255) orelse {
        arch.serial.writeString("[SK-16] FAILED: create t1\n");
        while (true) arch.cpu.waitForInterrupt();
    };
    const t0 = task.getTask(idx0) orelse {
        while (true) arch.cpu.waitForInterrupt();
    };
    const t1 = task.getTask(idx1) orelse {
        while (true) arch.cpu.waitForInterrupt();
    };

    frame_ptrs[0] = arch.context_switch.buildKernelTrapFrame(t0.kernel_stack_top, @intFromPtr(&thread0));
    frame_ptrs[1] = arch.context_switch.buildKernelTrapFrame(t1.kernel_stack_top, @intFromPtr(&thread1));
    if (frame_ptrs[0] == 0 or frame_ptrs[1] == 0) {
        arch.serial.writeString("[SK-16] FAILED: trap frames\n");
        while (true) arch.cpu.waitForInterrupt();
    }

    current = 0;
    switches = 0;
    entries = .{ 0, 0 };
    done = false;

    arch.context_switch.armSharedPreemptTimer();
    enabled = true;
    arch.interrupts.enableIrq();
    arch.context_switch.enterTrapFrame(frame_ptrs[0]);
    while (true) arch.cpu.waitForInterrupt();
}
