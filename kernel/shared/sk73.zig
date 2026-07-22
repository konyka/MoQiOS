//! SK-73 — UDP getsockname/getpeername address encode (`encodeUdpName`) on non-x86.
//!
//! SK-71 wired bind/sendto/recvfrom/connect for AF_INET6 UDP, but name queries
//! still returned ENOTSOCK. The syscall now uses `encodeUdpName`; this probe
//! locks v4/v6 local+peer encoding lengths and family/port/address fields.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const sa = @import("../net/sockaddr_util.zig");
const ipv6 = @import("../net/ipv6.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-73] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-73] udp getsockname encode non-x86: OK\n");
        return;
    }

    const ip4 = [4]u8{ 10, 0, 2, 15 };
    const ip6 = [16]u8{
        0xfe, 0x80, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0x01,
    };
    var out: [sa.SOCKADDR_IN6_LEN]u8 = undefined;

    // Local IPv4 name.
    const n4 = sa.encodeUdpName(false, 7777, ip4, ip6, &out);
    if (n4 != sa.SOCKADDR_IN_LEN) {
        fail("v4 len");
        return;
    }
    const p4 = sa.parseInet4(out[0..n4]) orelse {
        fail("v4 parse");
        return;
    };
    if (p4.port != 7777 or p4.addr[3] != 15) {
        fail("v4 fields");
        return;
    }

    // Peer IPv6 name.
    @memset(&out, 0);
    const n6 = sa.encodeUdpName(true, 53, ip4, ip6, &out);
    if (n6 != sa.SOCKADDR_IN6_LEN) {
        fail("v6 len");
        return;
    }
    const p6 = sa.parseInet6(out[0..n6]) orelse {
        fail("v6 parse");
        return;
    };
    if (p6.port != 53 or !ipv6.addrEq(p6.addr, ip6)) {
        fail("v6 fields");
        return;
    }

    // Buffer too short for v6 → 0.
    var tiny: [8]u8 = undefined;
    if (sa.encodeUdpName(true, 1, ip4, ip6, &tiny) != 0) {
        fail("short v6");
        return;
    }

    arch.serial.writeString("[SK-73] udp getsockname encode non-x86: OK\n");
}
