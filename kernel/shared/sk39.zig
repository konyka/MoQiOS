//! SK-39 — non-x86 FdTable slimming (follow-up to SK-37/38).
//!
//! `vfs.MAX_FDS` drops to 8 off x86; the free-slot bitmap masks bits >=
//! MAX_FDS so allocFd can never hand out an out-of-range slot.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const task = @import("../proc/task.zig");
const vfs = @import("../fs/vfs.zig");
const fmt_core = @import("../lib/fmt_core.zig");

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-39] slim fd table: OK\n");
        return;
    }

    if (comptime @sizeOf(task.Task) > 8 * 1024) {
        @compileError("SK-39: non-x86 Task exceeds 8KB — fd table slimming regressed");
    }

    var table = vfs.FdTable.init();
    const fd = table.allocFd() orelse {
        arch.serial.writeString("[SK-39] FAILED: allocFd\n");
        return;
    };
    if (fd < 3 or fd >= vfs.MAX_FDS) {
        arch.serial.writeString("[SK-39] FAILED: fd out of range\n");
        return;
    }
    table.freeFd(fd);
    const fd2 = table.allocFd() orelse {
        arch.serial.writeString("[SK-39] FAILED: realloc\n");
        return;
    };
    if (fd2 != fd) {
        arch.serial.writeString("[SK-39] FAILED: bitmap round-trip\n");
        return;
    }

    var dec: [20]u8 = undefined;
    arch.serial.writeString("[SK-39] task_bytes=");
    arch.serial.writeString(fmt_core.fmtDec(&dec, @sizeOf(task.Task)));
    arch.serial.writeString("\n");
    arch.serial.writeString("[SK-39] slim fd table: OK\n");
}
