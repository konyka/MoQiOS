//! SK-32 — shared SK probe ladder + slab boot fragment.
//!
//! Proves `sk_probes.runPostMm` ends here and `subsystem_boot.initSlab`
//! matches `main.zig`'s M2 slab call (idempotent after SK-6).

const arch = @import("../arch/arch.zig");
const subsystem_boot = @import("subsystem_boot.zig");
const slab = @import("../mm/slab.zig");

pub fn announce() void {
    subsystem_boot.initSlab();

    const ptr = slab.kmalloc(64) orelse {
        arch.serial.writeString("[SK-32] FAILED: kmalloc\n");
        return;
    };
    const bytes: [*]u8 = @ptrCast(ptr);
    bytes[0] = 0x32;
    bytes[1] = 0xA5;
    if (bytes[0] != 0x32 or bytes[1] != 0xA5) {
        arch.serial.writeString("[SK-32] FAILED: slab R/W\n");
        slab.kfree(ptr);
        return;
    }
    slab.kfree(ptr);

    arch.serial.writeString("[SK-32] shared sk probes+slab boot: OK\n");
}
