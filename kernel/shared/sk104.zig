//! SK-104 — Full-MTU TX success raises Path MTU early (non-x86).
//!
//! Raise probing only advanced on lifetime expiry. A successful send that
//! fills the current Path MTU now steps one plateau immediately (PLPMTUD-
//! style confirmation), while undersized sends leave the cache unchanged.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const netif = @import("../net/netif.zig");
const ipv6 = @import("../net/ipv6.zig");
const ipv4 = @import("../net/ipv4.zig");

const DST6: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0xa4,
};
const DST4: [4]u8 = .{ 10, 0, 0, 104 };

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-104] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-104] pmtu tx success raise non-x86: OK\n");
        return;
    }

    netif.resetMtu();
    ipv6.initPmtu();
    ipv4.initPmtu();

    // No cache entry → TX note is a no-op.
    ipv6.noteFullSizeSend(DST6, 1500);
    if (ipv6.probePathMtuCount() != 0) {
        fail("no entry");
        return;
    }

    ipv6.updatePathMtu(DST6, 1280);
    // Undersized send must not raise.
    ipv6.noteFullSizeSend(DST6, 1000);
    if (ipv6.getPathMtu(DST6) != 1280) {
        fail("undersize");
        return;
    }
    // Full-size success → next plateau.
    ipv6.noteFullSizeSend(DST6, 1280);
    if (ipv6.getPathMtu(DST6) != 1400) {
        fail("v6 raise1");
        return;
    }
    ipv6.noteFullSizeSend(DST6, 1400);
    if (ipv6.getPathMtu(DST6) != 1492) {
        fail("v6 raise2");
        return;
    }

    // IPv4: 576 → 1006 on full-size TX.
    ipv4.updatePathMtu(DST4, 576);
    ipv4.noteFullSizeSend(DST4, 400);
    if (ipv4.getPathMtu(DST4) != 576) {
        fail("v4 undersize");
        return;
    }
    ipv4.noteFullSizeSend(DST4, 576);
    if (ipv4.getPathMtu(DST4) != 1006) {
        fail("v4 raise");
        return;
    }

    // PTB/Frag Needed can still lower after a TX raise.
    ipv6.updatePathMtu(DST6, 1280);
    if (ipv6.getPathMtu(DST6) != 1280) {
        fail("relower");
        return;
    }

    ipv4.probeDrainPathMtu(16);
    ipv6.probeDrainPathMtu(16);
    arch.serial.writeString("[SK-104] pmtu tx success raise non-x86: OK\n");
}
