//! SK-38 — env buffer slimming on non-x86 (follow-up to SK-37).
//!
//! `Task.env_vars` shrinks from 32x128 to 4x64 off x86; env syscall code now
//! sizes its bounds from `task.ENV_MAX_VARS` / `ENV_VAR_BYTES`.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const task = @import("../proc/task.zig");
const fmt_core = @import("../lib/fmt_core.zig");

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-38] slim env buffers: OK\n");
        return;
    }

    if (comptime @sizeOf(task.Task) > 16 * 1024) {
        @compileError("SK-38: non-x86 Task exceeds 16KB — env slimming regressed");
    }

    var dec: [20]u8 = undefined;
    arch.serial.writeString("[SK-38] task_bytes=");
    arch.serial.writeString(fmt_core.fmtDec(&dec, @sizeOf(task.Task)));
    arch.serial.writeString("\n");
    arch.serial.writeString("[SK-38] slim env buffers: OK\n");
}
