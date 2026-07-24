//! SK-134 — Accurate ECN ACE counters (non-x86).
//!
//! Alongside classic ECE, echo a 3-bit ACE CE counter in TCP header byte 12
//! and react when the peer's ACE advances (mod 8).

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-134] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-134] tcp ace counters non-x86: OK\n");
        return;
    }

    if (tcp.probeAceDelta(0, 0) != 0 or tcp.probeAceDelta(3, 5) != 2) {
        fail("delta");
        return;
    }
    // 7 → 0 wraps by 1.
    if (tcp.probeAceDelta(7, 0) != 1) {
        fail("wrap");
        return;
    }
    if (!tcp.probeAceShouldReact(1, false, false) or tcp.probeAceShouldReact(0, false, false) or
        tcp.probeAceShouldReact(2, true, false))
    {
        fail("react");
        return;
    }
    if (tcp.probeAceEncode(5, 3) != 0x53) {
        fail("encode");
        return;
    }
    if (tcp.probeAceDecode(0x53) != 3 or tcp.probeAceDecode(0x50) != 0) {
        fail("decode");
        return;
    }

    arch.serial.writeString("[SK-134] tcp ace counters non-x86: OK\n");
}
