//! SK-75 — IPv6 TCP TCB demux + listen SYN accept on non-x86.
//!
//! SK-74 gated checksum only. This step adds `is_v6`/`remote_ip6`,
//! `findTcbByTupleV6`, family-split listen slots, and demux that clears
//! `idle_ms` on a hit. SYN-ACK TX remains SK-76 (`sendSegment` no-ops for v6).

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");
const tu = @import("../net/tcp_util.zig");
const bo = @import("../lib/byte_order.zig");

const PEER6: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x99,
};
const OURS6: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x01,
};
const LOCAL: u16 = 8080;
const REMOTE: u16 = 40000;

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-75] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

fn buildSeg(buf: *[20]u8, src_port: u16, dst_port: u16, flags: u8) void {
    @memset(buf, 0);
    bo.writeU16BeAt(buf, 0, src_port);
    bo.writeU16BeAt(buf, 2, dst_port);
    bo.writeU16BeAt(buf, 4, 0x1000);
    bo.writeU16BeAt(buf, 6, 0x0001);
    buf[12] = 0x50;
    buf[13] = flags;
    bo.writeU16BeAt(buf, 14, 65535);
    const csum = tu.checksumV6(PEER6, OURS6, buf, 20);
    bo.writeU16BeAt(buf, 16, csum);
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-75] tcp ipv6 tcb demux non-x86: OK\n");
        return;
    }

    // Pure tuple helper.
    if (!tu.tupleMatchV6(LOCAL, REMOTE, PEER6, LOCAL, REMOTE, PEER6)) {
        fail("tuple match");
        return;
    }
    if (tu.tupleMatchV6(LOCAL, REMOTE, PEER6, LOCAL, REMOTE + 1, PEER6)) {
        fail("tuple mismatch");
        return;
    }

    tcp.initTcbs();

    const idx = tcp.tcpProbeSeedV6(LOCAL, REMOTE, PEER6);
    if (idx < 0) {
        fail("seed");
        return;
    }
    if (!tcp.tcpProbeHasV6(LOCAL, REMOTE, PEER6)) {
        fail("has after seed");
        return;
    }
    // Wrong family / port must miss.
    if (tcp.tcpProbeHasV6(LOCAL, REMOTE + 1, PEER6)) {
        fail("false positive");
        return;
    }

    if (tcp.tcpProbeIdleV6(@intCast(idx)) != 999) {
        fail("idle seed");
        return;
    }

    // Demux hit clears idle_ms.
    var seg: [20]u8 = undefined;
    buildSeg(&seg, REMOTE, LOCAL, 0x10); // ACK
    tcp.handlePacketV6(PEER6, OURS6, &seg, 20, false);
    if (tcp.tcpProbeIdleV6(@intCast(idx)) != 0) {
        fail("demux idle");
        return;
    }

    // Listen SYN creates a pending IPv6 TCB (SYN-ACK TX deferred).
    tcp.initTcbs();
    const listen_idx = tcp.tcpSocket(0);
    if (listen_idx < 0) {
        fail("socket");
        return;
    }
    if (tcp.tcpSetIpv6(@intCast(listen_idx)) < 0 or
        tcp.tcpBind(@intCast(listen_idx), LOCAL) < 0 or
        tcp.tcpListen(@intCast(listen_idx)) < 0)
    {
        fail("listen setup");
        return;
    }
    var syn: [20]u8 = undefined;
    buildSeg(&syn, REMOTE, LOCAL, 0x02); // SYN
    tcp.handlePacketV6(PEER6, OURS6, &syn, 20, false);
    if (!tcp.tcpProbeHasV6(LOCAL, REMOTE, PEER6)) {
        fail("syn demux");
        return;
    }

    arch.serial.writeString("[SK-75] tcp ipv6 tcb demux non-x86: OK\n");
}
