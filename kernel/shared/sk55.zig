//! SK-55 — ICMP echo-reply builder (`net/icmp.zig`) on non-x86.
//!
//! icmp.zig imports only nic/netif/eth/ipv4/arp/byte_order (all arch-clean)
//! and has no timers, so it compiles on riscv64/aarch64. Its reply logic used
//! to be buried inside handlePacket (writes a local buffer, then arp/nic side
//! effects), so it was not observable. SK-55 factors the frame construction
//! into a pure `icmp.buildEchoReply` (handlePacket now delegates) and verifies
//! the produced frame end-to-end: ethertype, MAC swap, IPv4 header self-check
//! at offset 14, ICMP type flipped to reply, ICMP checksum valid (folds to 0),
//! and the id/seq/payload echoed verbatim.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const icmp = @import("../net/icmp.zig");
const ipv4 = @import("../net/ipv4.zig");
const eth = @import("../net/eth.zig");

const OUR_IP: [4]u8 = .{ 10, 0, 2, 15 };
const PEER_IP: [4]u8 = .{ 10, 0, 2, 2 };
const OUR_MAC: [6]u8 = .{ 0x52, 0x54, 0x00, 0xAA, 0xBB, 0xCC };
const PEER_MAC: [6]u8 = .{ 0x52, 0x54, 0x00, 0x11, 0x22, 0x33 };

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-55] icmp echo reply builder non-x86: OK\n");
        return;
    }

    // Echo request: type 8, code 0, checksum(2, ignored), id=0xBEEF, seq=1, payload.
    const payload = "ping-payload";
    var req: [8 + payload.len]u8 = undefined;
    req[0] = 8; // echo request
    req[1] = 0;
    req[2] = 0;
    req[3] = 0; // checksum (irrelevant to reply builder)
    req[4] = 0xBE;
    req[5] = 0xEF; // id
    req[6] = 0x00;
    req[7] = 0x01; // seq
    for (payload, 0..) |c, i| req[8 + i] = c;

    var frame: [256]u8 = @splat(0);
    const frame_len = icmp.buildEchoReply(&frame, &req, req.len, OUR_IP, PEER_IP, OUR_MAC, PEER_MAC);

    const icmp_total: u16 = req.len;
    if (frame_len != 14 + 20 + icmp_total) {
        arch.serial.writeString("[SK-55] FAILED: frame length\n");
        return;
    }

    // L2: ethertype IPv4, dst = requester, src = us.
    if (eth.parseEthertype(&frame) != eth.ETHERTYPE_IPV4) {
        arch.serial.writeString("[SK-55] FAILED: ethertype\n");
        return;
    }
    for (PEER_MAC, 0..) |b, i| {
        if (frame[i] != b) {
            arch.serial.writeString("[SK-55] FAILED: dst mac\n");
            return;
        }
    }
    for (OUR_MAC, 0..) |b, i| {
        if (frame[6 + i] != b) {
            arch.serial.writeString("[SK-55] FAILED: src mac\n");
            return;
        }
    }

    // L3: IPv4 header self-checksums to 0, protocol ICMP, addresses = us→peer.
    if (ipv4.checksum(frame[14..].ptr, 20) != 0) {
        arch.serial.writeString("[SK-55] FAILED: ipv4 checksum\n");
        return;
    }
    const info = ipv4.parseHeader(frame[14..].ptr, null) orelse {
        arch.serial.writeString("[SK-55] FAILED: ipv4 parse\n");
        return;
    };
    if (info.protocol != ipv4.PROTO_ICMP) {
        arch.serial.writeString("[SK-55] FAILED: not ICMP\n");
        return;
    }
    for (OUR_IP, 0..) |b, i| {
        if (info.src_ip[i] != b or info.dst_ip[i] != PEER_IP[i]) {
            arch.serial.writeString("[SK-55] FAILED: ip addrs\n");
            return;
        }
    }

    // L4: ICMP type flipped to 0 (reply), checksum valid, payload echoed.
    if (frame[34] != 0 or frame[35] != 0) {
        arch.serial.writeString("[SK-55] FAILED: icmp type/code\n");
        return;
    }
    if (ipv4.checksum(frame[34..].ptr, icmp_total) != 0) {
        arch.serial.writeString("[SK-55] FAILED: icmp checksum\n");
        return;
    }
    // id/seq preserved, payload verbatim.
    if (frame[38] != 0xBE or frame[39] != 0xEF or frame[40] != 0x00 or frame[41] != 0x01) {
        arch.serial.writeString("[SK-55] FAILED: id/seq\n");
        return;
    }
    for (payload, 0..) |c, i| {
        if (frame[42 + i] != c) {
            arch.serial.writeString("[SK-55] FAILED: payload echo\n");
            return;
        }
    }

    arch.serial.writeString("[SK-55] icmp echo reply builder non-x86: OK\n");
}
