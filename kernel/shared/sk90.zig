//! SK-90 — Prefix Information Valid Lifetime aging (non-x86).
//!
//! RA prefixes stored a Valid Lifetime but never decremented it, so expired
//! on-link prefixes and SLAAC addresses lingered. Lifetime now ages on the
//! NDP timer; at zero the prefix and matching SLAAC addresses are cleared.
//! 0xffffffff (infinity) is not aged.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const ndp = @import("../net/ndp.zig");
const icmpv6 = @import("../net/icmpv6.zig");
const netif = @import("../net/netif.zig");

const PREFIX: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
};
const ON_LINK: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x01,
};
const MAC = [6]u8{ 0x52, 0x54, 0x00, 0x90, 0x00, 0x01 };

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-90] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-90] ndp prefix lifetime aging non-x86: OK\n");
        return;
    }

    netif.ensureInit();
    ndp.init();

    ndp.setPrefix(PREFIX, 64, true, true, 2);
    _ = ndp.installSlaac(PREFIX, 64, 2, 2, MAC);
    if (ndp.probePrefixLifetime(PREFIX, 64) != 2 or !ndp.isOnLink(ON_LINK) or
        ndp.probeLocalAddrCount() != 1)
    {
        fail("install");
        return;
    }

    // Sub-second: unchanged.
    ndp.prefixLifetimeTimerTick(999);
    if (ndp.probePrefixLifetime(PREFIX, 64) != 2) {
        fail("subsec");
        return;
    }

    ndp.prefixLifetimeTimerTick(1);
    if (ndp.probePrefixLifetime(PREFIX, 64) != 1 or !ndp.isOnLink(ON_LINK)) {
        fail("one sec");
        return;
    }

    // Expire: prefix + SLAAC gone.
    ndp.prefixLifetimeTimerTick(1000);
    if (ndp.probePrefixCount() != 0 or ndp.probePrefixLifetime(PREFIX, 64) != 0 or
        ndp.isOnLink(ON_LINK) or ndp.probeLocalAddrCount() != 0)
    {
        fail("expire");
        return;
    }

    // Refresh resets age.
    ndp.setPrefix(PREFIX, 64, true, false, 5);
    ndp.prefixLifetimeTimerTick(500);
    ndp.setPrefix(PREFIX, 64, true, false, 5);
    ndp.prefixLifetimeTimerTick(500);
    if (ndp.probePrefixLifetime(PREFIX, 64) != 5) {
        fail("refresh");
        return;
    }

    // Infinity does not age.
    ndp.setPrefix(PREFIX, 64, true, false, ndp.PREFIX_LIFETIME_INFINITY);
    ndp.prefixLifetimeTimerTick(5_000);
    if (ndp.probePrefixLifetime(PREFIX, 64) != ndp.PREFIX_LIFETIME_INFINITY) {
        fail("infinity");
        return;
    }

    // Full timer path ages prefixes.
    ndp.setPrefix(PREFIX, 64, true, false, 1);
    icmpv6.neighborTimerTick(1000);
    if (ndp.probePrefixCount() != 0 or ndp.isOnLink(ON_LINK)) {
        fail("tick clear");
        return;
    }

    arch.serial.writeString("[SK-90] ndp prefix lifetime aging non-x86: OK\n");
}
