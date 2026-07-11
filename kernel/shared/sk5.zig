//! SK-5 — shared `mm/pmm` arena + `mm/slab` on non-x86 skeletons.
//!
//! Uses a compact identity-mapped BSS arena so the Limine-oriented bitmap PMM
//! can run without covering the entire physical address space. Swap reclaim
//! stays comptime-gated to x86_64 inside `pmm.allocPage`.

const arch = @import("../arch/arch.zig");
const hhdm = @import("../mm/hhdm.zig");
const pmm = @import("../mm/pmm.zig");
const slab = @import("../mm/slab.zig");
const fmt_core = @import("../lib/fmt_core.zig");

/// 2 MiB is enough for metadata + several slab refill pages.
var arena: [2 * 1024 * 1024]u8 align(4096) = undefined;

pub fn announce() void {
    // Identity map: phys == virt for the arena (riscv/aarch64 bring-up).
    hhdm.init(0);
    const base: u64 = @intFromPtr(&arena);
    pmm.initArena(base, arena.len);
    slab.init();

    const ptr = slab.kmalloc(64) orelse {
        arch.serial.writeString("[SK-5] FAILED: kmalloc\n");
        return;
    };
    const bytes: [*]u8 = @ptrCast(ptr);
    bytes[0] = 0x5a;
    bytes[1] = 0x5b;
    if (bytes[0] != 0x5a or bytes[1] != 0x5b) {
        arch.serial.writeString("[SK-5] FAILED: slab R/W\n");
        return;
    }
    slab.kfree(ptr);

    arch.serial.writeString("[SK-5] shared pmm free=");
    var buf: [20]u8 = undefined;
    arch.serial.writeString(fmt_core.fmtDec(&buf, pmm.freePages()));
    arch.serial.writeString("\n");
    arch.serial.writeString("[SK-5] shared pmm+slab: OK\n");
}
