//! SK-60 — DNS resolver + DHCP client link on non-x86.
//!
//! Both `net/dns.zig` and `net/dhcp.zig` depend only on arch-clean modules
//! (udp/netif/byte_order) plus the portable serial/getTickCount facades; their
//! sole remaining x86-ism was a bare `asm volatile ("pause")` busy-wait hint,
//! now routed through `arch.cpu.pause()`. This probe forces analysis of every
//! public entry point on riscv64/aarch64 (DHCP DISCOVER/REQUEST build +
//! OFFER/ACK option parsing, DNS query encode + response parse + LRU/TTL
//! cache) and exercises the non-blocking read paths: resolving a dotted-decimal
//! literal (pure parse, no network) and the pre-config DHCP getters. The
//! network-waiting paths (queryDns / discover) are compile-verified only — they
//! poll getTickCount and must not be run from the boot probe.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const dns = @import("../net/dns.zig");
const dhcp = @import("../net/dhcp.zig");

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-60] dns/dhcp link non-x86: OK\n");
        return;
    }

    // Force full analysis of both modules on this arch.
    comptime {
        _ = &dns.resolve;
        _ = &dns.getDnsServer;
        _ = &dhcp.discover;
        _ = &dhcp.isConfigured;
        _ = &dhcp.getDnsServer;
        _ = &dhcp.getIp;
        _ = &dhcp.getGateway;
        _ = &dhcp.getNetmask;
    }

    // DNS: a dotted-decimal literal resolves through the pure isIpV4/parseIpV4
    // path with no network I/O.
    const lit = dns.resolve("10.0.2.15");
    if (!(lit[0] == 10 and lit[1] == 0 and lit[2] == 2 and lit[3] == 15)) {
        arch.serial.writeString("[SK-60] FAILED: dns literal parse\n");
        return;
    }

    // An empty / over-long name is rejected to all-zero.
    const bad = dns.resolve("");
    if (bad[0] != 0 or bad[1] != 0 or bad[2] != 0 or bad[3] != 0) {
        arch.serial.writeString("[SK-60] FAILED: dns empty not zero\n");
        return;
    }

    // With DHCP unconfigured, DNS server falls back to Google DNS.
    const srv = dns.getDnsServer();
    if (!(srv[0] == 8 and srv[1] == 8 and srv[2] == 8 and srv[3] == 8)) {
        arch.serial.writeString("[SK-60] FAILED: dns fallback server\n");
        return;
    }

    // DHCP: fresh state is unconfigured with all-zero acquired address and the
    // default /24 netmask baked into the module.
    if (dhcp.isConfigured()) {
        arch.serial.writeString("[SK-60] FAILED: dhcp preconfigured\n");
        return;
    }
    const ip = dhcp.getIp();
    if (ip[0] != 0 or ip[1] != 0 or ip[2] != 0 or ip[3] != 0) {
        arch.serial.writeString("[SK-60] FAILED: dhcp ip nonzero\n");
        return;
    }
    const mask = dhcp.getNetmask();
    if (!(mask[0] == 255 and mask[1] == 255 and mask[2] == 255 and mask[3] == 0)) {
        arch.serial.writeString("[SK-60] FAILED: dhcp default netmask\n");
        return;
    }

    arch.serial.writeString("[SK-60] dns/dhcp link non-x86: OK\n");
}
