//! SK-25 — shared portable mm boot (`addr_space` + `dma`).
//!
//! Exercises `subsystem_boot.initPortableMm` the same way `main.zig` does for
//! M2, then proves the managers work: register a VA range and round-trip a
//! single-page coherent DMA buffer via shared PMM/HHDM.

const arch = @import("../arch/arch.zig");
const subsystem_boot = @import("subsystem_boot.zig");
const addr_space = @import("../mm/addr_space.zig");
const dma = @import("../mm/dma.zig");

const PROBE_VA_START: u64 = 0xFFFF_0000_1000_0000;
const PROBE_VA_END: u64 = 0xFFFF_0000_1000_1000;

pub fn announce() void {
    subsystem_boot.initPortableMm();

    addr_space.addRange(PROBE_VA_START, PROBE_VA_END, true, false);
    if (addr_space.getRangeCount() < 1) {
        arch.serial.writeString("[SK-25] FAILED: no ranges after addRange\n");
        return;
    }
    const found = addr_space.findRange(PROBE_VA_START) orelse {
        arch.serial.writeString("[SK-25] FAILED: findRange miss\n");
        return;
    };
    if (found.start != PROBE_VA_START or found.end != PROBE_VA_END or !found.writable) {
        arch.serial.writeString("[SK-25] FAILED: range mismatch\n");
        return;
    }

    const buf = dma.allocCoherent(4096) orelse {
        arch.serial.writeString("[SK-25] FAILED: allocCoherent\n");
        return;
    };
    const bytes: [*]u8 = @ptrFromInt(buf.virt_addr);
    bytes[0] = 0x25;
    bytes[1] = 0xA5;
    if (bytes[0] != 0x25 or bytes[1] != 0xA5) {
        arch.serial.writeString("[SK-25] FAILED: dma R/W\n");
        dma.freeCoherent(buf);
        return;
    }
    if (buf.phys_addr == 0 or buf.size < 4096) {
        arch.serial.writeString("[SK-25] FAILED: dma meta\n");
        dma.freeCoherent(buf);
        return;
    }
    dma.freeCoherent(buf);

    arch.serial.writeString("[SK-25] shared portable mm boot: OK\n");
}
