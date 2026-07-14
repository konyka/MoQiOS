//! SK-21 — shared `main.zig` subsystem boot (gdt/tsc/ipc/capability/syscall).
//!
//! Exercises `shared/subsystem_boot.zig` on non-x86: the same init trio and
//! CPU surfaces main.zig uses, then a trivial TSC read to prove the facade
//! path stays live after init.

const arch = @import("../arch/arch.zig");
const subsystem_boot = @import("subsystem_boot.zig");

pub fn announce() void {
    subsystem_boot.initAll();

    const t0 = arch.tsc.read();
    const t1 = arch.tsc.read();
    // Monotonic or equal is fine on stubs; only a jump backward fails.
    if (t1 < t0) {
        arch.serial.writeString("[SK-21] FAILED: tsc went backwards\n");
        return;
    }

    _ = arch.gdt;
    _ = arch.syscall.MAX_CPUS;

    arch.serial.writeString("[SK-21] shared subsystem boot: OK\n");
}
