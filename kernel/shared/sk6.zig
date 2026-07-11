//! SK-6 — unify arch-local PMM with shared `mm/pmm` + `mm/slab`.
//!
//! The bring-up carves a contiguous physical range just above the kernel
//! image and withholds it from the arch freelist. Shared PMM owns that
//! range via `initArena` (real RAM, not BSS).

const arch = @import("../arch/arch.zig");
const hhdm = @import("../mm/hhdm.zig");
const pmm = @import("../mm/pmm.zig");
const slab = @import("../mm/slab.zig");
const fmt_core = @import("../lib/fmt_core.zig");

pub const SHARE_BYTES: usize = 4 * 1024 * 1024;

/// `phys_base`/`length` must be identity-mapped and excluded from arch PMM.
pub fn announce(phys_base: u64, length: u64) void {
    if (length < 512 * 1024) {
        arch.serial.writeString("[SK-6] FAILED: carve too small\n");
        return;
    }

    hhdm.init(0);
    pmm.initArena(phys_base, length);
    slab.init();

    const ptr = slab.kmalloc(128) orelse {
        arch.serial.writeString("[SK-6] FAILED: kmalloc\n");
        return;
    };
    const bytes: [*]u8 = @ptrCast(ptr);
    bytes[0] = 0x36;
    bytes[1] = 0x36;
    if (bytes[0] != 0x36 or bytes[1] != 0x36) {
        arch.serial.writeString("[SK-6] FAILED: slab R/W\n");
        return;
    }
    slab.kfree(ptr);

    arch.serial.writeString("[SK-6] carve base=0x");
    var hexbuf: [16]u8 = undefined;
    arch.serial.writeString(fmt_core.fmtHex16(&hexbuf, phys_base));
    arch.serial.writeString(" pages=");
    var decbuf: [20]u8 = undefined;
    arch.serial.writeString(fmt_core.fmtDec(&decbuf, pmm.totalPages()));
    arch.serial.writeString(" free=");
    arch.serial.writeString(fmt_core.fmtDec(&decbuf, pmm.freePages()));
    arch.serial.writeString("\n");
    arch.serial.writeString("[SK-6] unified pmm+slab: OK\n");
}
