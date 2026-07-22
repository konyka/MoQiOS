//! SK-84 — SLAAC from A-flag /64 Prefix Information on non-x86.
//!
//! SK-83 stored on-link prefixes but did not form addresses. This probe locks
//! `formSlaacAddress` (prefix || EUI-64) and RA-driven `installSlaac`.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const ndp = @import("../net/ndp.zig");
const icmpv6 = @import("../net/icmpv6.zig");
const ipv6 = @import("../net/ipv6.zig");
const netif = @import("../net/netif.zig");
const bo = @import("../lib/byte_order.zig");

const RTR_LL: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x84,
};
const OUR_LL: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x01,
};
const PREFIX: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
};
const MAC = [6]u8{ 0x52, 0x54, 0x00, 0xAA, 0xBB, 0xCC };

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-84] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-84] ndp slaac address non-x86: OK\n");
        return;
    }

    // Pure form: prefix[0..8] || modified-EUI-64 from MAC.
    const formed = ndp.formSlaacAddress(PREFIX, MAC);
    const ll = ndp.generateLinkLocal(MAC);
    if (!ipv6.prefixMatch(formed, PREFIX, 64)) {
        fail("formed prefix");
        return;
    }
    var i: usize = 8;
    while (i < 16) : (i += 1) {
        if (formed[i] != ll[i]) {
            fail("formed iid");
            return;
        }
    }
    if (ipv6.isLinkLocal(formed)) {
        fail("global");
        return;
    }

    // Non-/64 ignored.
    ndp.init();
    _ = ndp.installSlaac(PREFIX, 48, 3600, 1800, MAC);
    if (ndp.probeLocalAddrCount() != 0) {
        fail("non-/64");
        return;
    }

    // RA with A-flag installs using the NIC MAC.
    var ra: [48]u8 = @splat(0);
    ra[0] = 134;
    ra[4] = 64;
    bo.writeU16BeAt(&ra, 6, 1800);
    ra[16] = 3;
    ra[17] = 4;
    ra[18] = 64;
    ra[19] = 0xC0; // L|A
    bo.writeU32BeAt(&ra, 20, 3600);
    bo.writeU32BeAt(&ra, 24, 1800);
    @memcpy(ra[32..48], &PREFIX);

    netif.ensureInit();
    const nic_mac = netif.getMac();
    const expect = ndp.formSlaacAddress(PREFIX, nic_mac);

    var pkt: [48]u8 = ra;
    const csum = icmpv6.checksum(RTR_LL, OUR_LL, &pkt, 48);
    bo.writeU16BeAt(&pkt, 2, csum);
    icmpv6.handlePacket(RTR_LL, OUR_LL, &pkt, 48);

    if (ndp.probeLocalAddrCount() != 1 or !ndp.hasLocalAddress(expect)) {
        fail("install");
        return;
    }
    // SK-85: address stays tentative until DAD RetransTimer elapses.
    var dad_out: [1][16]u8 = undefined;
    _ = ndp.dadTimerTick(ndp.RETRANS_MS, &dad_out);
    const got = ndp.getGlobalAddress() orelse {
        fail("get global");
        return;
    };
    if (!ipv6.addrEq(got, expect)) {
        fail("global addr");
        return;
    }

    // Lifetime 0 removes the SLAAC address.
    var ra0: [48]u8 = ra;
    bo.writeU32BeAt(&ra0, 20, 0);
    ra0[2] = 0;
    ra0[3] = 0;
    const csum0 = icmpv6.checksum(RTR_LL, OUR_LL, &ra0, 48);
    bo.writeU16BeAt(&ra0, 2, csum0);
    icmpv6.handlePacket(RTR_LL, OUR_LL, &ra0, 48);
    if (ndp.probeLocalAddrCount() != 0 or ndp.hasLocalAddress(expect)) {
        fail("remove");
        return;
    }

    arch.serial.writeString("[SK-84] ndp slaac address non-x86: OK\n");
}
