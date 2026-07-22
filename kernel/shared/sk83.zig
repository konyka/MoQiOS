//! SK-83 — RA Prefix Information → on-link prefix table on non-x86.
//!
//! SK-82 learned a default router but ignored PIO. This probe locks
//! `ipv6.prefixMatch`, RA prefix parse, and `ndp.isOnLink`.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const ndp = @import("../net/ndp.zig");
const icmpv6 = @import("../net/icmpv6.zig");
const ipv6 = @import("../net/ipv6.zig");
const bo = @import("../lib/byte_order.zig");

const RTR_LL: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x83,
};
const OUR_LL: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x01,
};
const PREFIX: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
};
const ON_LINK: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x01,
};
const OFF_LINK: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 1, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x01,
};

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-83] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-83] ndp prefix on-link non-x86: OK\n");
        return;
    }

    // prefixMatch edge cases.
    if (!ipv6.prefixMatch(ON_LINK, PREFIX, 64) or ipv6.prefixMatch(OFF_LINK, PREFIX, 64)) {
        fail("prefixMatch /64");
        return;
    }
    if (!ipv6.prefixMatch(ON_LINK, PREFIX, 0)) {
        fail("prefixMatch /0");
        return;
    }
    // /56: first 7 bytes of 2001:db8:0:: vs 2001:db8:1:: differ at byte 5.
    if (ipv6.prefixMatch(OFF_LINK, PREFIX, 56)) {
        fail("prefixMatch /56");
        return;
    }

    // RA = 16-byte header + 32-byte PIO (type=3,len=4).
    var ra: [48]u8 = @splat(0);
    ra[0] = 134;
    ra[4] = 64;
    bo.writeU16BeAt(&ra, 6, 1800);
    ra[16] = 3; // Prefix Information
    ra[17] = 4; // 32 bytes
    ra[18] = 64; // prefix length
    ra[19] = 0xC0; // L|A
    bo.writeU32BeAt(&ra, 20, 3600); // valid lifetime
    bo.writeU32BeAt(&ra, 24, 1800); // preferred
    @memcpy(ra[32..48], &PREFIX);

    const parsed = icmpv6.parseRouterAdvertisement(&ra, 48) orelse {
        fail("parse");
        return;
    };
    if (parsed.prefix_count != 1 or parsed.prefixes[0].prefix_len != 64 or
        !parsed.prefixes[0].on_link or !parsed.prefixes[0].autonomous or
        parsed.prefixes[0].valid_lifetime != 3600 or
        !ipv6.addrEq(parsed.prefixes[0].prefix, PREFIX))
    {
        fail("pio fields");
        return;
    }

    ndp.init();
    var pkt: [48]u8 = ra;
    pkt[2] = 0;
    pkt[3] = 0;
    const csum = icmpv6.checksum(RTR_LL, OUR_LL, &pkt, 48);
    bo.writeU16BeAt(&pkt, 2, csum);
    icmpv6.handlePacket(RTR_LL, OUR_LL, &pkt, 48);

    if (ndp.probePrefixCount() != 1) {
        fail("prefix count");
        return;
    }
    if (!ndp.isOnLink(ON_LINK) or ndp.isOnLink(OFF_LINK)) {
        fail("on-link");
        return;
    }
    if (!ndp.isOnLink(OUR_LL)) {
        fail("link-local on-link");
        return;
    }

    // valid_lifetime 0 removes the prefix.
    var ra0: [48]u8 = ra;
    bo.writeU32BeAt(&ra0, 20, 0);
    ra0[2] = 0;
    ra0[3] = 0;
    const csum0 = icmpv6.checksum(RTR_LL, OUR_LL, &ra0, 48);
    bo.writeU16BeAt(&ra0, 2, csum0);
    icmpv6.handlePacket(RTR_LL, OUR_LL, &ra0, 48);
    if (ndp.probePrefixCount() != 0 or ndp.isOnLink(ON_LINK)) {
        fail("prefix clear");
        return;
    }

    arch.serial.writeString("[SK-83] ndp prefix on-link non-x86: OK\n");
}
