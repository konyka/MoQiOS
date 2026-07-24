//! SK-131 — Classic ECN negotiate + ECE reaction (non-x86).
//!
//! Offer ECN on SYN (ECE+CWR), complete on SYN-ACK ECE, react to ECE with a
//! CUBIC β cut and CWR — without entering loss recovery.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-131] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-131] tcp ecn ece/cwr non-x86: OK\n");
        return;
    }

    const syn = tcp.probeEcnSynFlags(true);
    if (syn != 0xC2) { // SYN|ECE|CWR
        fail("syn flags");
        return;
    }
    if (tcp.probeEcnSynFlags(false) != 0x02) {
        fail("syn off");
        return;
    }
    if (!tcp.probeEcnPeerSetup(0xC2) or tcp.probeEcnPeerSetup(0x52)) {
        fail("peer setup");
        return;
    }
    if (tcp.probeEcnSynAckFlags(true) != 0x52) { // SYN|ACK|ECE
        fail("synack flags");
        return;
    }
    if (tcp.probeEcnSynAckFlags(false) != 0x12) {
        fail("synack plain");
        return;
    }
    if (!tcp.probeEcnSynAckOk(0x52) or tcp.probeEcnSynAckOk(0xD2)) {
        fail("synack ok");
        return;
    }
    if (!tcp.probeEcnReact(true, false, false)) {
        fail("react");
        return;
    }
    if (tcp.probeEcnReact(true, true, false) or tcp.probeEcnReact(true, false, true) or
        tcp.probeEcnReact(false, false, false))
    {
        fail("react guard");
        return;
    }

    arch.serial.writeString("[SK-131] tcp ecn ece/cwr non-x86: OK\n");
}
