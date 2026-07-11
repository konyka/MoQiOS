//! SK-2 — first shared-kernel subset linked into non-x86 skeletons.
//!
//! Proves that `klog` / `lib/fmt` / `arch` facade compile and run on riscv64
//! and aarch64 without pulling Limine or x86 drivers. Full `main.zig` linking
//! remains a later SK step.

const arch = @import("../arch/arch.zig");
const klog = @import("../klog.zig");
const fmt = @import("../lib/fmt.zig");

/// Call once after the arch early console is initialized.
pub fn announce() void {
    klog.log(.info, "SK-2 shared klog path active");
    arch.serial.writeString("[SK-2] shared fmt hex=");
    fmt.writeHex(0xcafebabe);
    arch.serial.writeString("\n");
    arch.serial.writeString("[SK-2] shared kernel subset: OK\n");
}
