//! SK-117 — Tail Loss Probe before RTO (non-x86).
//!
//! Lost tail segments often produce no dup ACK / SACK, so recovery waited for
//! a full RTO. TLP sends one probe at ~2·SRTT without cutting cwnd.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-117] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-117] tcp tail loss probe non-x86: OK\n");
        return;
    }

    // PTO from SRTT, floored at 10ms, capped below RTO.
    if (tcp.probeTlpTimeoutMs(100, 2000) != 200) {
        fail("pto srtt");
        return;
    }
    if (tcp.probeTlpTimeoutMs(2, 2000) != 10) {
        fail("pto floor");
        return;
    }
    if (tcp.probeTlpTimeoutMs(5000, 1000) != 999) {
        fail("pto cap");
        return;
    }

    // Fire window: at PTO, before RTO, not already probing/recovering.
    if (!tcp.probeTlpShouldFire(200, 200, 2000, false, false, 0)) {
        fail("fire");
        return;
    }
    if (tcp.probeTlpShouldFire(200, 200, 2000, true, false, 0) or
        tcp.probeTlpShouldFire(200, 200, 2000, false, true, 0) or
        tcp.probeTlpShouldFire(200, 200, 2000, false, false, 1) or
        tcp.probeTlpShouldFire(2000, 200, 2000, false, false, 0))
    {
        fail("nofire");
        return;
    }

    arch.serial.writeString("[SK-117] tcp tail loss probe non-x86: OK\n");
}
