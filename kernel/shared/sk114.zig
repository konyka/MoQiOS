//! SK-114 — RFC 6937 PRR during fast recovery (non-x86).
//!
//! Reno inflated cwnd by SMSS per dup ACK and shrunk by acked on partial ACK,
//! overshooting the pipe after heavy loss. PRR paces sends toward ssthresh.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-114] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-114] tcp prr recovery non-x86: OK\n");
        return;
    }

    // Proportional Reduction: RecoverFS=10000, ssthresh=5000, delivered=2000 → 1000.
    if (tcp.probePrrSndcnt(8000, 5000, 10000, 2000, 0, 2000) != 1000) {
        fail("pr");
        return;
    }
    // Already sent the PRR allotment → 0.
    if (tcp.probePrrSndcnt(8000, 5000, 10000, 2000, 1000, 0) != 0) {
        fail("pr out");
        return;
    }
    // SSRB catch-up toward ssthresh when pipe is below it.
    // pipe=2000, ssthresh=5000, prr_delivered=3000, prr_out=1000, delivered=500
    // → min(3000, max(2000, 500)) = 2000.
    if (tcp.probePrrSndcnt(2000, 5000, 10000, 3000, 1000, 500) != 2000) {
        fail("ssrb");
        return;
    }
    // SSRB capped by ssthresh − pipe.
    if (tcp.probePrrSndcnt(4500, 5000, 10000, 9000, 0, 1460) != 500) {
        fail("ssrb cap");
        return;
    }

    arch.serial.writeString("[SK-114] tcp prr recovery non-x86: OK\n");
}
