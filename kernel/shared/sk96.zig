//! SK-96 — invalidate Destination Cache when next-hop NUD fails (non-x86).
//!
//! Redirects installed a Destination Cache entry, but a later NUD failure on
//! that next hop left the redirect in place. Probe/incomplete exhaustion now
//! clears matching cache entries so resolveNextHop falls back to RIO/default.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const ndp = @import("../net/ndp.zig");

const RTR: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x96,
};
const BETTER: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0xb6,
};
const DST: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 9, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x96,
};
const RTR_MAC = [6]u8{ 0x52, 0x54, 0x00, 0x96, 0x00, 0xa6 };
const BETTER_MAC = [6]u8{ 0x52, 0x54, 0x00, 0x96, 0x00, 0xb6 };

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-96] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

fn macEq(a: [6]u8, b: [6]u8) bool {
    for (a, 0..) |x, i| if (x != b[i]) return false;
    return true;
}

fn exhaustNud(ip: [16]u8) bool {
    var batch: [4]ndp.Solicit = undefined;
    _ = ndp.timerTick(ndp.REACHABLE_TIME_MS, &batch);
    if (ndp.probeState(ip) != .stale) return false;
    _ = ndp.lookup(ip);
    if (ndp.probeState(ip) != .delay) return false;
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
        arch.serial.writeString("[SK-96] ndp redirect nud invalidate non-x86: OK\n");
        return;
    }

    ndp.init();
    ndp.setDefaultRouter(RTR, 1800);
    ndp.update(RTR, RTR_MAC);
    ndp.applyRedirect(DST, BETTER);
    ndp.update(BETTER, BETTER_MAC);

    const via = ndp.resolveNextHop(DST);
    const vm = via.mac orelse {
        fail("via better");
        return;
    };
    if (!macEq(vm, BETTER_MAC) or ndp.probeDestCacheCount() != 1) {
        fail("redirected");
        return;
    }

    // Unrelated NUD failure must not clear this redirect.
    const OTHER: [16]u8 = .{
        0xfe, 0x80, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0xee,
    };
    const OTHER_MAC = [6]u8{ 0x52, 0x54, 0x00, 0x96, 0x00, 0xee };
    ndp.update(OTHER, OTHER_MAC);
    if (!exhaustNud(OTHER) or ndp.probeDestCacheCount() != 1) {
        fail("unrelated");
        return;
    }

    // Next-hop NUD failure clears the Destination Cache entry.
    if (!exhaustNud(BETTER)) {
        fail("exhaust better");
        return;
    }
    if (ndp.probeDestCacheCount() != 0 or ndp.probeDestCacheNextHop(DST) != null) {
        fail("cleared");
        return;
    }

    const fb = ndp.resolveNextHop(DST);
    const fm = fb.mac orelse {
        fail("fallback mac");
        return;
    };
    if (!macEq(fm, RTR_MAC)) {
        fail("fallback rtr");
        return;
    }

    // On-link redirect (target == destination): clear when that neighbor dies.
    ndp.applyRedirect(DST, DST);
    ndp.update(DST, BETTER_MAC);
    if (ndp.probeDestCacheCount() != 1) {
        fail("onlink install");
        return;
    }
    if (!exhaustNud(DST)) {
        fail("exhaust dst");
        return;
    }
    if (ndp.probeDestCacheCount() != 0) {
        fail("onlink clear");
        return;
    }

    arch.serial.writeString("[SK-96] ndp redirect nud invalidate non-x86: OK\n");
}
