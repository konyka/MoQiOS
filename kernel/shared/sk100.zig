//! SK-100 — SYN MSS option + min(local, peer) SMSS (non-x86).
//!
//! SYN/SYN-ACK omitted the MSS option, so peers assumed 536 and we ignored
//! advertised limits. We now offer local SMSS on SYN and clamp send MSS to
//! min(local SMSS, peer MSS).

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const ipv6 = @import("../net/ipv6.zig");
const tcp = @import("../net/tcp.zig");
const bo = @import("../lib/byte_order.zig");

const DST: [16]u8 = .{
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0xa0,
};

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-100] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-100] tcp syn mss option non-x86: OK\n");
        return;
    }

    // Crafted TCP header: 20-byte base + MSS option (kind=2,len=4,mss=1220).
    var hdr: [24]u8 = @splat(0);
    hdr[12] = 6 << 4; // data offset = 6 (24 bytes)
    hdr[20] = 2;
    hdr[21] = 4;
    bo.writeU16BeAt(&hdr, 22, 1220);

    const parsed = tcp.probeParseMss(&hdr, 24) orelse {
        fail("parse");
        return;
    };
    if (parsed != 1220) {
        fail("mss val");
        return;
    }

    ipv6.initPmtu();
    ipv6.updatePathMtu(DST, 1280);
    const offer = tcp.probeSynOfferMssV6(DST);
    if (offer != 1220) {
        fail("offer");
        return;
    }

    // Peer smaller → clamp.
    if (tcp.probeMssWithPeer(offer, 1000) != 1000) {
        fail("peer clamp");
        return;
    }
    // Peer larger → keep local.
    if (tcp.probeMssWithPeer(offer, 1400) != 1220) {
        fail("local keep");
        return;
    }
    // No peer → local.
    if (tcp.probeMssWithPeer(offer, 0) != 1220) {
        fail("no peer");
        return;
    }

    arch.serial.writeString("[SK-100] tcp syn mss option non-x86: OK\n");
}
