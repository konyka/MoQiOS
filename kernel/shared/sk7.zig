//! SK-7 — shared-kernel serial path is the arch facade only.
//!
//! Leaf kernel modules (mm/fs/ipc/net/proc/drivers/…) no longer import
//! `arch/x86_64/serial.zig` directly; they use `arch/arch.zig`.serial.

const arch = @import("../arch/arch.zig");

pub fn announce() void {
    arch.serial.writeString("[SK-7] serial via arch facade: OK\n");
}
