//! SK-124 — CUBIC congestion avoidance (non-x86).
//!
//! When BBR rate samples are unavailable, Reno AI grows too slowly on long
//! fat pipes. CUBIC uses W(t)=C(t−K)³+W_max with β=0.7 loss reduction.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-124] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-124] tcp cubic ca non-x86: OK\n");
        return;
    }

    if (tcp.probeICbrt(27) != 3 or tcp.probeICbrt(0) != 0 or tcp.probeICbrt(8) != 2) {
        fail("cbrt");
        return;
    }

    // β=0.7 → 10000 → 7000, floored at 2*SMSS.
    if (tcp.probeCubicSsthresh(10_000, 1460) != 7000) {
        fail("ssthresh");
        return;
    }
    if (tcp.probeCubicSsthresh(1000, 1460) != 2920) {
        fail("ssthresh floor");
        return;
    }

    // At t=K, target ≈ W_max.
    const smss: u32 = 1460;
    const wmax: u32 = 40 * smss;
    const k = tcp.probeCubicK(wmax, smss);
    const at_k = tcp.probeCubicTarget(wmax, smss, k, k);
    if (at_k < wmax - smss or at_k > wmax + smss) {
        fail("at K");
        return;
    }
    // After K, target grows above W_max.
    if (tcp.probeCubicTarget(wmax, smss, k + 2000, k) <= wmax) {
        fail("after K");
        return;
    }

    arch.serial.writeString("[SK-124] tcp cubic ca non-x86: OK\n");
}
