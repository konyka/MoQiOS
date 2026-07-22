//! SK-85 — SLAAC Duplicate Address Detection → preferred on non-x86.
//!
//! SK-84 installed addresses immediately. DAD requires a tentative period,
//! src=:: NS without SLLA, then preferred — or abandon on conflict.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const ndp = @import("../net/ndp.zig");
const icmpv6 = @import("../net/icmpv6.zig");
const ipv6 = @import("../net/ipv6.zig");
const eth = @import("../net/eth.zig");
const bo = @import("../lib/byte_order.zig");

const PREFIX: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
};
const MAC = [6]u8{ 0x52, 0x54, 0x00, 0x85, 0x00, 0x01 };
const PEER: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x99,
};

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-85] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-85] ndp slaac dad preferred non-x86: OK\n");
        return;
    }

    const target = ndp.formSlaacAddress(PREFIX, MAC);

    // Pure DAD NS: src=::, icmp len 24, no SLLA, solicited-node dest.
    var frame: [128]u8 = @splat(0);
    const flen = icmpv6.buildDadNeighborSolicitation(&frame, target, MAC);
    if (flen != 54 + 24) {
        fail("dad len");
        return;
    }
    if (eth.parseEthertype(&frame) != eth.ETHERTYPE_IPV6) {
        fail("ethertype");
        return;
    }
    const info = ipv6.parseHeader(frame[14..].ptr) orelse {
        fail("ipv6");
        return;
    };
    if (!ipv6.isUnspecified(info.src_ip)) {
        fail("dad src");
        return;
    }
    const sn = ipv6.solicitedNodeMulticast(target);
    if (!ipv6.addrEq(info.dst_ip, sn) or info.payload_len != 24) {
        fail("dad dst");
        return;
    }
    if (frame[54] != 135) {
        fail("dad type");
        return;
    }

    // Install → tentative; getGlobalAddress withheld.
    ndp.init();
    const t = ndp.installSlaac(PREFIX, 64, 3600, 1800, MAC) orelse {
        fail("install");
        return;
    };
    if (!ipv6.addrEq(t, target) or ndp.probeAddrState(target) != .tentative) {
        fail("tentative");
        return;
    }
    if (ndp.getGlobalAddress() != null) {
        fail("global early");
        return;
    }

    var out: [2][16]u8 = undefined;
    if (ndp.dadTimerTick(ndp.RETRANS_MS - 1, &out) != 0) {
        fail("early dad tick");
        return;
    }
    if (ndp.probeAddrState(target) != .tentative) {
        fail("still tentative");
        return;
    }

    // RetransTimer elapsed with DupAddrDetectTransmits=1 → preferred.
    _ = ndp.dadTimerTick(1, &out);
    if (ndp.probeAddrState(target) != .preferred) {
        fail("preferred");
        return;
    }
    const g = ndp.getGlobalAddress() orelse {
        fail("get global");
        return;
    };
    if (!ipv6.addrEq(g, target)) {
        fail("global addr");
        return;
    }

    // Conflict path: new tentative + foreign NS for same target.
    ndp.init();
    _ = ndp.installSlaac(PREFIX, 64, 3600, 1800, MAC);
    var ns: [24]u8 = @splat(0);
    ns[0] = 135;
    @memcpy(ns[8..24], &target);
    const csum = icmpv6.checksum(PEER, sn, &ns, 24);
    bo.writeU16BeAt(&ns, 2, csum);
    icmpv6.handlePacket(PEER, sn, &ns, 24);
    if (ndp.hasLocalAddress(target) or ndp.probeLocalAddrCount() != 0) {
        fail("conflict");
        return;
    }

    arch.serial.writeString("[SK-85] ndp slaac dad preferred non-x86: OK\n");
}
