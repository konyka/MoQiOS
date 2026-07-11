//! SK-3 — expanded shared-kernel allowlist for non-x86 skeletons.
//!
//! Pulls additional portable modules (`hhdm`, `fmt_core`) that have no Limine
//! or x86 I/O dependency. Full `main.zig` / drivers remain SK-later.

const arch = @import("../arch/arch.zig");
const hhdm = @import("../mm/hhdm.zig");
const fmt_core = @import("../lib/fmt_core.zig");

/// Call after SK-2 announce (console already up).
pub fn announce() void {
    // Identity HHDM (offset 0) — valid on identity-mapped riscv/aarch64 bring-up.
    hhdm.init(0);
    const v = hhdm.physToVirt(0x1000);
    var buf: [16]u8 = undefined;
    const hex = fmt_core.fmtHex16(&buf, v);

    arch.serial.writeString("[SK-3] hhdm+fmt_core virt=");
    arch.serial.writeString(hex);
    arch.serial.writeString("\n");
    arch.serial.writeString("[SK-3] shared allowlist: OK\n");
}
