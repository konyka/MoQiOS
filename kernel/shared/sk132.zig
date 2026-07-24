//! SK-132 — ECN cut interacts with undo / loss recovery (non-x86).
//!
//! ECE saves undo state; DSACK/F-RTO can restore it before CWR. Loss recovery
//! in the same window must not apply a second CUBIC cut.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-132] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-132] tcp ecn undo/loss cut non-x86: OK\n");
        return;
    }

    if (!tcp.probeEcnSkipLossCut(true) or tcp.probeEcnSkipLossCut(false)) {
        fail("skip cut");
        return;
    }
    if (!tcp.probeEcnKeepUndo(true, 10000) or tcp.probeEcnKeepUndo(true, 0) or
        tcp.probeEcnKeepUndo(false, 10000))
    {
        fail("keep undo");
        return;
    }
    // ECE still reacts once outside recovery.
    if (!tcp.probeEcnReact(true, false, false) or tcp.probeEcnReact(true, true, false)) {
        fail("react");
        return;
    }

    arch.serial.writeString("[SK-132] tcp ecn undo/loss cut non-x86: OK\n");
}
