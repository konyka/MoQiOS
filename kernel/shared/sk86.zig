//! SK-86 — IPv6 source address selection (preferred global) on non-x86.
//!
//! SK-85 only exposes preferred addresses via getGlobalAddress. TX still always
//! used link-local. This probe locks `selectSourceAddress`: LL for LL dests,
//! same-/64 preferred global when available, else any preferred global.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const ndp = @import("../net/ndp.zig");
const ipv6 = @import("../net/ipv6.zig");

const PREFIX: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
};
const MAC = [6]u8{ 0x52, 0x54, 0x00, 0x86, 0x00, 0x01 };
const DST_ONLINK: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x99,
};
const DST_OFFLINK: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 1, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x01,
};
const DST_LL: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x02,
};

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-86] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-86] ipv6 source select non-x86: OK\n");
        return;
    }

    ndp.init();
    const ll = ndp.generateLinkLocal(MAC);

    // No global yet → always link-local.
    if (!ipv6.addrEq(ndp.selectSourceAddress(DST_ONLINK, MAC), ll) or
        !ipv6.addrEq(ndp.selectSourceAddress(DST_LL, MAC), ll))
    {
        fail("fallback ll");
        return;
    }

    // Install + complete DAD → preferred global.
    _ = ndp.installSlaac(PREFIX, 64, 3600, MAC);
    var dad_out: [1][16]u8 = undefined;
    _ = ndp.dadTimerTick(ndp.RETRANS_MS, &dad_out);
    const global = ndp.formSlaacAddress(PREFIX, MAC);
    if (ndp.probeAddrState(global) != .preferred) {
        fail("not preferred");
        return;
    }

    // Link-local destination still uses LL source.
    if (!ipv6.addrEq(ndp.selectSourceAddress(DST_LL, MAC), ll)) {
        fail("ll dest");
        return;
    }

    // On-link same /64 → preferred global.
    if (!ipv6.addrEq(ndp.selectSourceAddress(DST_ONLINK, MAC), global)) {
        fail("on-link global");
        return;
    }

    // Off-link → still preferred global (default-router path), not LL.
    if (!ipv6.addrEq(ndp.selectSourceAddress(DST_OFFLINK, MAC), global)) {
        fail("off-link global");
        return;
    }

    arch.serial.writeString("[SK-86] ipv6 source select non-x86: OK\n");
}
