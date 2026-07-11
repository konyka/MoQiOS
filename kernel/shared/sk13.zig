//! SK-13 — shared sched builds a portable InterruptFrame + switch anchor.
//!
//! After SK-12 create, `prepareTaskFrame` writes a software frame (x86-shaped
//! field names) onto the kernel stack and publishes `saved_rsp` via the
//! per-CPU anchor — without entering the task.

const arch = @import("../arch/arch.zig");
const sched = @import("../proc/sched.zig");
const task = @import("../proc/task.zig");
const fmt_core = @import("../lib/fmt_core.zig");

pub fn announce() void {
    _ = arch.context_switch.uses_software_frame;

    const idx = task.createKernelThread(sched.kernelIdleLoop, 255) orelse {
        arch.serial.writeString("[SK-13] FAILED: createKernelThread\n");
        return;
    };

    if (!sched.prepareTaskFrame(idx)) {
        arch.serial.writeString("[SK-13] FAILED: prepareTaskFrame\n");
        return;
    }

    const t = task.getTask(idx) orelse {
        arch.serial.writeString("[SK-13] FAILED: getTask\n");
        return;
    };

    const frame: *arch.interrupts.InterruptFrame = @ptrFromInt(t.saved_rsp);
    const want: u64 = @intFromPtr(&sched.kernelIdleLoop);
    if (frame.rip != want) {
        arch.serial.writeString("[SK-13] FAILED: frame.rip mismatch\n");
        return;
    }
    if (sched.getAnchor() != t.saved_rsp) {
        arch.serial.writeString("[SK-13] FAILED: anchor mismatch\n");
        return;
    }

    arch.serial.writeString("[SK-13] frame_rsp=0x");
    var hex: [16]u8 = undefined;
    arch.serial.writeString(fmt_core.fmtHex16(&hex, t.saved_rsp));
    arch.serial.writeString(" rip=0x");
    arch.serial.writeString(fmt_core.fmtHex16(&hex, frame.rip));
    arch.serial.writeString("\n");
    arch.serial.writeString("[SK-13] shared InterruptFrame+anchor: OK\n");
}
