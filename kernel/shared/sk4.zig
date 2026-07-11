//! SK-4 — portable IrqSpinlock + arch.irq (no x86 pushfq/cli in shared sync).
//!
//! Proves `sync/irq_spinlock.zig` links and runs on riscv64/aarch64 via the
//! arch facade. Limine-backed `mm/pmm` init remains x86-only for now.

const arch = @import("../arch/arch.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

var lock: IrqSpinlock = .{};
var counter: u32 = 0;

pub fn announce() void {
    const saved = lock.acquire();
    counter +%= 1;
    const v = counter;
    lock.release(saved);

    arch.serial.writeString("[SK-4] irq_spinlock counter=");
    var buf: [10]u8 = undefined;
    const s = @import("../lib/fmt_core.zig").fmtDec(&buf, v);
    arch.serial.writeString(s);
    arch.serial.writeString("\n");
    arch.serial.writeString("[SK-4] portable irq_spinlock: OK\n");
}
