//! SK-139 — AccECN SYN negotiation via AE (non-x86).
//!
//! Offer AccECN on SYN-ACK with AE|ECE (no CWR). Only then enable ACE feedback;
//! classic ECE-only SYN-ACK still negotiates RFC 3168 ECN without ACE.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-139] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-139] tcp accecn ae negotiate non-x86: OK\n");
        return;
    }

    // Classic SYN-ACK ECE (byte12 AE clear) is ECN but not AccECN.
    if (!tcp.probeEcnSynAckOk(0x52) or tcp.probeAccecnSynAckOk(0x52, 0x50)) {
        fail("classic synack");
        return;
    }
    // AccECN: same flags plus AE in byte12 bit0 (e.g. 0x51).
    if (!tcp.probeAccecnSynAckOk(0x52, 0x51) or tcp.probeAccecnSynAckOk(0xD2, 0x51)) {
        fail("accecn synack");
        return;
    }
    if (tcp.probeAccecnAeBit(true) != 0x01 or tcp.probeAccecnAeBit(false) != 0) {
        fail("ae bit");
        return;
    }
    if (!tcp.probeAceFeedbackEnabled(true) or tcp.probeAceFeedbackEnabled(false)) {
        fail("ace gate");
        return;
    }

    arch.serial.writeString("[SK-139] tcp accecn ae negotiate non-x86: OK\n");
}
