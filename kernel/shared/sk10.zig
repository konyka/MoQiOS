//! SK-10 — comptime-isolated smp / ACPI / PCI boot paths.
//!
//! Non-x86 builds can import and call `smp.init` / `acpi.init` / `pci.init`
//! without embedding the AP trampoline, pulling Limine `main`, or scanning
//! legacy PCI config space.

const arch = @import("../arch/arch.zig");
const smp = @import("../smp.zig");
const acpi = @import("../acpi/acpi_parser.zig");
const pci = @import("../drivers/pci.zig");

pub fn announce() void {
    acpi.init(0);
    pci.init();
    smp.init();

    arch.serial.writeString("[SK-10] smp/acpi/pci isolated: OK\n");
}
