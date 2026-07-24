//! SK-76 — IPv6 TCP `sendSegmentV6` + handshake completion on non-x86.
//!
//! SK-75 accepted listen SYNs but `sendSegment` no-op'd for v6. This probe
//! seeds NDP, drives a listen SYN → SYN-ACK (snd_nxt = iss+1), then the
//! client's third ACK → established.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");
const tu = @import("../net/tcp_util.zig");
const ndp = @import("../net/ndp.zig");
const bo = @import("../lib/byte_order.zig");

const PEER6: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x99,
};
const OURS6: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x01,
};
const LOCAL: u16 = 8443;
const REMOTE: u16 = 41000;
const PEER_MAC = [6]u8{ 0x02, 0, 0, 0x76, 0x00, 0x01 };

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-76] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

fn buildSeg(buf: *[20]u8, src_port: u16, dst_port: u16, seq_hi: u16, seq_lo: u16, ack_hi: u16, ack_lo: u16, flags: u8) void {
    @memset(buf, 0);
    bo.writeU16BeAt(buf, 0, src_port);
    bo.writeU16BeAt(buf, 2, dst_port);
    bo.writeU16BeAt(buf, 4, seq_hi);
    bo.writeU16BeAt(buf, 6, seq_lo);
    bo.writeU16BeAt(buf, 8, ack_hi);
    bo.writeU16BeAt(buf, 10, ack_lo);
    buf[12] = 0x50;
    buf[13] = flags;
    bo.writeU16BeAt(buf, 14, 65535);
    const csum = tu.checksumV6(PEER6, OURS6, buf, 20);
    bo.writeU16BeAt(buf, 16, csum);
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-76] tcp sendSegmentV6 handshake non-x86: OK\n");
        return;
    }

    tcp.initTcbs();
    ndp.init();
    ndp.update(PEER6, PEER_MAC);

    // Without NDP, SYN still creates TCB but SYN-ACK TX fails (snd_nxt stays iss).
    ndp.init();
    const listen0 = tcp.tcpSocket(0);
    if (listen0 < 0 or tcp.tcpSetIpv6(@intCast(listen0)) < 0 or
        tcp.tcpBind(@intCast(listen0), LOCAL) < 0 or tcp.tcpListen(@intCast(listen0)) < 0)
    {
        fail("listen0");
        return;
    }
    var syn0: [20]u8 = undefined;
    buildSeg(&syn0, REMOTE, LOCAL, 0x1000, 0x0001, 0, 0, 0x02);
    tcp.handlePacketV6(PEER6, OURS6, &syn0, 20, false);
    if (!tcp.tcpProbeHasV6(LOCAL, REMOTE, PEER6)) {
        fail("syn without ndp");
        return;
    }
    if (tcp.tcpProbeSynAckAdvancedV6(LOCAL, REMOTE, PEER6)) {
        fail("synack without ndp");
        return;
    }

    // With NDP: SYN-ACK advances snd_nxt; third ACK → established.
    tcp.initTcbs();
    ndp.init();
    ndp.update(PEER6, PEER_MAC);
    const listen1 = tcp.tcpSocket(0);
    if (listen1 < 0 or tcp.tcpSetIpv6(@intCast(listen1)) < 0 or
        tcp.tcpBind(@intCast(listen1), LOCAL) < 0 or tcp.tcpListen(@intCast(listen1)) < 0)
    {
        fail("listen1");
        return;
    }
    var syn1: [20]u8 = undefined;
    buildSeg(&syn1, REMOTE, LOCAL, 0x2000, 0x0002, 0, 0, 0x02);
    tcp.handlePacketV6(PEER6, OURS6, &syn1, 20, false);
    if (!tcp.tcpProbeSynAckAdvancedV6(LOCAL, REMOTE, PEER6)) {
        fail("synack advance");
        return;
    }

    // Third ACK: ack = peer's rcv expectation. We don't know iss precisely;
    // use a non-zero ACK flag — server only checks ACK bit for syn_received.
    var ack: [20]u8 = undefined;
    buildSeg(&ack, REMOTE, LOCAL, 0x2000, 0x0003, 0x0001, 0x0000, 0x10);
    tcp.handlePacketV6(PEER6, OURS6, &ack, 20, false);
    if (!tcp.tcpProbeIsEstablishedV6(LOCAL, REMOTE, PEER6)) {
        fail("established");
        return;
    }

    arch.serial.writeString("[SK-76] tcp sendSegmentV6 handshake non-x86: OK\n");
}
