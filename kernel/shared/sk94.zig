//! SK-94 — RA Route Information (RIO) → more-specific next hops (non-x86).
//!
//! Off-link TX always used the default router. RFC 4191 RIO now installs
//! prefix routes; resolveNextHop picks the longest match (then preference)
//! before falling back to the default router.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const ndp = @import("../net/ndp.zig");
const icmpv6 = @import("../net/icmpv6.zig");
const ipv6 = @import("../net/ipv6.zig");
const bo = @import("../lib/byte_order.zig");

const RTR_A: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0xa4,
};
const RTR_B: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0xb4,
};
const ROUTE_PFX: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 1, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
};
const DST: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 1, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x99,
};
const MAC_A = [6]u8{ 0x52, 0x54, 0x00, 0x94, 0x00, 0xa4 };
const MAC_B = [6]u8{ 0x52, 0x54, 0x00, 0x94, 0x00, 0xb4 };

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-94] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

fn macEq(a: [6]u8, b: [6]u8) bool {
    for (a, 0..) |x, i| if (x != b[i]) return false;
    return true;
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-94] ndp route info rio non-x86: OK\n");
        return;
    }

    // RA = 16-byte header + 16-byte RIO (type=24,len=2, /48, medium, life=3600).
    var ra: [32]u8 = @splat(0);
    ra[0] = 134;
    bo.writeU16BeAt(&ra, 6, 1800);
    ra[16] = 24; // Route Information
    ra[17] = 2; // 16 bytes
    ra[18] = 48; // prefix length
    ra[19] = 0x00; // Prf=medium (bits 4-3 = 00)
    bo.writeU32BeAt(&ra, 20, 3600);
    @memcpy(ra[24..32], ROUTE_PFX[0..8]);

    const parsed = icmpv6.parseRouterAdvertisement(&ra, 32) orelse {
        fail("parse");
        return;
    };
    if (parsed.route_count != 1 or parsed.routes[0].prefix_len != 48 or
        parsed.routes[0].preference != 0 or parsed.routes[0].lifetime_sec != 3600 or
        !ipv6.prefixMatch(parsed.routes[0].prefix, ROUTE_PFX, 48))
    {
        fail("rio fields");
        return;
    }

    // High preference encoding (Prf=01 → bits 4-3).
    ra[19] = 0x08;
    const hi = icmpv6.parseRouterAdvertisement(&ra, 32) orelse {
        fail("parse hi");
        return;
    };
    if (hi.routes[0].preference != 1) {
        fail("pref high");
        return;
    }

    ndp.init();
    ndp.setDefaultRouter(RTR_A, 1800);
    ndp.update(RTR_A, MAC_A);
    ndp.setRoute(ROUTE_PFX, 48, 2, 0, RTR_B);
    ndp.update(RTR_B, MAC_B);

    if (ndp.probeRouteCount() != 1) {
        fail("count");
        return;
    }
    const nh_ip = ndp.probeBestRouteNextHop(DST) orelse {
        fail("best");
        return;
    };
    if (!ipv6.addrEq(nh_ip, RTR_B)) {
        fail("best nh");
        return;
    }

    const nh = ndp.resolveNextHop(DST);
    const m = nh.mac orelse {
        fail("rio mac");
        return;
    };
    if (!macEq(m, MAC_B) or nh.solicit != null) {
        fail("rio via B");
        return;
    }

    // Preference: same /48, higher Prf wins.
    const RTR_C: [16]u8 = .{
        0xfe, 0x80, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0xc4,
    };
    ndp.setRoute(ROUTE_PFX, 48, 3600, 1, RTR_C);
    const prefer = ndp.probeBestRouteNextHop(DST) orelse {
        fail("pref route");
        return;
    };
    if (!ipv6.addrEq(prefer, RTR_C)) {
        fail("pref C");
        return;
    }

    // Lifetime expiry → fall back to default router A.
    ndp.init();
    ndp.setDefaultRouter(RTR_A, 1800);
    ndp.update(RTR_A, MAC_A);
    ndp.setRoute(ROUTE_PFX, 48, 1, 0, RTR_B);
    ndp.update(RTR_B, MAC_B);
    ndp.routeLifetimeTimerTick(1000);
    if (ndp.probeRouteCount() != 0) {
        fail("expire");
        return;
    }
    const fb = ndp.resolveNextHop(DST);
    const fm = fb.mac orelse {
        fail("fallback mac");
        return;
    };
    if (!macEq(fm, MAC_A)) {
        fail("fallback A");
        return;
    }

    arch.serial.writeString("[SK-94] ndp route info rio non-x86: OK\n");
}
