//! SK-89 — default-router Router Lifetime aging (non-x86).
//!
//! RA installs a Router Lifetime, but the host never decremented it.
//! Lifetime now ages on the NDP timer; at zero the default router is
//! cleared and router solicitation restarts.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const ndp = @import("../net/ndp.zig");
const icmpv6 = @import("../net/icmpv6.zig");
const netif = @import("../net/netif.zig");

const RTR: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x89,
};

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-89] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-89] ndp router lifetime aging non-x86: OK\n");
        return;
    }

    netif.ensureInit();
    ndp.init();
    icmpv6.stopRouterSolicit();

    ndp.setDefaultRouter(RTR, 2);
    if (ndp.probeDefaultRouterLifetime() != 2 or ndp.getDefaultRouter() == null) {
        fail("install");
        return;
    }

    // Sub-second: lifetime unchanged.
    if (ndp.routerLifetimeTimerTick(999)) {
        fail("subsec expire");
        return;
    }
    if (ndp.probeDefaultRouterLifetime() != 2) {
        fail("subsec lifetime");
        return;
    }

    // First whole second.
    if (ndp.routerLifetimeTimerTick(1)) {
        fail("early expire");
        return;
    }
    if (ndp.probeDefaultRouterLifetime() != 1 or ndp.getDefaultRouter() == null) {
        fail("one sec");
        return;
    }

    // Expire.
    if (!ndp.routerLifetimeTimerTick(1000)) {
        fail("no expire");
        return;
    }
    if (ndp.getDefaultRouter() != null or ndp.probeDefaultRouterLifetime() != 0) {
        fail("cleared");
        return;
    }

    // Refresh resets the age accumulator.
    ndp.setDefaultRouter(RTR, 5);
    _ = ndp.routerLifetimeTimerTick(500);
    ndp.setDefaultRouter(RTR, 5);
    _ = ndp.routerLifetimeTimerTick(500);
    if (ndp.probeDefaultRouterLifetime() != 5) {
        fail("refresh");
        return;
    }

    // Full timer path: expire restarts Router Solicitation.
    ndp.setDefaultRouter(RTR, 1);
    icmpv6.stopRouterSolicit();
    icmpv6.neighborTimerTick(1000);
    if (ndp.getDefaultRouter() != null) {
        fail("tick clear");
        return;
    }
    if (!icmpv6.probeRsActive() or icmpv6.probeRsSent() != 1) {
        fail("rs restart");
        return;
    }

    arch.serial.writeString("[SK-89] ndp router lifetime aging non-x86: OK\n");
}
