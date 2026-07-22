//! SK-88 — automatic Router Solicitation on bring-up (non-x86).
//!
//! RS/RA parsing existed (SK-82) but hosts never solicited unless called by
//! hand. Discovery now starts at net.init and retries up to
//! MAX_RTR_SOLICITATIONS, stopping early when a default router appears.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const ndp = @import("../net/ndp.zig");
const icmpv6 = @import("../net/icmpv6.zig");
const netif = @import("../net/netif.zig");

const RTR: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x88,
};

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-88] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-88] ndp auto router solicit non-x86: OK\n");
        return;
    }

    netif.ensureInit();
    ndp.init();
    icmpv6.stopRouterSolicit();

    icmpv6.startRouterSolicit();
    if (!icmpv6.probeRsActive() or icmpv6.probeRsSent() != 1) {
        fail("start");
        return;
    }

    // Sub-interval: no additional RS.
    icmpv6.routerSolicitTimerTick(icmpv6.RTR_SOLICITATION_INTERVAL_MS - 1);
    if (icmpv6.probeRsSent() != 1 or !icmpv6.probeRsActive()) {
        fail("early retransmit");
        return;
    }

    // Second and third solicits, then idle.
    icmpv6.routerSolicitTimerTick(1);
    if (icmpv6.probeRsSent() != 2 or !icmpv6.probeRsActive()) {
        fail("second");
        return;
    }
    icmpv6.routerSolicitTimerTick(icmpv6.RTR_SOLICITATION_INTERVAL_MS);
    if (icmpv6.probeRsSent() != 3 or icmpv6.probeRsActive()) {
        fail("exhausted");
        return;
    }

    // RA with lifetime stops discovery early.
    icmpv6.startRouterSolicit();
    if (icmpv6.probeRsSent() != 1) {
        fail("restart");
        return;
    }
    ndp.setDefaultRouter(RTR, 1800);
    icmpv6.routerSolicitTimerTick(icmpv6.RTR_SOLICITATION_INTERVAL_MS);
    if (icmpv6.probeRsActive() or icmpv6.probeRsSent() != 1) {
        fail("stop on router");
        return;
    }

    // Direct stopRouterSolicit (RA path).
    icmpv6.startRouterSolicit();
    icmpv6.stopRouterSolicit();
    if (icmpv6.probeRsActive()) {
        fail("stop");
        return;
    }

    arch.serial.writeString("[SK-88] ndp auto router solicit non-x86: OK\n");
}
