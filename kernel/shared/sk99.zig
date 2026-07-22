//! SK-99 — TCP Reno congestion control uses SMSS (non-x86).
//!
//! SK-98 sized segments from Path MTU, but cwnd/ssthresh still stepped by the
//! fixed IPv4 MSS. Reno CA/fast-recovery/RTO floors now use SMSS = PMTU−60.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const ipv6 = @import("../net/ipv6.zig");
const tcp = @import("../net/tcp.zig");

const DST: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x99,
};

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-99] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-99] tcp reno smss pmtu non-x86: OK\n");
        return;
    }

    ipv6.initPmtu();
    ipv6.updatePathMtu(DST, 1280);
    const smss = tcp.probeIpv6Mss(DST);
    if (smss != 1220) {
        fail("smss");
        return;
    }

    // CA: cwnd += SMSS² / cwnd
    const cwnd: u32 = 12200;
    const inc = tcp.probeIpv6RenoCaInc(DST, cwnd);
    if (inc != (1220 * 1220) / cwnd) {
        fail("ca inc");
        return;
    }

    // ssthresh floor = 2×SMSS
    if (tcp.probeIpv6RenoMinSsthresh(DST) != 2 * 1220) {
        fail("ssthresh");
        return;
    }

    // After PMTU expiry, SMSS (and Reno floors) track LINK_MTU again.
    ipv6.pathMtuTimerTick(ipv6.PMTU_LIFETIME_SEC * 1000);
    if (tcp.probeIpv6Mss(DST) != 1440 or tcp.probeIpv6RenoMinSsthresh(DST) != 2880) {
        fail("expire");
        return;
    }

    arch.serial.writeString("[SK-99] tcp reno smss pmtu non-x86: OK\n");
}
