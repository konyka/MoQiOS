//! SK-140 — ACE feedback in AE|CWR|ECE (non-x86).
//!
//! After AccECN, pack the 3-bit ACE counter into AE (byte12 bit0) plus CWR and
//! ECE flags instead of the reserved low bits of byte12.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-140] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-140] tcp ace ae|cwr|ece non-x86: OK\n");
        return;
    }

    // ace=5 (101b) → AE + ECE; ace=3 (011b) → CWR + ECE.
    if (tcp.probeAcePackAe(5) != 0x01 or tcp.probeAcePackAe(3) != 0) {
        fail("pack ae");
        return;
    }
    const ack: u8 = 0x10;
    if (tcp.probeAcePackFlags(5, ack) != (ack | 0x40) or // ECE
        tcp.probeAcePackFlags(3, ack) != (ack | 0xC0)) // CWR|ECE
    {
        fail("pack flags");
        return;
    }
    // Round-trip: ace 0..7.
    var ace: u3 = 0;
    while (true) {
        const b12: u8 = 0x50 | tcp.probeAcePackAe(ace);
        const fl = tcp.probeAcePackFlags(ace, ack);
        if (tcp.probeAceUnpack(b12, fl) != ace) {
            fail("unpack");
            return;
        }
        if (ace == 7) break;
        ace += 1;
    }

    arch.serial.writeString("[SK-140] tcp ace ae|cwr|ece non-x86: OK\n");
}
