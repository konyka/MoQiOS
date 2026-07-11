//! SK-9 — interrupts/gdt/syscall/timer/io reached only via the arch facade.
//!
//! Leaf modules no longer import x86_64 idt/gdt/syscall_entry/lapic/io/
//! context_switch directly.

const arch = @import("../arch/arch.zig");

pub fn announce() void {
    // Touch the SK-9 surfaces so missing stubs fail at link/compile time.
    _ = arch.interrupts;
    _ = arch.gdt;
    _ = arch.syscall.MAX_CPUS;
    _ = arch.timer;
    _ = arch.context_switch;
    _ = arch.io;
    arch.gdt.setRsp0(0, 0);
    _ = arch.io.inb(0x80);

    arch.serial.writeString("[SK-9] idt/gdt/syscall/io via facade: OK\n");
}
