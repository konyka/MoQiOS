//! SK-15 — shared dual kernel-thread preempt via timer IRQ.
//!
//! Uses `proc/task` stacks + arch TrapFrames. Timer IRQs call `onTimer` from
//! the arch trap path; after enough cross-switches both threads have run,
//! print OK and resume bring-up.

const arch = @import("../arch/arch.zig");
const task = @import("../proc/task.zig");
const fmt_core = @import("../lib/fmt_core.zig");

var frame_ptrs: [2]u64 = .{ 0, 0 };
var entries: [2]u64 = .{ 0, 0 };
var current: u8 = 0;
var switches: u64 = 0;
var enabled: bool = false;
var done: bool = false;

pub fn isEnabled() bool {
    return enabled and !done;
}

/// Called from arch timer IRQ. `frame_ptr` is the current native TrapFrame.
/// Returns the TrapFrame pointer to resume.
pub fn onTimer(frame_ptr: u64) u64 {
    if (!enabled or done) return frame_ptr;

    frame_ptrs[current] = frame_ptr;
    current ^= 1;
    switches +%= 1;

    if (switches >= 8 and entries[0] >= 1 and entries[1] >= 1) {
        done = true;
        arch.serial.writeString("[SK-15] preemptive switches=");
        var dec: [20]u8 = undefined;
        arch.serial.writeString(fmt_core.fmtDec(&dec, switches));
        arch.serial.writeString(" t0=");
        arch.serial.writeString(fmt_core.fmtDec(&dec, entries[0]));
        arch.serial.writeString(" t1=");
        arch.serial.writeString(fmt_core.fmtDec(&dec, entries[1]));
        arch.serial.writeString("\n");
        arch.serial.writeString("[SK-15] shared preempt: OK\n");
        enabled = false;
        arch.context_switch.resumeAfterSoftwareEnter();
    }

    return frame_ptrs[current];
}

fn thread0() callconv(.c) noreturn {
    entries[0] +%= 1;
    while (!done) {
        arch.cpu.waitForInterrupt();
    }
    while (true) arch.cpu.waitForInterrupt();
}

fn thread1() callconv(.c) noreturn {
    entries[1] +%= 1;
    while (!done) {
        arch.cpu.waitForInterrupt();
    }
    while (true) arch.cpu.waitForInterrupt();
}

pub fn announce() void {
    // Bring-up may still have SIE/IRQs from SK-14 enter; keep creates non-preemptible.
    // Boot stack must hold several FdTable in-place inits (~57KiB memset each).
    arch.interrupts.disableIrq();

    const idx0 = task.createKernelThread(thread0, 255) orelse {
        arch.serial.writeString("[SK-15] FAILED: create t0\n");
        return;
    };
    const idx1 = task.createKernelThread(thread1, 255) orelse {
        arch.serial.writeString("[SK-15] FAILED: create t1\n");
        return;
    };
    const t0 = task.getTask(idx0) orelse return;
    const t1 = task.getTask(idx1) orelse return;

    frame_ptrs[0] = arch.context_switch.buildKernelTrapFrame(t0.kernel_stack_top, @intFromPtr(&thread0));
    frame_ptrs[1] = arch.context_switch.buildKernelTrapFrame(t1.kernel_stack_top, @intFromPtr(&thread1));
    if (frame_ptrs[0] == 0 or frame_ptrs[1] == 0) {
        arch.serial.writeString("[SK-15] FAILED: trap frames\n");
        return;
    }

    current = 0;
    switches = 0;
    entries = .{ 0, 0 };
    done = false;

    arch.context_switch.armSharedPreemptTimer();
    enabled = true;
    // Match arch-local M5/M9: enable IRQs before enter; TrapFrame SPIE/spsr
    // keeps them enabled after sret/eret.
    arch.interrupts.enableIrq();
    arch.context_switch.enterTrapFrame(frame_ptrs[0]);
}
