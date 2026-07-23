//! SK-116 — RFC 5682 F-RTO spurious timeout recovery (non-x86).
//!
//! A delayed ACK can fire RTO and cut cwnd even when no segment was lost.
//! F-RTO waits for two new ACKs after a single RTO rexmit before undoing.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-116] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-116] tcp f-rto spurious rto non-x86: OK\n");
        return;
    }

    // Idle.
    const idle = tcp.probeFrtoOnAck(0, true);
    if (idle.frto != 0 or idle.undo or idle.send_new or idle.clear_undo) {
        fail("idle");
        return;
    }

    // First new ACK after RTO → wait for second, send new data.
    const a1 = tcp.probeFrtoOnAck(1, true);
    if (a1.frto != 2 or !a1.send_new or a1.undo or a1.clear_undo) {
        fail("ack1");
        return;
    }

    // Second new ACK → undo.
    const a2 = tcp.probeFrtoOnAck(2, true);
    if (a2.frto != 0 or !a2.undo or a2.send_new or a2.clear_undo) {
        fail("ack2");
        return;
    }

    // Dup ACK during F-RTO → real loss, clear undo.
    const d1 = tcp.probeFrtoOnAck(1, false);
    if (d1.frto != 0 or !d1.clear_undo or d1.undo or d1.send_new) {
        fail("dup");
        return;
    }

    arch.serial.writeString("[SK-116] tcp f-rto spurious rto non-x86: OK\n");
}
