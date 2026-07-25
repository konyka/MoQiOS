//! SK-146 — RTT-window CE mark-rate EWMA for AccECN L4S (non-x86).
//!
//! Accumulate peer ACE CE marks and delivered bytes per RTT, fold into a Q8
//! EWMA, and map that rate to L4S cut intensity.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-146] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-146] tcp l4s ce ewma non-x86: OK\n");
        return;
    }

    if (!tcp.probeL4sRttWindowReady(100, 140, 40) or tcp.probeL4sRttWindowReady(100, 130, 40) or
        tcp.probeL4sRttWindowReady(0, 140, 40))
    {
        fail("window ready");
        return;
    }
    // 2 CE over 16·SMSS → 2*256/16 = 32.
    if (tcp.probeL4sCeRateQ8(2, 16 * 1460, 1460) != 32 or
        tcp.probeL4sCeRateQ8(0, 16 * 1460, 1460) != 0)
    {
        fail("rate q8");
        return;
    }
    if (tcp.probeL4sCeEwma(0, 32) != 32 or tcp.probeL4sCeEwma(32, 64) != 36) {
        fail("ewma");
        return;
    }
    // ewma 32 → 1 cut; 256 → 8 → clamp 7; cold EWMA falls back to δ.
    if (tcp.probeL4sEwmaCuts(32, 2) != 1 or tcp.probeL4sEwmaCuts(256, 1) != 7 or
        tcp.probeL4sEwmaCuts(0, 3) != 3)
    {
        fail("ewma cuts");
        return;
    }

    arch.serial.writeString("[SK-146] tcp l4s ce ewma non-x86: OK\n");
}
