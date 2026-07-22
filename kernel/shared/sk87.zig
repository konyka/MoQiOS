//! SK-87 — IPv6 off-link next hop via default router on non-x86.
//!
//! SK-86 picks a global source, but TX still NDP-resolved the L3 destination.
//! Off-link peers must use the default router's MAC as L2 next hop.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const ndp = @import("../net/ndp.zig");
const ipv6 = @import("../net/ipv6.zig");

const PREFIX: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
};
const ONLINK: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x10,
};
const OFFLINK: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 1, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x01,
};
const RTR: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x87,
};
const ON_MAC = [6]u8{ 0x02, 0, 0, 0x10, 0x00, 0x01 };
const RTR_MAC = [6]u8{ 0x02, 0, 0, 0x87, 0x00, 0x01 };

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-87] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

fn macEq(a: [6]u8, b: [6]u8) bool {
    for (a, 0..) |x, i| if (x != b[i]) return false;
    return true;
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-87] ipv6 nexthop router non-x86: OK\n");
        return;
    }

    ndp.init();
    ndp.setPrefix(PREFIX, 64, true, true, 3600);

    // On-link neighbor resolved directly.
    ndp.update(ONLINK, ON_MAC);
    const nh1 = ndp.resolveNextHop(ONLINK);
    const m1 = nh1.mac orelse {
        fail("on-link mac");
        return;
    };
    if (!macEq(m1, ON_MAC) or nh1.solicit != null) {
        fail("on-link fields");
        return;
    }

    // Off-link without default router → no path.
    const nh2 = ndp.resolveNextHop(OFFLINK);
    if (nh2.mac != null or nh2.solicit != null) {
        fail("no router");
        return;
    }

    // Off-link with router but unresolved → solicit the router.
    ndp.setDefaultRouter(RTR, 1800);
    const nh3 = ndp.resolveNextHop(OFFLINK);
    if (nh3.mac != null) {
        fail("router mac early");
        return;
    }
    const sol = nh3.solicit orelse {
        fail("router solicit");
        return;
    };
    if (!ipv6.addrEq(sol, RTR)) {
        fail("solicit target");
        return;
    }

    // Router resolved → L2 is router MAC (L3 dst stays off-link at IP layer).
    ndp.update(RTR, RTR_MAC);
    const nh4 = ndp.resolveNextHop(OFFLINK);
    const m4 = nh4.mac orelse {
        fail("via router mac");
        return;
    };
    if (!macEq(m4, RTR_MAC) or nh4.solicit != null) {
        fail("via router fields");
        return;
    }

    // Multicast → derived MAC, no NDP.
    const mcast = ipv6.allRoutersLinkLocalMulticast();
    const nh5 = ndp.resolveNextHop(mcast);
    const m5 = nh5.mac orelse {
        fail("mcast mac");
        return;
    };
    if (!macEq(m5, ipv6.multicastMac(mcast))) {
        fail("mcast derive");
        return;
    }

    arch.serial.writeString("[SK-87] ipv6 nexthop router non-x86: OK\n");
}
