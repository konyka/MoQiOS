//! SK-91 — SLAAC Preferred Lifetime aging / address deprecation (non-x86).
//!
//! PIO Preferred Lifetime was parsed but unused. Addresses stayed preferred
//! forever after DAD. Preferred Lifetime now ages; at zero the address becomes
//! deprecated (still valid for RX, skipped by selectSourceAddress). A later
//! RA refresh can restore preferred.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const ndp = @import("../net/ndp.zig");
const icmpv6 = @import("../net/icmpv6.zig");
const ipv6 = @import("../net/ipv6.zig");
const netif = @import("../net/netif.zig");

const PREFIX: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
};
const DST: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x99,
};
const MAC = [6]u8{ 0x52, 0x54, 0x00, 0x91, 0x00, 0x01 };

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-91] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

fn promotePreferred(addr: [16]u8) bool {
    var out: [1][16]u8 = undefined;
    _ = ndp.dadTimerTick(ndp.RETRANS_MS, &out);
    return ndp.probeAddrState(addr) == .preferred;
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-91] ndp preferred lifetime aging non-x86: OK\n");
        return;
    }

    netif.ensureInit();
    ndp.init();

    const addr = ndp.formSlaacAddress(PREFIX, MAC);
    _ = ndp.installSlaac(PREFIX, 64, 10, 2, MAC);
    if (!promotePreferred(addr)) {
        fail("dad");
        return;
    }
    if (ndp.probePreferredLifetime(addr) != 2) {
        fail("pref lifetime");
        return;
    }

    // Sub-second: unchanged.
    ndp.preferredLifetimeTimerTick(999);
    if (ndp.probePreferredLifetime(addr) != 2 or ndp.probeAddrState(addr) != .preferred) {
        fail("subsec");
        return;
    }

    ndp.preferredLifetimeTimerTick(1);
    if (ndp.probePreferredLifetime(addr) != 1) {
        fail("one sec");
        return;
    }

    // Expire preferred → deprecated; still local, not selected for TX.
    ndp.preferredLifetimeTimerTick(1000);
    if (ndp.probeAddrState(addr) != .deprecated or !ndp.hasLocalAddress(addr)) {
        fail("deprecate");
        return;
    }
    const ll = ndp.generateLinkLocal(MAC);
    if (!ipv6.addrEq(ndp.selectSourceAddress(DST, MAC), ll)) {
        fail("source skip");
        return;
    }

    // Refresh restores preferred.
    _ = ndp.installSlaac(PREFIX, 64, 10, 5, MAC);
    if (ndp.probeAddrState(addr) != .preferred or ndp.probePreferredLifetime(addr) != 5) {
        fail("refresh");
        return;
    }
    if (!ipv6.addrEq(ndp.selectSourceAddress(DST, MAC), addr)) {
        fail("source restore");
        return;
    }

    // Infinity does not age.
    _ = ndp.installSlaac(PREFIX, 64, ndp.PREFIX_LIFETIME_INFINITY, ndp.PREFIX_LIFETIME_INFINITY, MAC);
    ndp.preferredLifetimeTimerTick(5_000);
    if (ndp.probePreferredLifetime(addr) != ndp.PREFIX_LIFETIME_INFINITY or
        ndp.probeAddrState(addr) != .preferred)
    {
        fail("infinity");
        return;
    }

    // Full timer path.
    _ = ndp.installSlaac(PREFIX, 64, 10, 1, MAC);
    icmpv6.neighborTimerTick(1000);
    if (ndp.probeAddrState(addr) != .deprecated) {
        fail("tick deprecate");
        return;
    }

    arch.serial.writeString("[SK-91] ndp preferred lifetime aging non-x86: OK\n");
}
