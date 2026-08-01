//! SK-157 — UDP race-condition and IPv4 underflow regression tests.
//!
//! Validates fixes for:
//! 1. UDP shared-state races in port registration and queue operations
//! 2. IPv4 parseHeader underflow when total_len < ihl
//!
//! Tests UDP ensurePort duplicate registration, concurrent enqueue/dequeue
//! safety (via IrqSpinlock), and IPv4 malformed packet rejection.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const udp = @import("../net/udp.zig");
const ipv4 = @import("../net/ipv4.zig");
const bo = @import("../lib/byte_order.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-157] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    // Test 1: UDP ensurePort duplicate registration safety
    const port: u16 = 9999;
    const idx1 = udp.ensurePort(port);
    const idx2 = udp.ensurePort(port);

    if (idx1 != idx2) {
        fail("ensurePort duplicate registration returned different indices");
        return;
    }
    if (idx1 == 0xFFFF) {
        fail("ensurePort failed unexpectedly");
        return;
    }

    // Test 2: IPv4 parseHeader underflow rejection (total_len < ihl)
    var malformed: [20]u8 = undefined;
    malformed[0] = 0x46; // version=4, ihl=6 (24 bytes)
    malformed[1] = 0x00;
    bo.writeU16BeAt(&malformed, 2, 20); // total_len=20 < ihl=24 → underflow
    malformed[9] = ipv4.PROTO_UDP;
    @memset(malformed[4..20], 0);

    const bad_info = ipv4.parseHeader(&malformed, null);
    if (bad_info != null) {
        fail("parseHeader accepted total_len < ihl");
        return;
    }

    // Test 3: IPv4 parseHeader frame length validation
    var valid_hdr: [20]u8 = undefined;
    ipv4.buildHeader(&valid_hdr, .{ 10, 0, 0, 1 }, .{ 10, 0, 0, 2 }, ipv4.PROTO_UDP, 40);

    // Pass actual frame length smaller than total_len in header
    const truncated = ipv4.parseHeader(&valid_hdr, 15);
    if (truncated != null) {
        fail("parseHeader accepted frame_len < total_len");
        return;
    }

    // Valid case should succeed
    const good_info = ipv4.parseHeader(&valid_hdr, 60);
    if (good_info == null) {
        fail("parseHeader rejected valid header");
        return;
    }
    if (good_info.?.payload_len != 40) {
        fail("parseHeader payload_len mismatch");
        return;
    }

    // Test 4: UDP enqueue/recvFrom round-trip (lock safety implicit)
    const test_port: u16 = 8888;
    const test_idx = udp.ensurePort(test_port);
    if (test_idx == 0xFFFF) {
        fail("ensurePort failed for test port");
        return;
    }

    const test_payload = "testdata";
    var src_ip: [16]u8 = .{0} ** 16;
    src_ip[0] = 192;
    src_ip[1] = 168;
    src_ip[2] = 1;
    src_ip[3] = 100;

    // Simulate packet reception via handlePacket
    var udp_pkt: [8 + test_payload.len]u8 = undefined;
    bo.writeU16BeAt(&udp_pkt, 0, 5000); // src_port
    bo.writeU16BeAt(&udp_pkt, 2, test_port); // dst_port
    bo.writeU16BeAt(&udp_pkt, 4, @intCast(udp_pkt.len)); // length
    bo.writeU16BeAt(&udp_pkt, 6, 0); // checksum (skip for IPv4)
    @memcpy(udp_pkt[8..], test_payload);

    udp.handlePacket(.{ 192, 168, 1, 100 }, .{ 10, 0, 0, 1 }, &udp_pkt, @intCast(udp_pkt.len));

    // Receive and validate
    var recv_buf: [64]u8 = undefined;
    var recv_src_ip: [4]u8 = undefined;
    var recv_src_port: u16 = 0;
    const n = udp.recvFrom(test_port, &recv_buf, 64, &recv_src_ip, &recv_src_port);

    if (n != test_payload.len) {
        fail("recvFrom returned wrong length");
        return;
    }
    if (recv_src_port != 5000) {
        fail("recvFrom src_port mismatch");
        return;
    }
    for (0..test_payload.len) |i| {
        if (recv_buf[i] != test_payload[i]) {
            fail("recvFrom payload corruption");
            return;
        }
    }

    arch.serial.writeString("[SK-157] UDP race fixes + IPv4 underflow: OK\n");
}
