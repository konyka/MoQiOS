//! SK-109 — TCP keepalive probes use SND.UNA−1 (non-x86).
//!
//! Keepalive sent an empty ACK at snd_nxt. Peers often ignore that as a pure
//! duplicate ACK, so idle probes failed. RFC 1122 requires SEQ = SND.UNA−1 so
//! the segment is outside the window and elicits an ACK.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-109] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-109] tcp keepalive snd.una-1 non-x86: OK\n");
        return;
    }

    if (tcp.probeKeepaliveSeq(1000) != 999) {
        fail("basic");
        return;
    }
    if (tcp.probeKeepaliveSeq(0) != 0xffff_ffff) {
        fail("wrap");
        return;
    }
    // Probe must not equal snd_nxt when the send pipe is idle (una == nxt).
    const una: u32 = 0xabcde000;
    if (tcp.probeKeepaliveSeq(una) == una) {
        fail("neq una");
        return;
    }

    arch.serial.writeString("[SK-109] tcp keepalive snd.una-1 non-x86: OK\n");
}
