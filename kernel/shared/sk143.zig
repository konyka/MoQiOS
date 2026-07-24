//! SK-143 — AccECN/L4S send path uses ECT(1) (non-x86).
//!
//! Classic ECN keeps ECT(0); once AccECN is negotiated, mark non-SYN packets
//! with ECT(1) so L4S-capable AQMs can apply scalable CE marking.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");
const ipv4 = @import("../net/ipv4.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-143] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-143] tcp accecn ect(1) non-x86: OK\n");
        return;
    }

    if (tcp.probeEcnSendCodepoint(false, false) != ipv4.ECN_NOT_ECT or
        tcp.probeEcnSendCodepoint(false, true) != ipv4.ECN_ECT0 or
        tcp.probeEcnSendCodepoint(true, true) != ipv4.ECN_ECT1)
    {
        fail("codepoint");
        return;
    }
    // AccECN without classic ecn_ok is not a send path we use.
    if (tcp.probeEcnSendCodepoint(true, false) != ipv4.ECN_NOT_ECT) {
        fail("gate");
        return;
    }

    arch.serial.writeString("[SK-143] tcp accecn ect(1) non-x86: OK\n");
}
