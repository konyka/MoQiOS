//! SK-135 — ACE per-RTT re-cut rate limit (non-x86).
//!
//! After the first ECN cut, sticky ECE stays once-per-window, but further ACE
//! advances may cut again once ≥1 RTT has elapsed.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-135] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-135] tcp ace rtt rate-limit non-x86: OK\n");
        return;
    }

    if (tcp.probeAceRttLimit(40, 20) != 40 or tcp.probeAceRttLimit(0, 20) != 20 or
        tcp.probeAceRttLimit(0, 0) != 10)
    {
        fail("rtt limit");
        return;
    }
    if (!tcp.probeAceRttReady(0, 100, 40) or !tcp.probeAceRttReady(100, 140, 40) or
        tcp.probeAceRttReady(100, 130, 40))
    {
        fail("rtt ready");
        return;
    }
    // First cut ignores rtt_ready; second cut needs it.
    if (!tcp.probeAceShouldReact(1, false, false) or !tcp.probeAceShouldReact(2, true, true) or
        tcp.probeAceShouldReact(2, true, false) or tcp.probeAceShouldReact(0, true, true))
    {
        fail("react");
        return;
    }

    arch.serial.writeString("[SK-135] tcp ace rtt rate-limit non-x86: OK\n");
}
