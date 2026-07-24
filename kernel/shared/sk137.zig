//! SK-137 — Couple ACE/ECN cuts with BBR drain + rate discount (non-x86).
//!
//! After ACE/ECE, land ProbeBW on the 3/4 drain phase and shrink delivery_rate
//! by (10−cuts)/10 so subsequent BDP/pacing tracks CE severity.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-137] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-137] tcp ace bbr couple non-x86: OK\n");
        return;
    }

    if (tcp.probeBbrAceDrainIdx() != 1 or tcp.probeBbrCycleGainNum(tcp.probeBbrAceDrainIdx()) != 3) {
        fail("drain idx");
        return;
    }
    // cuts=1 → 90%, cuts=2 → 80%, cuts=7 → 30%.
    if (tcp.probeAceRateDiscount(10_000, 0) != 9000 or
        tcp.probeAceRateDiscount(10_000, 2) != 8000 or
        tcp.probeAceRateDiscount(10_000, 7) != 3000)
    {
        fail("rate discount");
        return;
    }
    if (tcp.probeAceRateDiscount(0, 1) != 0 or tcp.probeAceRateDiscount(1, 1) != 1) {
        fail("rate edge");
        return;
    }

    arch.serial.writeString("[SK-137] tcp ace bbr couple non-x86: OK\n");
}
