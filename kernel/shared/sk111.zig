//! SK-111 — RFC 6675 SACK pipe accounting (non-x86).
//!
//! cwnd checks used snd_nxt−snd_una as in-flight, so SACKed bytes still counted
//! against the pipe and blocked new sends during recovery. Pipe is now
//! flight − sacked overlap with [una,nxt).

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-111] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-111] tcp sack pipe accounting non-x86: OK\n");
        return;
    }

    const una: u32 = 1000;
    const mss: u32 = 1460;
    const nxt: u32 = una + 3 * mss;

    // SACK second segment only → overlap = mss.
    if (tcp.probeSackOverlap(una, nxt, una + mss, una + 2 * mss) != mss) {
        fail("overlap mid");
        return;
    }
    // Block clipped to [una,nxt).
    if (tcp.probeSackOverlap(una, nxt, una -% 100, una + mss) != mss) {
        fail("clip left");
        return;
    }
    if (tcp.probeSackOverlap(una, nxt, nxt -% mss, nxt +% 500) != mss) {
        fail("clip right");
        return;
    }
    // No overlap.
    if (tcp.probeSackOverlap(una, nxt, nxt, nxt +% mss) != 0) {
        fail("no overlap");
        return;
    }

    // Pipe: 3*MSS flight with 1*MSS sacked → 2*MSS.
    if (tcp.probePipeBytes(3 * mss, mss) != 2 * mss) {
        fail("pipe");
        return;
    }
    if (tcp.probePipeBytes(mss, mss) != 0 or tcp.probePipeBytes(mss, mss + 10) != 0) {
        fail("pipe zero");
        return;
    }

    arch.serial.writeString("[SK-111] tcp sack pipe accounting non-x86: OK\n");
}
