//! SK-14 — enter a shared software InterruptFrame via sret/eret, then resume.
//!
//! Builds a kernel task whose entry prints the SK-14 marker and returns to
//! the caller through `context_switch.resumeAfterSoftwareEnter`, proving the
//! software-frame enter path without parking the bring-up forever.

const arch = @import("../arch/arch.zig");
const sched = @import("../proc/sched.zig");
const task = @import("../proc/task.zig");

fn sk14Body() callconv(.c) void {
    arch.serial.writeString("[SK-14] software-frame enter: OK\n");
    arch.context_switch.resumeAfterSoftwareEnter();
}

pub fn announce() void {
    const idx = task.createKernelThread(sk14Body, 255) orelse {
        arch.serial.writeString("[SK-14] FAILED: createKernelThread\n");
        return;
    };
    if (!sched.prepareTaskFrame(idx)) {
        arch.serial.writeString("[SK-14] FAILED: prepareTaskFrame\n");
        return;
    }
    const t = task.getTask(idx) orelse {
        arch.serial.writeString("[SK-14] FAILED: getTask\n");
        return;
    };

    arch.context_switch.enterSoftwareFrame(t.saved_rsp);
}
