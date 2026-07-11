//! SK-12 — shared sched create/idle callable on non-x86.
//!
//! Wires real page-table roots into the paging facade, uses portable
//! enableIrq+waitForInterrupt idle, and allocates identity-mapped kernel
//! stacks so `createKernelThread(kernelIdleLoop)` succeeds after SK-6.

const arch = @import("../arch/arch.zig");
const sched = @import("../proc/sched.zig");
const task = @import("../proc/task.zig");
const fmt_core = @import("../lib/fmt_core.zig");

pub fn announce() void {
    const root = arch.paging.getKernelPml4();
    if (root == 0) {
        arch.serial.writeString("[SK-12] FAILED: page root is 0\n");
        return;
    }

    const idx = task.createKernelThread(sched.kernelIdleLoop, 255) orelse {
        arch.serial.writeString("[SK-12] FAILED: createKernelThread\n");
        return;
    };

    _ = sched.getAnchor();
    _ = @sizeOf(arch.interrupts.InterruptFrame);

    arch.serial.writeString("[SK-12] root=0x");
    var hex: [16]u8 = undefined;
    arch.serial.writeString(fmt_core.fmtHex16(&hex, root));
    arch.serial.writeString(" idle_idx=");
    var dec: [10]u8 = undefined;
    arch.serial.writeString(fmt_core.fmtDec(&dec, idx));
    arch.serial.writeString("\n");
    arch.serial.writeString("[SK-12] shared sched create+idle callable: OK\n");
}
