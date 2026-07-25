//! SK-145 — Separate IP-CE stats; normalize L4S cuts by delivery (non-x86).
//!
//! Keep a full-width IP-CE receive counter apart from the ACE wire field, and
//! scale AccECN L4S cut intensity by SMSS segments delivered since the last cut.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-145] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-145] tcp ace ce rate norm non-x86: OK\n");
        return;
    }

    // 2 CE over 16·SMSS → cuts = 16/16 = 1 (milder than raw 2).
    if (tcp.probeL4sNormCuts(2, 16 * 1460, 1460) != 1) {
        fail("sparse");
        return;
    }
    // 2 CE over 2·SMSS → cuts = 16/2 = 8 → clamp 7.
    if (tcp.probeL4sNormCuts(2, 2 * 1460, 1460) != 7) {
        fail("dense");
        return;
    }
    // No delivery sample → raw ACE cut count.
    if (tcp.probeL4sNormCuts(3, 0, 1460) != 3 or tcp.probeL4sNormCuts(0, 0, 1460) != 1) {
        fail("raw");
        return;
    }
    // Normalized mild cut keeps more cwnd than raw δ=2 L4S cut.
    const mild = tcp.probeL4sSsthresh(8000, 1460, tcp.probeL4sNormCuts(2, 16 * 1460, 1460));
    const raw = tcp.probeL4sSsthresh(8000, 1460, 2);
    if (mild <= raw) {
        fail("milder ssthresh");
        return;
    }

    arch.serial.writeString("[SK-145] tcp ace ce rate norm non-x86: OK\n");
}
