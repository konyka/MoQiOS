//! SK-138 — Couple ACE cuts with CUBIC W_max (non-x86).
//!
//! ECE-only keeps classic pre-cut W_max; ACE advances set W_max to the
//! β-scaled post-cut window so CUBIC does not race back to the old peak.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-138] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-138] tcp ace cubic wmax non-x86: OK\n");
        return;
    }

    // ECE-only: classic W_max = pre-cut (floored at 2·SMSS).
    if (tcp.probeAceCubicWmax(10_000, 1460, 0) != 10_000 or
        tcp.probeAceCubicWmax(1000, 1460, 0) != 2920)
    {
        fail("ece wmax");
        return;
    }
    // ACE: W_max tracks scaled ssthresh (β / β²).
    if (tcp.probeAceCubicWmax(10_000, 1460, 1) != 7000 or
        tcp.probeAceCubicWmax(10_000, 1460, 2) != 4900)
    {
        fail("ace wmax");
        return;
    }

    arch.serial.writeString("[SK-138] tcp ace cubic wmax non-x86: OK\n");
}
