//! SK-110 — Zero-window persist probe (non-x86).
//!
//! When snd_wnd hit 0 with unsent data queued, flushSendBuffer stopped forever
//! if the window-update ACK was lost. A persist timer now sends a 1-byte probe
//! (ignoring the zero window) until the peer readvertises a window.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-110] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-110] tcp zero-window persist non-x86: OK\n");
        return;
    }

    if (!tcp.probePersistActive(0, 100)) {
        fail("active");
        return;
    }
    if (tcp.probePersistActive(1, 100) or tcp.probePersistActive(0, 0)) {
        fail("inactive");
        return;
    }
    if (!tcp.probePersistDue(2000, 2000) or tcp.probePersistDue(1999, 2000)) {
        fail("due");
        return;
    }
    if (tcp.probePersistDue(100, 0)) {
        fail("zero interval");
        return;
    }

    arch.serial.writeString("[SK-110] tcp zero-window persist non-x86: OK\n");
}
