//! SK-105 — Oversized Path MTU raise probes (non-x86).
//!
//! TX was hard-capped at the cached PMTU, so the next plateau could never be
//! tried until a blind timer raise. An armed probe now lifts the send ceiling
//! one plateau; success confirms via noteFullSizeSend, while getPathMtu stays
//! conservative until then.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const netif = @import("../net/netif.zig");
const ipv6 = @import("../net/ipv6.zig");
const ipv4 = @import("../net/ipv4.zig");

const DST6: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0xa5,
};
const DST4: [4]u8 = .{ 10, 0, 0, 105 };

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-105] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-105] pmtu oversized probe non-x86: OK\n");
        return;
    }

    netif.resetMtu();
    ipv6.initPmtu();
    ipv4.initPmtu();

    // No entry → arm fails.
    if (ipv6.armRaiseProbe(DST6)) {
        fail("arm empty");
        return;
    }

    ipv6.updatePathMtu(DST6, 1280);
    if (ipv6.getPathMtu(DST6) != 1280 or ipv6.getSendMtu(DST6) != 1280) {
        fail("baseline");
        return;
    }
    if (!ipv6.armRaiseProbe(DST6)) {
        fail("arm");
        return;
    }
    // Cached PMTU stays 1280; TX may try 1400.
    if (ipv6.getPathMtu(DST6) != 1280 or ipv6.getSendMtu(DST6) != 1400) {
        fail("send ceiling");
        return;
    }

    // Oversized probe success confirms the raise.
    ipv6.noteFullSizeSend(DST6, 1400);
    if (ipv6.getPathMtu(DST6) != 1400) {
        fail("confirm");
        return;
    }
    // After raise, next probe is auto-armed (SK-105 chain).
    if (ipv6.getSendMtu(DST6) != 1492) {
        fail("chain arm");
        return;
    }

    // PTB clears the armed probe.
    ipv6.updatePathMtu(DST6, 1280);
    if (ipv6.getSendMtu(DST6) != 1280) {
        fail("ptb clear");
        return;
    }

    // IPv4: arm 576 → send ceiling 1006.
    ipv4.updatePathMtu(DST4, 576);
    if (!ipv4.armRaiseProbe(DST4) or ipv4.getSendMtu(DST4) != 1006) {
        fail("v4 arm");
        return;
    }
    ipv4.noteFullSizeSend(DST4, 1006);
    if (ipv4.getPathMtu(DST4) != 1006) {
        fail("v4 confirm");
        return;
    }

    ipv4.probeDrainPathMtu(16);
    ipv6.probeDrainPathMtu(16);
    arch.serial.writeString("[SK-105] pmtu oversized probe non-x86: OK\n");
}
