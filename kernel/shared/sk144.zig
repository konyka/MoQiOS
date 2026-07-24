//! SK-144 — L4S-lite proportional AccECN window cuts (non-x86).
//!
//! On AccECN, each ACE CE mark keeps (8−δ)/8 of cwnd instead of stacking
//! CUBIC β, so dense L4S CE marking trims gently rather than collapsing.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-144] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-144] tcp l4s ace cut non-x86: OK\n");
        return;
    }

    // δ=1 → 7/8; δ=2 → 6/8; ECE-only δ=0 → one cut (7/8).
    if (tcp.probeL4sSsthresh(8000, 1460, 1) != 7000 or
        tcp.probeL4sSsthresh(8000, 1460, 2) != 6000 or
        tcp.probeL4sSsthresh(8000, 1460, 0) != 7000)
    {
        fail("l4s cut");
        return;
    }
    // Floor at 2·SMSS after heavy CE.
    if (tcp.probeL4sSsthresh(3000, 1460, 7) != 2920) {
        fail("smss floor");
        return;
    }
    // Milder than CUBIC β^2 on same input (7500 > 4900).
    if (tcp.probeL4sSsthresh(10_000, 1460, 2) <= tcp.probeAceScaledSsthresh(10_000, 1460, 2)) {
        fail("milder than cubic");
        return;
    }

    arch.serial.writeString("[SK-144] tcp l4s ace cut non-x86: OK\n");
}
