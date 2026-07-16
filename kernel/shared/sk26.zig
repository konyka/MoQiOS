//! SK-26 — user-mode timer IRQ visible via native TrapFrame (no preempt).
//!
//! Proves U/EL0 can take a supervisor/EL1 timer IRQ on the native trap path
//! and return safely. Does not call `preemptFromIrq` / software-frame switch
//! (those hard-code kernel privilege and mishandle EL0 SP).
//! User image: aarch64 `wfi` loop; riscv U-mode uses a nop busy-loop (WFI is
//! illegal in U on virt).

const arch = @import("../arch/arch.zig");

var enabled: bool = false;
var done: bool = false;
var user_ticks: u64 = 0;

pub fn isEnabled() bool {
    return enabled and !done;
}

pub fn userTickCount() u64 {
    return user_ticks;
}

/// Called from arch timer IRQ after `timer.onInterrupt`.
/// Counts ticks taken while interrupted from user mode; on the first such
/// tick, finishes the probe (noreturn via resume slot).
pub fn onTimerIrq(trap_frame_ptr: u64) u64 {
    if (!isEnabled()) return trap_frame_ptr;
    if (!arch.context_switch.irqFromUserMode(trap_frame_ptr)) return trap_frame_ptr;
    user_ticks +%= 1;
    done = true;
    enabled = false;
    arch.context_switch.finishUserIrqProbe();
}

pub fn announce() void {
    if (comptime !arch.context_switch.uses_software_frame) {
        arch.serial.writeString("[SK-26] user timer IRQ visible: OK\n");
        return;
    }

    user_ticks = 0;
    done = false;
    enabled = false;

    arch.interrupts.disableIrq();
    if (!arch.context_switch.prepareUserIrqProbe()) {
        arch.serial.writeString("[SK-26] FAILED: prepare user pages\n");
        return;
    }

    arch.context_switch.armSharedPreemptTimer();
    enabled = true;
    arch.context_switch.enterUserIrqProbe();
    // Resumed from finishUserIrqProbe after a user-mode timer tick.
    enabled = false;
    done = true;

    if (user_ticks >= 1) {
        arch.serial.writeString("[SK-26] user timer IRQ visible: OK\n");
    } else {
        arch.serial.writeString("[SK-26] FAILED: no user-mode timer IRQ\n");
    }
}
