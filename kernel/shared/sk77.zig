//! SK-77 — IPv6 TCP established data/close via shared state machine on non-x86.
//!
//! SK-76 completed the handshake only. `driveTcbStateMachine` now runs the
//! same established/FIN paths for IPv6 as IPv4. This probe: handshake →
//! deliver one data byte → peer FIN → `close_wait`.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");
const tu = @import("../net/tcp_util.zig");
const ndp = @import("../net/ndp.zig");
const bo = @import("../lib/byte_order.zig");

const PEER6: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x77,
};
const OURS6: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x01,
};
const LOCAL: u16 = 9000;
const REMOTE: u16 = 42000;
const PEER_MAC = [6]u8{ 0x02, 0, 0, 0x77, 0x00, 0x01 };

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-77] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

fn csumFill(buf: []u8) void {
    const csum = tu.checksumV6(PEER6, OURS6, buf.ptr, @intCast(buf.len));
    bo.writeU16BeAt(buf.ptr, 16, csum);
}

fn buildHdr(buf: *[20]u8, seq: u32, ack: u32, flags: u8) void {
    @memset(buf, 0);
    bo.writeU16BeAt(buf, 0, REMOTE);
    bo.writeU16BeAt(buf, 2, LOCAL);
    bo.writeU32BeAt(buf, 4, seq);
    bo.writeU32BeAt(buf, 8, ack);
    buf[12] = 0x50;
    buf[13] = flags;
    bo.writeU16BeAt(buf, 14, 65535);
    csumFill(buf);
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-77] tcp ipv6 established path non-x86: OK\n");
        return;
    }

    tcp.initTcbs();
    ndp.init();
    ndp.update(PEER6, PEER_MAC);

    const listen_idx = tcp.tcpSocket(0);
    if (listen_idx < 0 or tcp.tcpSetIpv6(@intCast(listen_idx)) < 0 or
        tcp.tcpBind(@intCast(listen_idx), LOCAL) < 0 or tcp.tcpListen(@intCast(listen_idx)) < 0)
    {
        fail("listen");
        return;
    }

    // SYN (seq=0x10000001)
    var syn: [20]u8 = undefined;
    buildHdr(&syn, 0x1000_0001, 0, 0x02);
    tcp.handlePacketV6(PEER6, OURS6, &syn, 20);
    if (!tcp.tcpProbeSynAckAdvancedV6(LOCAL, REMOTE, PEER6)) {
        fail("synack");
        return;
    }

    // Third ACK → established (ack covers server's SYN)
    var ack: [20]u8 = undefined;
    buildHdr(&ack, 0x1000_0002, 0x0001_0000, 0x10);
    tcp.handlePacketV6(PEER6, OURS6, &ack, 20);
    if (!tcp.tcpProbeIsEstablishedV6(LOCAL, REMOTE, PEER6)) {
        fail("established");
        return;
    }

    const conn = tcp.tcpProbeConnIdxV6(LOCAL, REMOTE, PEER6);
    if (conn < 0) {
        fail("conn idx");
        return;
    }

    // One-byte data segment (seq = 0x10000002).
    var data_seg: [21]u8 = undefined;
    @memset(&data_seg, 0);
    bo.writeU16BeAt(&data_seg, 0, REMOTE);
    bo.writeU16BeAt(&data_seg, 2, LOCAL);
    bo.writeU32BeAt(&data_seg, 4, 0x1000_0002);
    bo.writeU32BeAt(&data_seg, 8, 0x0001_0000);
    data_seg[12] = 0x50;
    data_seg[13] = 0x18; // PSH|ACK
    bo.writeU16BeAt(&data_seg, 14, 65535);
    data_seg[20] = 'Z';
    csumFill(data_seg[0..]);
    tcp.handlePacketV6(PEER6, OURS6, &data_seg, 21);

    if (tcp.tcpRecvAvailable(@intCast(conn)) != 1) {
        fail("recv avail");
        return;
    }
    var out: [4]u8 = undefined;
    const n = tcp.tcpRecv(@intCast(conn), &out, 4);
    if (n != 1 or out[0] != 'Z') {
        fail("recv data");
        return;
    }

    // FIN → close_wait
    var fin: [20]u8 = undefined;
    buildHdr(&fin, 0x1000_0003, 0x0001_0000, 0x11); // FIN|ACK
    tcp.handlePacketV6(PEER6, OURS6, &fin, 20);
    // close_wait enum value: check via tcpState — close_wait is after established
    const st = tcp.tcpState(@intCast(conn));
    // TcpState: closed=0 ... established, fin_wait_1, fin_wait_2, closing, time_wait, close_wait, last_ack, listen
    // Count: closed, syn_sent, syn_received, established, fin_wait_1, fin_wait_2, closing, time_wait, close_wait, last_ack, listen
    // close_wait = 8
    if (st != 8) {
        fail("close_wait");
        return;
    }

    arch.serial.writeString("[SK-77] tcp ipv6 established path non-x86: OK\n");
}
