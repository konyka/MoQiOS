//! SK-53 — UDP port-binding table + receive queues + TX path (`net/udp.zig`) on non-x86.
//!
//! Next link after SK-52. `udp.zig` imports only nic/netif/eth/ipv4/arp/
//! byte_order (all arch-clean) and its state is a static port table with
//! per-port receive queues — no timers — so the whole module compiles and runs
//! on riscv64/aarch64. This drives the observable receive path for real:
//! port binding, delivery to bound ports only, unbound-port drop, queue-depth
//! overflow, and drain order. sendTo() is exercised on both branches
//! (unresolved ARP → request + false; resolved → full eth/ipv4/udp frame build
//! through nic's no-op) purely for no-fault coverage, since TX cannot be
//! observed on non-x86 yet.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const udp = @import("../net/udp.zig");
const arp = @import("../net/arp.zig");

const SRC_IP: [4]u8 = .{ 10, 0, 2, 99 };
const DST_IP: [4]u8 = .{ 10, 0, 2, 2 };
const BOUND_PORT: u16 = 7777;
const SRC_PORT: u16 = 5000;
const QUEUE_DEPTH: usize = 8; // must match udp.zig

/// Fill `buf` with a UDP segment (header + payload) for handlePacket, which
/// reads src_port@0, dst_port@2, length@4, checksum@6, payload@8.
fn buildUdp(buf: []u8, src_port: u16, dst_port: u16, payload: []const u8) void {
    const total: u16 = @intCast(8 + payload.len);
    buf[0] = @truncate(src_port >> 8);
    buf[1] = @truncate(src_port);
    buf[2] = @truncate(dst_port >> 8);
    buf[3] = @truncate(dst_port);
    buf[4] = @truncate(total >> 8);
    buf[5] = @truncate(total);
    buf[6] = 0;
    buf[7] = 0;
    for (payload, 0..) |c, i| buf[8 + i] = c;
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-53] udp ports/queues non-x86: OK\n");
        return;
    }

    // Bind a port; ensurePort must be idempotent.
    const idx = udp.ensurePort(BOUND_PORT);
    if (idx == 0xFFFF) {
        arch.serial.writeString("[SK-53] FAILED: ensurePort full\n");
        return;
    }
    if (udp.ensurePort(BOUND_PORT) != idx) {
        arch.serial.writeString("[SK-53] FAILED: ensurePort not idempotent\n");
        return;
    }

    // Deliver one datagram to the bound port, then read it back.
    const msg = "sk53-udp";
    var seg: [8 + msg.len]u8 = undefined;
    buildUdp(&seg, SRC_PORT, BOUND_PORT, msg);
    udp.handlePacket(SRC_IP, DST_IP, &seg, seg.len);

    var out: [64]u8 = undefined;
    var out_ip: [4]u8 = undefined;
    var out_port: u16 = 0;
    const n = udp.recvFrom(BOUND_PORT, &out, &out_ip, &out_port);
    if (n != msg.len) {
        arch.serial.writeString("[SK-53] FAILED: recv len\n");
        return;
    }
    for (msg, 0..) |c, i| {
        if (out[i] != c) {
            arch.serial.writeString("[SK-53] FAILED: payload mismatch\n");
            return;
        }
    }
    if (out_port != SRC_PORT or out_ip[3] != SRC_IP[3] or out_ip[0] != SRC_IP[0]) {
        arch.serial.writeString("[SK-53] FAILED: src ip/port\n");
        return;
    }

    // Queue is now empty again.
    if (udp.recvFrom(BOUND_PORT, &out, &out_ip, &out_port) != 0) {
        arch.serial.writeString("[SK-53] FAILED: queue not drained\n");
        return;
    }

    // Datagram to an unbound port must be dropped (no auto-bind on receive).
    const UNBOUND: u16 = 6543;
    buildUdp(&seg, SRC_PORT, UNBOUND, msg);
    udp.handlePacket(SRC_IP, DST_IP, &seg, seg.len);
    if (udp.recvFrom(UNBOUND, &out, &out_ip, &out_port) != 0) {
        arch.serial.writeString("[SK-53] FAILED: unbound delivered\n");
        return;
    }

    // Overflow: push QUEUE_DEPTH+1 datagrams, only QUEUE_DEPTH should be kept.
    var i: usize = 0;
    while (i < QUEUE_DEPTH + 1) : (i += 1) {
        var one: [9]u8 = undefined;
        const body = [_]u8{@intCast('0' + @as(u8, @intCast(i % 10)))};
        buildUdp(&one, SRC_PORT, BOUND_PORT, &body);
        udp.handlePacket(SRC_IP, DST_IP, &one, one.len);
    }
    var drained: usize = 0;
    while (udp.recvFrom(BOUND_PORT, &out, &out_ip, &out_port) != 0) drained += 1;
    if (drained != QUEUE_DEPTH) {
        arch.serial.writeString("[SK-53] FAILED: queue depth wrong\n");
        return;
    }

    // TX unresolved-ARP branch: no cache entry → returns false, queues an ARP request.
    arp.init();
    if (udp.sendTo(DST_IP, 53, BOUND_PORT, msg, msg.len)) {
        arch.serial.writeString("[SK-53] FAILED: sendTo succeeded without arp\n");
        return;
    }

    // TX resolved branch: seed the ARP cache so sendTo runs the full frame
    // build (eth+ipv4+udp) through nic's no-op without faulting.
    var arp_req: [42]u8 = @splat(0);
    for (0..6) |k| arp_req[k] = 0xFF;
    const peer_mac = [6]u8{ 0x02, 0, 0, 0xAB, 0xCD, 0xEF };
    @memcpy(arp_req[6..12], &peer_mac);
    arp_req[12] = 0x08;
    arp_req[13] = 0x06;
    arp_req[15] = 0x01; // htype
    arp_req[16] = 0x08; // ptype hi
    arp_req[18] = 6;
    arp_req[19] = 4;
    arp_req[21] = 0x01; // opcode request
    @memcpy(arp_req[22..28], &peer_mac);
    @memcpy(arp_req[28..32], &DST_IP); // sender_ip = DST_IP → caches DST_IP's MAC
    const our_ip = [4]u8{ 10, 0, 2, 15 };
    @memcpy(arp_req[38..42], &our_ip); // target = our ip
    arp.handlePacket(&arp_req, 42);
    _ = udp.sendTo(DST_IP, 53, BOUND_PORT, msg, msg.len); // no-op TX, must not fault

    arch.serial.writeString("[SK-53] udp ports/queues non-x86: OK\n");
}
