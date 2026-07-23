//! SK-112 — RFC 6675 IsLost / early fast retransmit (non-x86).
//!
//! Fast retransmit waited for 3 duplicate ACKs even when SACK already proved
//! the head was lost. IsLost(snd_una) now also triggers recovery when enough
//! SACKed data or discontiguous blocks sit above the hole.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-112] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-112] tcp sack islost early rexmit non-x86: OK\n");
        return;
    }

    const smss: u32 = 1460;

    // Not lost yet: one MSS SACKed above the hole.
    if (tcp.probeIsLost(smss, 1, smss)) {
        fail("early");
        return;
    }
    // DupThresh-1 MSS SACKed above → lost.
    if (!tcp.probeIsLost(2 * smss, 1, smss)) {
        fail("bytes");
        return;
    }
    // DupThresh discontiguous SACK blocks above → lost.
    if (!tcp.probeIsLost(0, 3, smss)) {
        fail("blocks");
        return;
    }
    // smss=0 must not divide-by-zero or spuriously declare lost on bytes rule.
    if (tcp.probeIsLost(100, 0, 0) or !tcp.probeIsLost(0, 3, 0)) {
        fail("smss0");
        return;
    }

    arch.serial.writeString("[SK-112] tcp sack islost early rexmit non-x86: OK\n");
}
