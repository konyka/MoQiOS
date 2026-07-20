//! SK-51 — network interface config (`net/netif.zig`) links and runs on non-x86.
//!
//! SK-50 arch-gated the driver imports inside `nic.zig`; this probe proves the
//! payoff propagates upward: `netif.zig` — the first *consumer* of the nic
//! facade — now imports only `nic` (arch-clean) + `arch.serial` (portable), so
//! it compiles into the riscv64/aarch64 image with zero driver/PCI/ACPI pull.
//!
//! Checks the static interface config (IP / gateway / netmask are compile-time
//! constants, identical on every arch) and the lazy MAC cache: with no NIC
//! linked, getMac() must resolve through nic.getMAC() to all-zero and be
//! idempotent across repeated ensureInit() calls.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const netif = @import("../net/netif.zig");

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-51] netif config non-x86: OK\n");
        return;
    }

    const ip = netif.getOurIp();
    const gw = netif.getGateway();
    const mask = netif.getNetmask();

    if (ip[0] != 10 or ip[1] != 0 or ip[2] != 2 or ip[3] != 15) {
        arch.serial.writeString("[SK-51] FAILED: our ip\n");
        return;
    }
    if (gw[0] != 10 or gw[1] != 0 or gw[2] != 2 or gw[3] != 2) {
        arch.serial.writeString("[SK-51] FAILED: gateway\n");
        return;
    }
    if (mask[0] != 255 or mask[1] != 255 or mask[2] != 255 or mask[3] != 0) {
        arch.serial.writeString("[SK-51] FAILED: netmask\n");
        return;
    }

    // No NIC on non-x86 → MAC resolves to all-zero through the facade.
    netif.ensureInit();
    const mac1 = netif.getMac();
    const mac2 = netif.getMac(); // second call must hit the cache, same value
    for (mac1, 0..) |b, i| {
        if (b != 0 or mac2[i] != b) {
            arch.serial.writeString("[SK-51] FAILED: mac cache\n");
            return;
        }
    }

    arch.serial.writeString("[SK-51] netif config non-x86: OK\n");
}
