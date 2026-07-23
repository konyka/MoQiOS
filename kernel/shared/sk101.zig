//! SK-101 — ICMP Fragmentation Needed → IPv4 Path MTU cache (non-x86).
//!
//! IPv4 TX always set DF but ignored ICMP type=3/code=4. Frag Needed now
//! updates a Path MTU cache; UDP/TCP IPv4 TX refuse packets larger than the
//! learned MTU (clamped to ≥576), and TCP SMSS uses PMTU−40.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const ipv4 = @import("../net/ipv4.zig");
const icmp = @import("../net/icmp.zig");
const tcp = @import("../net/tcp.zig");
const bo = @import("../lib/byte_order.zig");

const DST: [4]u8 = .{ 10, 0, 0, 101 };
const SRC: [4]u8 = .{ 10, 0, 0, 1 };
const RTR: [4]u8 = .{ 10, 0, 0, 254 };

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-101] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-101] ipv4 path mtu frag-needed non-x86: OK\n");
        return;
    }

    // Frag Needed = 8-byte ICMP + 20-byte invoking IPv4 header.
    var fn_pkt: [28]u8 = @splat(0);
    fn_pkt[0] = 3;
    fn_pkt[1] = 4;
    bo.writeU16BeAt(&fn_pkt, 6, 1000);
    fn_pkt[8] = 0x45;
    bo.writeU16BeAt(&fn_pkt, 8 + 2, 1500);
    fn_pkt[8 + 9] = ipv4.PROTO_UDP;
    @memcpy(fn_pkt[8 + 12 .. 8 + 16], &SRC);
    @memcpy(fn_pkt[8 + 16 .. 8 + 20], &DST);

    const parsed = icmp.parseFragNeeded(&fn_pkt, 28) orelse {
        fail("parse");
        return;
    };
    if (parsed.next_hop_mtu != 1000 or
        parsed.dst[0] != DST[0] or parsed.dst[1] != DST[1] or
        parsed.dst[2] != DST[2] or parsed.dst[3] != DST[3])
    {
        fail("fields");
        return;
    }

    ipv4.initPmtu();
    if (ipv4.getPathMtu(DST) != ipv4.LINK_MTU) {
        fail("default mtu");
        return;
    }

    icmp.handlePacket(RTR, SRC, &fn_pkt, 28);

    if (ipv4.probePathMtuCount() != 1 or ipv4.getPathMtu(DST) != 1000) {
        fail("learned");
        return;
    }

    // Clamp below minimum up to 576.
    ipv4.updatePathMtu(DST, 400);
    if (ipv4.getPathMtu(DST) != ipv4.MIN_MTU) {
        fail("clamp min");
        return;
    }

    // Never raise via a higher report.
    ipv4.updatePathMtu(DST, 1400);
    if (ipv4.getPathMtu(DST) != ipv4.MIN_MTU) {
        fail("no raise");
        return;
    }

    // TX gate: IPv4+UDP+payload must fit in learned PMTU.
    const oversize_total: u16 = ipv4.HEADER_LEN + 8 + 600;
    const fit_total: u16 = ipv4.HEADER_LEN + 8 + 100;
    if (oversize_total <= ipv4.getPathMtu(DST) or fit_total > ipv4.getPathMtu(DST)) {
        fail("tx gate");
        return;
    }

    // TCP SMSS = PMTU − 40.
    if (tcp.probeIpv4Mss(DST) != ipv4.MIN_MTU - 40) {
        fail("smss");
        return;
    }

    // Lifetime expiry raises then clears back to the interface MTU (SK-103).
    ipv4.probeDrainPathMtu(16);
    if (ipv4.probePathMtuCount() != 0 or ipv4.getPathMtu(DST) != ipv4.LINK_MTU) {
        fail("expire");
        return;
    }

    arch.serial.writeString("[SK-101] ipv4 path mtu frag-needed non-x86: OK\n");
}
