//! SK-151 — TCP send copies user data straight into the ring (non-x86).
//!
//! The send path no longer stages a window-sized bounce buffer on the 128 KiB
//! kernel stack, so the ring-wrap split is what keeps the two direct copies
//! inside the buffer. Lock the split and the overflow-safe ProbeRTT cap.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-151] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-151] tcp send user->ring non-x86: OK\n");
        return;
    }

    const size: u32 = 65536;
    // No wrap: the whole count fits before the end of the ring.
    if (tcp.probeRingHeadLen(size, 0, 4096) != 4096 or
        tcp.probeRingHeadLen(size, 60000, 5536) != 5536)
    {
        fail("nowrap");
        return;
    }
    // Wrap: head stops at the ring end and the remainder restarts at 0.
    const head = tcp.probeRingHeadLen(size, 60000, 10000);
    if (head != 5536 or 10000 - head != 4464) {
        fail("wrap");
        return;
    }
    // Degenerate positions must not hand out an out-of-bounds slice.
    if (tcp.probeRingHeadLen(size, size, 16) != 0 or
        tcp.probeRingHeadLen(size, 10, 0) != 0)
    {
        fail("bounds");
        return;
    }
    // base·15 exceeds u32 here, so a 32-bit intermediate would wrap (SK-150).
    if (tcp.probeL4sProbeRttDuration(0x2000_0000, 256) != 0x3C00_0000) {
        fail("prtt wide");
        return;
    }

    arch.serial.writeString("[SK-151] tcp send user->ring non-x86: OK\n");
}
