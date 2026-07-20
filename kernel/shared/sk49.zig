//! SK-49 — shared Ethernet framing + composed L2/L3 outbound header stack on non-x86.
//!
//! SK-47/48 proved the L3 primitives (ipv4/ipv6 headers + checksums) portable
//! in isolation. `net/eth.zig` is the last L2 framing primitive and is equally
//! arch-clean (only `lib/byte_order.zig`). This probe compiles eth.zig into the
//! riscv64/aarch64 image and, more importantly, composes it with ipv4.zig the
//! way the real TX path does: build an Ethernet frame, lay an IPv4 header at
//! offset 14, then verify the layered result — ethertype parses back, the IPv4
//! header still self-checksums to 0 at its non-zero offset, and total length
//! adds up. This is the first *composition* test: the portable primitives must
//! interoperate, not just pass in isolation.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const eth = @import("../net/eth.zig");
const ipv4 = @import("../net/ipv4.zig");

const DST_MAC: [6]u8 = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
const SRC_MAC: [6]u8 = .{ 0x52, 0x54, 0x00, 0xAB, 0xCD, 0xEF };
const SRC_IP: [4]u8 = .{ 10, 0, 2, 15 };
const DST_IP: [4]u8 = .{ 10, 0, 2, 2 };

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-49] shared eth framing + L2/L3 compose: OK\n");
        return;
    }

    const udp_payload_len: u16 = 8; // pretend UDP header, contents irrelevant here
    const ip_total: u16 = 20 + udp_payload_len;

    var frame: [64]u8 = @splat(0);

    // L2: Ethernet frame header (14 bytes), payload = full IPv4 packet.
    const frame_len = eth.buildFrame(&frame, DST_MAC, SRC_MAC, eth.ETHERTYPE_IPV4, ip_total);
    if (frame_len != 14 + ip_total) {
        arch.serial.writeString("[SK-49] FAILED: frame length\n");
        return;
    }

    // L3: IPv4 header laid at offset 14 (right after the Ethernet header).
    ipv4.buildHeader(frame[14..].ptr, SRC_IP, DST_IP, ipv4.PROTO_UDP, udp_payload_len);

    // Ethertype must parse back to IPv4.
    if (eth.parseEthertype(&frame) != eth.ETHERTYPE_IPV4) {
        arch.serial.writeString("[SK-49] FAILED: ethertype parse\n");
        return;
    }

    // MAC fields must be laid down in the right order.
    for (DST_MAC, 0..) |b, i| {
        if (frame[i] != b) {
            arch.serial.writeString("[SK-49] FAILED: dst mac\n");
            return;
        }
    }
    for (SRC_MAC, 0..) |b, i| {
        if (frame[6 + i] != b) {
            arch.serial.writeString("[SK-49] FAILED: src mac\n");
            return;
        }
    }

    // The IPv4 header must still self-checksum to 0 at its non-zero offset —
    // proving buildHeader is offset-independent and composes under eth framing.
    if (ipv4.checksum(frame[14..].ptr, 20) != 0) {
        arch.serial.writeString("[SK-49] FAILED: composed ipv4 checksum\n");
        return;
    }

    // And parseHeader must read the L3 layer back through the composed frame.
    const info = ipv4.parseHeader(frame[14..].ptr) orelse {
        arch.serial.writeString("[SK-49] FAILED: composed ipv4 parse null\n");
        return;
    };
    if (info.protocol != ipv4.PROTO_UDP or info.payload_len != udp_payload_len) {
        arch.serial.writeString("[SK-49] FAILED: composed ipv4 fields\n");
        return;
    }

    arch.serial.writeString("[SK-49] shared eth framing + L2/L3 compose: OK\n");
}
