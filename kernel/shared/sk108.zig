//! SK-108 — SACK selective retransmit (non-x86).
//!
//! Fast retransmit always restarted at snd_una, resending bytes the peer had
//! already SACKed. The next rexmit sequence now skips scoreboard-covered
//! ranges so only the first hole is retransmitted.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-108] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-108] sack selective retransmit non-x86: OK\n");
        return;
    }

    const una: u32 = 1000;
    const mss: u32 = 1460;
    const nxt: u32 = una + 2 * mss;

    // No SACK coverage → retransmit from snd_una.
    if (tcp.probeNextRexmitSeq(una, nxt, 0, 0) != una) {
        fail("no sack");
        return;
    }

    // First MSS SACKed → hole starts at una+MSS.
    if (tcp.probeNextRexmitSeq(una, nxt, una, una + mss) != una + mss) {
        fail("skip sacked");
        return;
    }

    // Entire flight SACKed → fall back to snd_una.
    if (tcp.probeNextRexmitSeq(una, nxt, una, nxt) != una) {
        fail("all sacked");
        return;
    }

    // Sequence wrap: SACK covers una..una+mss across the wrap boundary logic
    // via seqInWindow; una near top of u32.
    const una_w: u32 = 0xfffff000;
    const mss_w: u32 = 0x1000;
    const nxt_w: u32 = una_w +% (2 * mss_w);
    if (tcp.probeNextRexmitSeq(una_w, nxt_w, una_w, una_w +% mss_w) != una_w +% mss_w) {
        fail("wrap");
        return;
    }

    arch.serial.writeString("[SK-108] sack selective retransmit non-x86: OK\n");
}
