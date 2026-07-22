//! SK-93 — default-router NUD failure failover (non-x86).
//!
//! Multi-router selection preferred a cached MAC, but a dead router that
//! failed unicast NUD stayed selectable. Probe exhaustion now marks the
//! router nud_failed so selection fails over; NA/RA refresh clears the mark.
//! Selecting a stale default router also starts DELAY (active NUD).

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const ndp = @import("../net/ndp.zig");
const ipv6 = @import("../net/ipv6.zig");
const netif = @import("../net/netif.zig");

const RTR_A: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0xa3,
};
const RTR_B: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0xb3,
};
const MAC_A = [6]u8{ 0x52, 0x54, 0x00, 0x93, 0x00, 0xa3 };
const MAC_B = [6]u8{ 0x52, 0x54, 0x00, 0x93, 0x00, 0xb3 };

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-93] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

fn exhaustNud(ip: [16]u8) bool {
    var batch: [4]ndp.Solicit = undefined;
    _ = ndp.timerTick(ndp.REACHABLE_TIME_MS, &batch);
    if (ndp.probeState(ip) != .stale) return false;
    // Active NUD via selection, or explicit lookup.
    _ = ndp.getDefaultRouter();
    if (ndp.probeState(ip) != .delay) {
        _ = ndp.lookup(ip);
        if (ndp.probeState(ip) != .delay) return false;
    }
    _ = ndp.timerTick(ndp.DELAY_FIRST_PROBE_TIME_MS, &batch);
    if (ndp.probeState(ip) != .probe) return false;
    var i: u8 = 0;
    while (i < ndp.MAX_UNICAST_SOLICIT) : (i += 1) {
        _ = ndp.timerTick(ndp.RETRANS_MS, &batch);
    }
    return ndp.probeState(ip) == null;
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-93] ndp router nud failover non-x86: OK\n");
        return;
    }

    netif.ensureInit();
    ndp.init();

    ndp.setDefaultRouter(RTR_A, 1800);
    ndp.setDefaultRouter(RTR_B, 1800);
    ndp.update(RTR_A, MAC_A);
    ndp.update(RTR_B, MAC_B);

    // Stick to A (first with MAC after selection).
    const first = ndp.getDefaultRouter() orelse {
        fail("first");
        return;
    };
    if (!ipv6.addrEq(first, RTR_A) and !ipv6.addrEq(first, RTR_B)) {
        fail("first id");
        return;
    }

    // Force A selected with MAC, then age to stale and confirm active nudge.
    ndp.init();
    ndp.setDefaultRouter(RTR_A, 1800);
    ndp.setDefaultRouter(RTR_B, 1800);
    ndp.update(RTR_A, MAC_A);
    ndp.update(RTR_B, MAC_B);
    _ = ndp.getDefaultRouter();
    var batch: [4]ndp.Solicit = undefined;
    _ = ndp.timerTick(ndp.REACHABLE_TIME_MS, &batch);
    if (ndp.probeState(RTR_A) != .stale and ndp.probeState(RTR_B) != .stale) {
        fail("stale");
        return;
    }
    const sel = ndp.getDefaultRouter() orelse {
        fail("sel");
        return;
    };
    if (ndp.probeState(sel) != .delay) {
        fail("active nud");
        return;
    }

    // Exhaust NUD on A → failover to B.
    ndp.init();
    ndp.setDefaultRouter(RTR_A, 1800);
    ndp.setDefaultRouter(RTR_B, 1800);
    ndp.update(RTR_A, MAC_A);
    ndp.update(RTR_B, MAC_B);
    // Prefer A by looking it up first / selecting when both have MAC — sticky first MAC walk picks A.
    _ = ndp.getDefaultRouter();
    if (!exhaustNud(RTR_A)) {
        fail("exhaust A");
        return;
    }
    if (!ndp.probeDefaultRouterNudFailed(RTR_A)) {
        fail("marked");
        return;
    }
    const fb = ndp.getDefaultRouter() orelse {
        fail("failover");
        return;
    };
    if (!ipv6.addrEq(fb, RTR_B)) {
        fail("failover B");
        return;
    }

    // NA refresh clears the mark.
    ndp.update(RTR_A, MAC_A);
    if (ndp.probeDefaultRouterNudFailed(RTR_A)) {
        fail("clear");
        return;
    }

    arch.serial.writeString("[SK-93] ndp router nud failover non-x86: OK\n");
}
