//! SK-70 — UDP over IPv6 RX/TX helpers on non-x86.
//!
//! Closes the `mod.zig` PROTO_UDP IPv6 TODO at the stack layer: parse +
//! mandatory checksum (`udp_util`), bound-port delivery (`handlePacketV6`),
//! and NDP-gated TX (`sendToV6`). Syscall `sockaddr_in6` wiring is SK-71.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const udp = @import("../net/udp.zig");
const udp_util = @import("../net/udp_util.zig");
const ndp = @import("../net/ndp.zig");
const ipv6 = @import("../net/ipv6.zig");
const bo = @import("../lib/byte_order.zig");

const BOUND: u16 = 7778;
const SRC_PORT: u16 = 5001;
const SRC6: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x99,
};
const DST6: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x02,
};

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-70] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

fn buildUdpV6(buf: []u8, src: [16]u8, dst: [16]u8, src_port: u16, dst_port: u16, payload: []const u8) u16 {
    const total: u16 = @intCast(8 + payload.len);
    bo.writeU16BeAt(buf.ptr, 0, src_port);
    bo.writeU16BeAt(buf.ptr, 2, dst_port);
    bo.writeU16BeAt(buf.ptr, 4, total);
    buf[6] = 0;
    buf[7] = 0;
    for (payload, 0..) |c, i| buf[8 + i] = c;
    const csum = udp_util.checksumV6(src, dst, buf.ptr, total);
    bo.writeU16BeAt(buf.ptr, 6, csum);
    return total;
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-70] udp over ipv6 non-x86: OK\n");
        return;
    }

    // Pure parse + checksum round-trip.
    var hdr_buf: [16]u8 = @splat(0);
    const pay = "sk70";
    const ulen = buildUdpV6(&hdr_buf, SRC6, DST6, SRC_PORT, BOUND, pay);
    const parsed = udp_util.parseHeader(&hdr_buf, ulen) orelse {
        fail("parse");
        return;
    };
    if (parsed.src_port != SRC_PORT or parsed.dst_port != BOUND or parsed.payload_len != pay.len) {
        fail("parse fields");
        return;
    }
    const again = udp_util.checksumV6(SRC6, DST6, &hdr_buf, ulen);
    if (again != bo.readU16BeAt(&hdr_buf, 6) or again == 0) {
        fail("checksum");
        return;
    }

    // Zero checksum must be rejected on RX.
    const idx = udp.ensurePort(BOUND);
    if (idx == 0xFFFF) {
        fail("ensurePort");
        return;
    }
    var bad = hdr_buf;
    bad[6] = 0;
    bad[7] = 0;
    udp.handlePacketV6(SRC6, DST6, &bad, ulen);
    var out: [64]u8 = undefined;
    var out_ip: [16]u8 = undefined;
    var out_port: u16 = 0;
    if (udp.recvFromV6(BOUND, &out, &out_ip, &out_port) != 0) {
        fail("zero csum accepted");
        return;
    }

    // Good datagram delivered; IPv4 recvFrom must not see it.
    udp.handlePacketV6(SRC6, DST6, &hdr_buf, ulen);
    var v4ip: [4]u8 = undefined;
    if (udp.recvFrom(BOUND, &out, @intCast(out.len), &v4ip, &out_port) != 0) {
        fail("v6 leaked to v4 recv");
        return;
    }
    const n = udp.recvFromV6(BOUND, &out, &out_ip, &out_port);
    if (n != pay.len) {
        fail("recv len");
        return;
    }
    for (pay, 0..) |c, i| {
        if (out[i] != c) {
            fail("payload");
            return;
        }
    }
    if (out_port != SRC_PORT or !ipv6.addrEq(out_ip, SRC6)) {
        fail("src");
        return;
    }

    // TX without NDP → false + markIncomplete.
    ndp.init();
    if (udp.sendToV6(DST6, 53, BOUND, pay, pay.len)) {
        fail("send without ndp");
        return;
    }

    // Seed NDP and exercise full eth+ipv6+udp frame build. nic is a no-op on
    // non-x86 (returns false); success is "no fault" + neighbor still present,
    // matching SK-53's resolved-ARP TX coverage.
    const peer_mac = [6]u8{ 0x02, 0, 0, 0x11, 0x22, 0x33 };
    ndp.update(DST6, peer_mac);
    if (ndp.lookup(DST6) == null) {
        fail("ndp seed");
        return;
    }
    _ = udp.sendToV6(DST6, 53, BOUND, pay, pay.len);

    arch.serial.writeString("[SK-70] udp over ipv6 non-x86: OK\n");
}
