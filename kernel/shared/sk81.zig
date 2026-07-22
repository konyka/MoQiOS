//! SK-81 — NDP stale→delay→probe unicast NUD on non-x86.
//!
//! SK-80 ages reachable→stale. First use of a stale neighbor must enter DELAY,
//! then PROBE with unicast NS (MAX_UNICAST_SOLICIT). This probe also locks the
//! pure unicast NS frame builder.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const ndp = @import("../net/ndp.zig");
const icmpv6 = @import("../net/icmpv6.zig");
const ipv6 = @import("../net/ipv6.zig");
const eth = @import("../net/eth.zig");

const IP: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x81,
};
const MAC = [6]u8{ 0x02, 0, 0, 0x81, 0x00, 0x01 };
const OUR_LL: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x01,
};
const OUR_MAC = [6]u8{ 0x52, 0x54, 0x00, 0xAA, 0xBB, 0xCC };

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-81] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

fn macEq(a: [6]u8, b: [6]u8) bool {
    for (a, 0..) |x, i| if (x != b[i]) return false;
    return true;
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-81] ndp delay probe unicast non-x86: OK\n");
        return;
    }

    // Pure unicast NS frame: L3/L2 destined to the neighbor.
    var frame: [128]u8 = @splat(0);
    const flen = icmpv6.buildNeighborSolicitationUnicast(&frame, OUR_LL, IP, OUR_MAC, MAC);
    if (flen != 54 + 32) {
        fail("frame len");
        return;
    }
    if (eth.parseEthertype(&frame) != eth.ETHERTYPE_IPV6) {
        fail("ethertype");
        return;
    }
    var eth_dst: [6]u8 = undefined;
    var eth_src: [6]u8 = undefined;
    @memcpy(&eth_dst, frame[0..6]);
    @memcpy(&eth_src, frame[6..12]);
    if (!macEq(eth_dst, MAC) or !macEq(eth_src, OUR_MAC)) {
        fail("eth macs");
        return;
    }
    const info = ipv6.parseHeader(frame[14..].ptr) orelse {
        fail("ipv6");
        return;
    };
    if (!ipv6.addrEq(info.dst_ip, IP) or info.next_header != ipv6.PROTO_ICMPV6) {
        fail("ipv6 dst");
        return;
    }
    if (frame[54] != 135) {
        fail("NS type");
        return;
    }

    // State machine: reachable → stale → delay → probe → drop.
    ndp.init();
    ndp.update(IP, MAC);
    var batch: [4]ndp.Solicit = undefined;
    _ = ndp.timerTick(ndp.REACHABLE_TIME_MS, &batch);
    if (ndp.probeState(IP) != .stale) {
        fail("stale");
        return;
    }

    _ = ndp.lookup(IP) orelse {
        fail("lookup");
        return;
    };
    if (ndp.probeState(IP) != .delay) {
        fail("delay");
        return;
    }

    if (ndp.timerTick(ndp.DELAY_FIRST_PROBE_TIME_MS - 1, &batch) != 0) {
        fail("early probe");
        return;
    }
    if (ndp.probeState(IP) != .delay) {
        fail("still delay");
        return;
    }

    // Enter probe + first unicast solicit.
    if (ndp.timerTick(1, &batch) != 1 or ndp.solicitIsMulticast(batch[0]) or
        !ipv6.addrEq(batch[0].target, IP) or !macEq(batch[0].dst_mac, MAC))
    {
        fail("probe solicit");
        return;
    }
    if (ndp.probeState(IP) != .probe or ndp.probeSolicitCount(IP) != 1) {
        fail("probe state");
        return;
    }

    // 2nd and 3rd unicast NS, then drop.
    if (ndp.timerTick(ndp.RETRANS_MS, &batch) != 1 or ndp.probeSolicitCount(IP) != 2) {
        fail("ucast 2");
        return;
    }
    if (ndp.timerTick(ndp.RETRANS_MS, &batch) != 1 or ndp.probeSolicitCount(IP) != 3) {
        fail("ucast 3");
        return;
    }
    if (ndp.timerTick(ndp.RETRANS_MS, &batch) != 0 or ndp.probeState(IP) != null) {
        fail("not dropped");
        return;
    }

    // NA during delay restores reachable.
    ndp.update(IP, MAC);
    _ = ndp.timerTick(ndp.REACHABLE_TIME_MS, &batch);
    _ = ndp.lookup(IP);
    if (ndp.probeState(IP) != .delay) {
        fail("delay2");
        return;
    }
    ndp.update(IP, MAC);
    if (ndp.probeState(IP) != .reachable) {
        fail("na refresh");
        return;
    }

    arch.serial.writeString("[SK-81] ndp delay probe unicast non-x86: OK\n");
}
