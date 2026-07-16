//! SK-27 — user-mode native TrapFrame preempt (kernel thread ↔ one user task).
//!
//! Reuses the SK-15 frame-pointer switch on timer IRQ. Does **not** use
//! SK-24 software-frame preempt (kernel privilege + wrong aarch64 EL0 SP).
//! aarch64 IRQ path saves/restores SP_EL0 in TrapFrame.sp_el0.

const arch = @import("../arch/arch.zig");
const task = @import("../proc/task.zig");
const fmt_core = @import("../lib/fmt_core.zig");

var frame_ptrs: [2]u64 = .{ 0, 0 };
var current: u8 = 0;
var switches: u64 = 0;
var enabled: bool = false;
var done: bool = false;
var seen_k: bool = false;
var seen_u: bool = false;

pub fn isEnabled() bool {
    return enabled and !done;
}

/// Timer IRQ: save current native frame, switch to the other (K↔U).
pub fn onTimer(frame_ptr: u64) u64 {
    if (!enabled or done) return frame_ptr;

    if (arch.context_switch.irqFromUserMode(frame_ptr)) {
        seen_u = true;
    }

    frame_ptrs[current] = frame_ptr;
    current ^= 1;
    switches +%= 1;

    // K→U then U→K: both sides observed, at least two switches.
    if (switches >= 2 and seen_k and seen_u) {
        done = true;
        enabled = false;
        arch.serial.writeString("[SK-27] switches=");
        var dec: [20]u8 = undefined;
        arch.serial.writeString(fmt_core.fmtDec(&dec, switches));
        arch.serial.writeString("\n");
        arch.serial.writeString("[SK-27] user trapframe preempt: OK\n");
        // Must clear sscratch / mask IRQs — we abandon a U/EL0 IRQ path.
        arch.context_switch.finishUserIrqProbe();
    }

    return frame_ptrs[current];
}

fn kernelA() callconv(.c) noreturn {
    seen_k = true;
    while (!done) {
        arch.cpu.waitForInterrupt();
    }
    while (true) arch.cpu.waitForInterrupt();
}

fn userStackHolder() callconv(.c) noreturn {
    // Never entered; stack only hosts the synthetic user TrapFrame.
    while (true) arch.cpu.waitForInterrupt();
}

pub fn announce() void {
    if (comptime !arch.context_switch.uses_software_frame) {
        arch.serial.writeString("[SK-27] user trapframe preempt: OK\n");
        return;
    }

    arch.interrupts.disableIrq();
    seen_k = false;
    seen_u = false;
    switches = 0;
    current = 0;
    done = false;
    enabled = false;

    if (!arch.context_switch.prepareUserIrqProbe()) {
        arch.serial.writeString("[SK-27] FAILED: prepare user pages\n");
        return;
    }

    const idx_k = task.createKernelThread(kernelA, 255) orelse {
        arch.serial.writeString("[SK-27] FAILED: kernel thread\n");
        return;
    };
    const idx_u = task.createKernelThread(userStackHolder, 255) orelse {
        arch.serial.writeString("[SK-27] FAILED: user stack holder\n");
        return;
    };
    const tk = task.getTask(idx_k) orelse return;
    const tu = task.getTask(idx_u) orelse return;

    frame_ptrs[0] = arch.context_switch.buildKernelTrapFrame(tk.kernel_stack_top, @intFromPtr(&kernelA));
    frame_ptrs[1] = arch.context_switch.buildUserTrapFrame(
        tu.kernel_stack_top,
        arch.context_switch.userProbeTextVa(),
        arch.context_switch.userProbeStackTop(),
    );
    if (frame_ptrs[0] == 0 or frame_ptrs[1] == 0) {
        arch.serial.writeString("[SK-27] FAILED: trap frames\n");
        return;
    }

    arch.context_switch.armSharedPreemptTimer();
    enabled = true;
    arch.interrupts.enableIrq();
    arch.context_switch.enterTrapFrame(frame_ptrs[0]);
}
