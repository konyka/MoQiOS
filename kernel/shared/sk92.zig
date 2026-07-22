//! SK-92 — multi default-router list and selection (non-x86).
//!
//! Only one default router was kept, so a second RA replaced the first.
//! Hosts now keep a small list, prefer a router with a cached neighbor MAC,
//! and fall back to another entry when one is removed or expires.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const ndp = @import("../net/ndp.zig");
const icmpv6 = @import("../net/icmpv6.zig");
const ipv6 = @import("../net/ipv6.zig");
const netif = @import("../net/netif.zig");

const RTR_A: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0xa1,
};
const RTR_B: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0xb2,
};
const MAC_B = [6]u8{ 0x52, 0x54, 0x00, 0x92, 0x00, 0xb2 };

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-92] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-92] ndp multi default router non-x86: OK\n");
        return;
    }

    netif.ensureInit();
    ndp.init();
    icmpv6.stopRouterSolicit();

    ndp.setDefaultRouter(RTR_A, 1800);
    ndp.setDefaultRouter(RTR_B, 1800);
    if (ndp.probeDefaultRouterCount() != 2) {
        fail("count");
        return;
    }

    // Sticky first selection while neither has a neighbor MAC.
    const first = ndp.getDefaultRouter() orelse {
        fail("first");
        return;
    };
    if (!ipv6.addrEq(first, RTR_A) and !ipv6.addrEq(first, RTR_B)) {
        fail("first id");
        return;
    }
    const again = ndp.getDefaultRouter() orelse {
        fail("sticky");
        return;
    };
    if (!ipv6.addrEq(again, first)) {
        fail("sticky eq");
        return;
    }

    // Prefer the router with a resolved neighbor MAC.
    ndp.update(RTR_B, MAC_B);
    const pref = ndp.getDefaultRouter() orelse {
        fail("prefer");
        return;
    };
    if (!ipv6.addrEq(pref, RTR_B)) {
        fail("prefer B");
        return;
    }

    // Remove B; fall back to A.
    ndp.setDefaultRouter(RTR_B, 0);
    if (ndp.probeDefaultRouterCount() != 1) {
        fail("remove count");
        return;
    }
    const only_a = ndp.getDefaultRouter() orelse {
        fail("only A");
        return;
    };
    if (!ipv6.addrEq(only_a, RTR_A)) {
        fail("fallback A");
        return;
    }

    // Partial expiry: one router left → no RS restart.
    ndp.init();
    ndp.setDefaultRouter(RTR_A, 1);
    ndp.setDefaultRouter(RTR_B, 5);
    if (ndp.routerLifetimeTimerTick(1000)) {
        fail("partial expire");
        return;
    }
    if (ndp.probeDefaultRouterCount() != 1) {
        fail("partial count");
        return;
    }
    const left = ndp.getDefaultRouter() orelse {
        fail("left");
        return;
    };
    if (!ipv6.addrEq(left, RTR_B)) {
        fail("left B");
        return;
    }

    // Last router expires → restart RS via neighborTimerTick.
    icmpv6.stopRouterSolicit();
    icmpv6.neighborTimerTick(5_000);
    if (ndp.probeDefaultRouterCount() != 0 or ndp.getDefaultRouter() != null) {
        fail("empty");
        return;
    }
    if (!icmpv6.probeRsActive() or icmpv6.probeRsSent() != 1) {
        fail("rs restart");
        return;
    }

    arch.serial.writeString("[SK-92] ndp multi default router non-x86: OK\n");
}
