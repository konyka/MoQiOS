//! SK-133 — Couple ECN cuts with PRR sndcnt (non-x86).
//!
//! After ECE, if pipe still exceeds the new cwnd, drain with PRR. During loss
//! recovery, ECE only lowers ssthresh so subsequent PRR targets the new value.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-133] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-133] tcp ecn prr couple non-x86: OK\n");
        return;
    }

    if (!tcp.probeEcnReactRecovery(true, false, true) or
        tcp.probeEcnReactRecovery(true, true, true) or
        tcp.probeEcnReactRecovery(true, false, false))
    {
        fail("react recovery");
        return;
    }
    if (!tcp.probeEcnPrrArm(10_000, 7000) or tcp.probeEcnPrrArm(7000, 7000)) {
        fail("prr arm");
        return;
    }
    if (!tcp.probeEcnPrrDone(7000, 7000) or tcp.probeEcnPrrDone(7001, 7000)) {
        fail("prr done");
        return;
    }
    // β=0.7 on max(10000,8000) → 7000
    if (tcp.probeEcnRecoverySsthresh(10_000, 8000, 1460) != 7000) {
        fail("ssthresh");
        return;
    }
    if (tcp.probeEcnRecoverySsthresh(1000, 5000, 1460) != 3500) {
        fail("ssthresh basis");
        return;
    }

    arch.serial.writeString("[SK-133] tcp ecn prr couple non-x86: OK\n");
}
