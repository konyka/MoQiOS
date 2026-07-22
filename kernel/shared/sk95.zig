//! SK-95 — ICMPv6 Redirect → Destination Cache (non-x86).
//!
//! Routers may redirect hosts to a better first hop. Redirects were ignored,
//! so traffic kept using the default/RIO next hop. Valid Redirects now update
//! the Destination Cache; resolveNextHop consults it first.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const ndp = @import("../net/ndp.zig");
const icmpv6 = @import("../net/icmpv6.zig");
const ipv6 = @import("../net/ipv6.zig");
const bo = @import("../lib/byte_order.zig");

const RTR: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x95,
};
const BETTER: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0xb5,
};
const DST: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 9, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x01,
};
const OUR_LL: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x01,
};
const RTR_MAC = [6]u8{ 0x52, 0x54, 0x00, 0x95, 0x00, 0xa5 };
const BETTER_MAC = [6]u8{ 0x52, 0x54, 0x00, 0x95, 0x00, 0xb5 };

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-95] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

fn macEq(a: [6]u8, b: [6]u8) bool {
    for (a, 0..) |x, i| if (x != b[i]) return false;
    return true;
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-95] ndp icmpv6 redirect non-x86: OK\n");
        return;
    }

    // Redirect body + Target LL option (8 bytes) = 48.
    var redir: [48]u8 = @splat(0);
    redir[0] = 137;
    @memcpy(redir[8..24], &BETTER);
    @memcpy(redir[24..40], &DST);
    redir[40] = 2; // Target LL
    redir[41] = 1;
    @memcpy(redir[42..48], &BETTER_MAC);

    const parsed = icmpv6.parseRedirect(&redir, 48) orelse {
        fail("parse");
        return;
    };
    if (!ipv6.addrEq(parsed.target, BETTER) or !ipv6.addrEq(parsed.destination, DST)) {
        fail("fields");
        return;
    }
    const tll = parsed.target_ll orelse {
        fail("tlla");
        return;
    };
    if (!macEq(tll, BETTER_MAC)) {
        fail("tlla mac");
        return;
    }

    ndp.init();
    ndp.setDefaultRouter(RTR, 1800);
    ndp.update(RTR, RTR_MAC);

    // Without redirect: via default router.
    const before = ndp.resolveNextHop(DST);
    const bm = before.mac orelse {
        fail("before mac");
        return;
    };
    if (!macEq(bm, RTR_MAC)) {
        fail("before rtr");
        return;
    }

    // Apply via RX path (checksummed).
    var pkt = redir;
    pkt[2] = 0;
    pkt[3] = 0;
    const csum = icmpv6.checksum(RTR, OUR_LL, &pkt, 48);
    bo.writeU16BeAt(&pkt, 2, csum);
    icmpv6.handlePacket(RTR, OUR_LL, &pkt, 48);

    if (ndp.probeDestCacheCount() != 1) {
        fail("cache count");
        return;
    }
    const cached = ndp.probeDestCacheNextHop(DST) orelse {
        fail("cache nh");
        return;
    };
    if (!ipv6.addrEq(cached, BETTER)) {
        fail("cache better");
        return;
    }

    const after = ndp.resolveNextHop(DST);
    const am = after.mac orelse {
        fail("after mac");
        return;
    };
    if (!macEq(am, BETTER_MAC) or after.solicit != null) {
        fail("after better");
        return;
    }

    // Spoofed redirect from non-first-hop must be ignored.
    ndp.init();
    ndp.setDefaultRouter(RTR, 1800);
    const SPOOF: [16]u8 = .{
        0xfe, 0x80, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0xee,
    };
    var bad = redir;
    bad[2] = 0;
    bad[3] = 0;
    const csum_bad = icmpv6.checksum(SPOOF, OUR_LL, &bad, 48);
    bo.writeU16BeAt(&bad, 2, csum_bad);
    icmpv6.handlePacket(SPOOF, OUR_LL, &bad, 48);
    if (ndp.probeDestCacheCount() != 0) {
        fail("spoof");
        return;
    }

    // Lifetime expiry clears the cache entry.
    ndp.applyRedirect(DST, BETTER);
    ndp.destCacheTimerTick(ndp.REDIRECT_LIFETIME_SEC * 1000);
    if (ndp.probeDestCacheCount() != 0 or ndp.probeDestCacheNextHop(DST) != null) {
        fail("expire");
        return;
    }

    arch.serial.writeString("[SK-95] ndp icmpv6 redirect non-x86: OK\n");
}
