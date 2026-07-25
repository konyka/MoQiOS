//! SK-147 — AccECN CE-rate EWMA scales ProbeBW pacing gain (non-x86).
//!
//! When AccECN L4S tracks a non-zero CE/seg EWMA, shrink the ProbeBW gain
//! numerator by (8−cuts)/8 so pacing drains with sustained marking.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-147] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-147] tcp l4s ewma pace gain non-x86: OK\n");
        return;
    }

    // Cold EWMA leaves gain untouched.
    if (tcp.probeL4sEwmaGainNum(5, 0) != 5 or tcp.probeL4sEwmaGainNum(4, 0) != 4) {
        fail("cold");
        return;
    }
    // ewma 32 → 1 cut → keep 7/8: 5→4, 4→3.
    if (tcp.probeL4sEwmaGainNum(5, 32) != 4 or tcp.probeL4sEwmaGainNum(4, 32) != 3) {
        fail("mild");
        return;
    }
    // ewma 256 → 7 cuts → keep 1/8: 5→1 (floor).
    if (tcp.probeL4sEwmaGainNum(5, 256) != 1 or tcp.probeL4sEwmaGainNum(3, 256) != 1) {
        fail("severe");
        return;
    }
    // Scaled cruise cwnd is below unscaled BDP·gain.
    const bdp: u32 = 8000;
    const hi = tcp.probeBbrCycleCwnd(bdp, 5);
    const lo = tcp.probeBbrCycleCwnd(bdp, tcp.probeL4sEwmaGainNum(5, 32));
    if (lo == 0 or lo >= hi) {
        fail("cwnd");
        return;
    }

    arch.serial.writeString("[SK-147] tcp l4s ewma pace gain non-x86: OK\n");
}
