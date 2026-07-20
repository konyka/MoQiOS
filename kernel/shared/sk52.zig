//! SK-52 — ARP cache + request/reply state machine (`net/arp.zig`) on non-x86.
//!
//! Next link up the dependency chain after SK-51. `net/arp.zig` imports only
//! nic / netif / eth / byte_order — all now arch-clean — and its cache has no
//! aging/timer coupling, so the whole ARP module (parse, cache add/update/
//! resolve, request/reply frame build) compiles and runs on riscv64/aarch64.
//! This is the first probe to drive a real *stateful* protocol module there,
//! not just pure header math: TX calls fall through nic's non-x86 no-op, so
//! nothing is sent, but all the parsing/caching logic executes for real.
//!
//! Scenario: init() clears the cache; a synthetic ARP request for our IP is
//! fed to handlePacket() (which caches the sender and would reply); resolve()
//! must return the cached MAC and miss on an unknown IP; a second packet with
//! the same IP but a new MAC must update the entry in place; sendArpRequest()
//! must build and hand a 42-byte frame to the (no-op) facade without faulting.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const arp = @import("../net/arp.zig");

const SENDER_MAC: [6]u8 = .{ 0x02, 0x00, 0x00, 0x11, 0x22, 0x33 };
const SENDER_MAC2: [6]u8 = .{ 0x02, 0x00, 0x00, 0x44, 0x55, 0x66 };
const SENDER_IP: [4]u8 = .{ 10, 0, 2, 99 };
const OUR_IP: [4]u8 = .{ 10, 0, 2, 15 }; // must match netif.getOurIp()

/// Build a 42-byte ARP-over-Ethernet request frame into `pkt`.
fn buildArpRequest(pkt: *[42]u8, sender_mac: [6]u8, sender_ip: [4]u8, target_ip: [4]u8) void {
    pkt.* = @splat(0);
    // Ethernet: dst broadcast, src = sender, ethertype ARP.
    for (0..6) |i| pkt[i] = 0xFF;
    @memcpy(pkt[6..12], &sender_mac);
    pkt[12] = 0x08;
    pkt[13] = 0x06;
    // ARP payload.
    pkt[14] = 0x00;
    pkt[15] = 0x01; // HTYPE=Ethernet
    pkt[16] = 0x08;
    pkt[17] = 0x00; // PTYPE=IPv4
    pkt[18] = 6; // HLEN
    pkt[19] = 4; // PLEN
    pkt[20] = 0x00;
    pkt[21] = 0x01; // opcode=request
    @memcpy(pkt[22..28], &sender_mac);
    @memcpy(pkt[28..32], &sender_ip);
    // target MAC left zero
    @memcpy(pkt[38..42], &target_ip);
}

fn macEq(a: [6]u8, b: [6]u8) bool {
    for (a, 0..) |x, i| if (x != b[i]) return false;
    return true;
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-52] arp cache/state machine non-x86: OK\n");
        return;
    }

    arp.init();

    // Unknown IP resolves to null on a fresh cache.
    if (arp.resolve(SENDER_IP) != null) {
        arch.serial.writeString("[SK-52] FAILED: stale entry after init\n");
        return;
    }

    // Feed an ARP request for our IP; sender must be cached (reply TX no-ops).
    var pkt: [42]u8 = undefined;
    buildArpRequest(&pkt, SENDER_MAC, SENDER_IP, OUR_IP);
    arp.handlePacket(&pkt, 42);

    const r1 = arp.resolve(SENDER_IP) orelse {
        arch.serial.writeString("[SK-52] FAILED: sender not cached\n");
        return;
    };
    if (!macEq(r1, SENDER_MAC)) {
        arch.serial.writeString("[SK-52] FAILED: cached mac mismatch\n");
        return;
    }

    // Miss on an IP we never saw.
    if (arp.resolve(.{ 10, 0, 2, 50 }) != null) {
        arch.serial.writeString("[SK-52] FAILED: phantom resolve\n");
        return;
    }

    // Same IP, new MAC → in-place update, not a duplicate entry.
    buildArpRequest(&pkt, SENDER_MAC2, SENDER_IP, OUR_IP);
    arp.handlePacket(&pkt, 42);
    const r2 = arp.resolve(SENDER_IP) orelse {
        arch.serial.writeString("[SK-52] FAILED: entry lost after update\n");
        return;
    };
    if (!macEq(r2, SENDER_MAC2)) {
        arch.serial.writeString("[SK-52] FAILED: mac not updated\n");
        return;
    }

    // Too-short frames must be ignored without faulting.
    arp.handlePacket(&pkt, 20);

    // Request builder must run through the no-op facade without faulting.
    arp.sendArpRequest(.{ 10, 0, 2, 2 });

    arch.serial.writeString("[SK-52] arp cache/state machine non-x86: OK\n");
}
