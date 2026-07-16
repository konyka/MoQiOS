//! SK-28 — dual-user native TrapFrame preempt (U↔U).
//!
//! Completes the SK-15/27 triangle: K↔K, K↔U, then U↔U via the same
//! frame-pointer switch. Two user stacks share one busy-loop text page.
//! Abandon via `finishUserIrqProbe` so sscratch / IRQs stay clean.

const arch = @import("../arch/arch.zig");
const task = @import("../proc/task.zig");
const fmt_core = @import("../lib/fmt_core.zig");

var frame_ptrs: [2]u64 = .{ 0, 0 };
var stack_base: [2]u64 = .{ 0, 0 };
var stack_top: [2]u64 = .{ 0, 0 };
var current: u8 = 0;
var switches: u64 = 0;
var enabled: bool = false;
var done: bool = false;
var ran: [2]bool = .{ false, false };

pub fn isEnabled() bool {
    return enabled and !done;
}

/// Timer IRQ: save current user frame, switch to the peer user frame.
pub fn onTimer(frame_ptr: u64) u64 {
    if (!enabled or done) return frame_ptr;

    if (!arch.context_switch.irqFromUserMode(frame_ptr)) {
        return frame_ptr;
    }

    ran[current] = true;
    // Relocate off shared u_trap_stack before the peer's next U IRQ clobbers it.
    frame_ptrs[current] = arch.context_switch.relocateNativeTrapFrame(
        frame_ptr,
        stack_base[current],
        stack_top[current],
    );
    current ^= 1;
    switches +%= 1;

    // ≥4 switches: resume a relocated frame after another U IRQ used the shared stack.
    if (switches >= 4 and ran[0] and ran[1]) {
        done = true;
        enabled = false;
        arch.serial.writeString("[SK-28] switches=");
        var dec: [20]u8 = undefined;
        arch.serial.writeString(fmt_core.fmtDec(&dec, switches));
        arch.serial.writeString("\n");
        arch.serial.writeString("[SK-28] dual-user trapframe preempt: OK\n");
        arch.context_switch.finishUserIrqProbe();
    }

    return frame_ptrs[current];
}

fn userStackHolder() callconv(.c) noreturn {
    while (true) arch.cpu.waitForInterrupt();
}

pub fn announce() void {
    if (comptime !arch.context_switch.uses_software_frame) {
        arch.serial.writeString("[SK-28] dual-user trapframe preempt: OK\n");
        return;
    }

    arch.interrupts.disableIrq();
    ran = .{ false, false };
    switches = 0;
    current = 0;
    done = false;
    enabled = false;

    if (!arch.context_switch.prepareDualUserIrqProbe()) {
        arch.serial.writeString("[SK-28] FAILED: prepare dual user pages\n");
        return;
    }

    const idx0 = task.createKernelThread(userStackHolder, 255) orelse {
        arch.serial.writeString("[SK-28] FAILED: holder0\n");
        return;
    };
    const idx1 = task.createKernelThread(userStackHolder, 255) orelse {
        arch.serial.writeString("[SK-28] FAILED: holder1\n");
        return;
    };
    const t0 = task.getTask(idx0) orelse return;
    const t1 = task.getTask(idx1) orelse return;
    stack_base[0] = t0.kernel_stack;
    stack_base[1] = t1.kernel_stack;
    stack_top[0] = t0.kernel_stack_top;
    stack_top[1] = t1.kernel_stack_top;

    const entry = arch.context_switch.userProbeTextVa();
    frame_ptrs[0] = arch.context_switch.buildUserTrapFrame(
        t0.kernel_stack_top,
        entry,
        arch.context_switch.userProbeStackTop(),
    );
    frame_ptrs[1] = arch.context_switch.buildUserTrapFrame(
        t1.kernel_stack_top,
        entry,
        arch.context_switch.userProbeStackTop1(),
    );
    if (frame_ptrs[0] == 0 or frame_ptrs[1] == 0) {
        arch.serial.writeString("[SK-28] FAILED: trap frames\n");
        return;
    }

    arch.context_switch.armSharedPreemptTimer();
    enabled = true;
    // Keep SIE clear until sret: user TrapFrame SPIE enables IRQs in U-mode.
    // Enabling here races timer IRQs through enterTrapFrame's S-mode window.
    arch.context_switch.enterTrapFrame(frame_ptrs[0]);
}
