//! SK-37 — non-x86 BSS slimming (readahead window + symbol table).
//!
//! Verifies the arch-gated sizes actually shrank the static task table and
//! that task creation still works with the slimmed layout.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const task = @import("../proc/task.zig");
const fmt_core = @import("../lib/fmt_core.zig");

fn parkBody() callconv(.c) void {
    while (true) arch.cpu.waitForInterrupt();
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-37] slim task/symbol footprint: OK\n");
        return;
    }

    // Slimmed readahead window must cap Task well below the x86 ~62KB layout
    // (remaining bulk: 64-entry FdTable + env/cwd buffers).
    if (comptime @sizeOf(task.Task) > 24 * 1024) {
        @compileError("SK-37: non-x86 Task exceeds 24KB — readahead window regressed");
    }

    const idx = task.createKernelThread(parkBody, 255) orelse {
        arch.serial.writeString("[SK-37] FAILED: createKernelThread\n");
        return;
    };
    if (task.getTask(idx) == null) {
        arch.serial.writeString("[SK-37] FAILED: getTask\n");
        return;
    }

    var dec: [20]u8 = undefined;
    arch.serial.writeString("[SK-37] task_bytes=");
    arch.serial.writeString(fmt_core.fmtDec(&dec, @sizeOf(task.Task)));
    arch.serial.writeString("\n");
    arch.serial.writeString("[SK-37] slim task/symbol footprint: OK\n");
}
