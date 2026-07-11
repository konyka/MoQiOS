//! SK-8 — shared code reaches paging/tsc/tlb only through the arch facade.
//!
//! Leaf modules no longer import `arch/x86_64/{paging,tsc,tlb}.zig` directly.

const arch = @import("../arch/arch.zig");
const fmt_core = @import("../lib/fmt_core.zig");

pub fn announce() void {
    const page_size = arch.paging.PAGE_SIZE;
    const tick = arch.tsc.read();
    arch.tlb.shootdownRange(0, 0);

    arch.serial.writeString("[SK-8] paging.PAGE_SIZE=");
    var buf: [20]u8 = undefined;
    arch.serial.writeString(fmt_core.fmtDec(&buf, page_size));
    arch.serial.writeString(" tsc=");
    var hex: [16]u8 = undefined;
    arch.serial.writeString(fmt_core.fmtHex16(&hex, tick));
    arch.serial.writeString("\n");
    arch.serial.writeString("[SK-8] paging/tsc/tlb via facade: OK\n");
}
