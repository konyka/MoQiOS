//! SK-36 — probe-ladder cleanup before arch M5/M6/M9 continue.
//!
//! After sk26…sk31 arm shared timers and set `current`, a failed/early exit
//! can leave non-null current + live timer. SK-31's default fallthrough would
//! then preempt M6/`user.enter`. Clear current, disarm the shared timer, and
//! keep IRQs masked for the subsequent arch bring-up steps.

const arch = @import("../arch/arch.zig");
const sched = @import("../proc/sched.zig");

pub fn announce() void {
    arch.interrupts.disableIrq();
    sched.setCurrentTaskIndex(null);
    arch.context_switch.disarmSharedPreemptTimer();

    if (sched.currentTaskIndex() != null) {
        arch.serial.writeString("[SK-36] FAILED: current still set\n");
        return;
    }

    arch.serial.writeString("[SK-36] probe ladder cleanup: OK\n");
}
