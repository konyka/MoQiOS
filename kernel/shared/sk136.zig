//! SK-136 — Scale ECN cuts by ACE delta (non-x86).
//!
//! Stack CUBIC β once per CE counted in the ACE delta (ECE-only → one cut).

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-136] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-136] tcp ace delta scale non-x86: OK\n");
        return;
    }

    if (tcp.probeAceCutCount(0) != 1 or tcp.probeAceCutCount(3) != 3) {
        fail("cut count");
        return;
    }
    // β=0.7: 10000 → 7000; twice → 4900.
    if (tcp.probeAceScaledSsthresh(10_000, 1460, 0) != 7000 or
        tcp.probeAceScaledSsthresh(10_000, 1460, 1) != 7000 or
        tcp.probeAceScaledSsthresh(10_000, 1460, 2) != 4900)
    {
        fail("scaled ssthresh");
        return;
    }
    // Recovery basis max(10000,8000)=10000 → two cuts → 4900.
    if (tcp.probeAceScaledRecoverySsthresh(10_000, 8000, 1460, 2) != 4900) {
        fail("recovery scale");
        return;
    }
    // Floor at 2·SMSS still holds after stacked cuts.
    if (tcp.probeAceScaledSsthresh(3000, 1460, 7) != 2920) {
        fail("smss floor");
        return;
    }

    arch.serial.writeString("[SK-136] tcp ace delta scale non-x86: OK\n");
}
