//! SK-50 — active-NIC facade (`net/nic.zig`) links and runs on non-x86.
//!
//! SK-47/48/49 moved the arch-clean protocol *logic* (eth/ipv4/ipv6) onto
//! riscv64/aarch64. The remaining blocker to linking the wider `net/*` tree
//! there was `nic.zig`, which unconditionally imported `drivers/e1000.zig` +
//! `drivers/virtio_net.zig` — both reach through `drivers/pci.zig` → ACPI →
//! port I/O, none portable. nic.zig now gates those imports behind a comptime
//! arch check, so on non-x86 it carries a driver-free no-op path.
//!
//! This probe compiles nic.zig into the non-x86 image and calls every facade
//! entry point, proving (a) it links with zero driver/PCI/ACPI dependency and
//! (b) the no-op contract holds: no NIC is active, MAC is all-zero, and TX/RX
//! safely report "nothing sent / nothing received" instead of faulting.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const nic = @import("../net/nic.zig");

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-50] nic facade non-x86 no-op: OK\n");
        return;
    }

    // No NIC driver is linked on non-x86 yet, so the facade must report idle.
    if (nic.isActive()) {
        arch.serial.writeString("[SK-50] FAILED: isActive true without driver\n");
        return;
    }

    const mac = nic.getMAC();
    for (mac) |b| {
        if (b != 0) {
            arch.serial.writeString("[SK-50] FAILED: nonzero MAC without driver\n");
            return;
        }
    }

    // TX must safely refuse (no NIC) rather than dispatch into absent drivers.
    var frame: [16]u8 = @splat(0xAA);
    if (nic.sendPacket(&frame, frame.len)) {
        arch.serial.writeString("[SK-50] FAILED: sendPacket claimed success\n");
        return;
    }

    // RX must report nothing pending.
    var rx: [16]u8 = undefined;
    if (nic.receivePacket(&rx, rx.len) != 0) {
        arch.serial.writeString("[SK-50] FAILED: receivePacket returned bytes\n");
        return;
    }

    arch.serial.writeString("[SK-50] nic facade non-x86 no-op: OK\n");
}
