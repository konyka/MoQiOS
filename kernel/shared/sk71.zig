//! SK-71 — sockaddr_in / sockaddr_in6 encode/decode on non-x86.
//!
//! SK-70 wired the IPv6 UDP stack. The syscall layer needs a single layout
//! contract for bind/sendto/recvfrom/connect; this probe locks that contract
//! without needing a live user process.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const sa = @import("../net/sockaddr_util.zig");
const ipv6 = @import("../net/ipv6.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-71] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-71] sockaddr inet6 util non-x86: OK\n");
        return;
    }

    // IPv4 round-trip.
    const ip4 = [4]u8{ 10, 0, 2, 15 };
    var buf4: [sa.SOCKADDR_IN_LEN]u8 = undefined;
    if (sa.writeInet4(&buf4, 8080, ip4) != sa.SOCKADDR_IN_LEN) {
        fail("write4 len");
        return;
    }
    const p4 = sa.parseInet4(&buf4) orelse {
        fail("parse4");
        return;
    };
    if (p4.port != 8080 or p4.addr[0] != 10 or p4.addr[3] != 15) {
        fail("roundtrip4");
        return;
    }

    // IPv6 round-trip + scope_id.
    const ip6 = [16]u8{
        0xfe, 0x80, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0x01,
    };
    var buf6: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
    if (sa.writeInet6(&buf6, 53, ip6, 0x42) != sa.SOCKADDR_IN6_LEN) {
        fail("write6 len");
        return;
    }
    if (buf6[0] != 10 or buf6[1] != 0) { // AF_INET6 little-endian
        fail("family6");
        return;
    }
    const p6 = sa.parseInet6(&buf6) orelse {
        fail("parse6");
        return;
    };
    if (p6.port != 53 or p6.scope_id != 0x42 or !ipv6.addrEq(p6.addr, ip6)) {
        fail("roundtrip6");
        return;
    }

    // Family mismatch rejects (full-sized buffers, wrong sa_family).
    var wrong6: [sa.SOCKADDR_IN6_LEN]u8 = @splat(0);
    _ = sa.writeInet4(wrong6[0..sa.SOCKADDR_IN_LEN], 1, ip4);
    if (sa.parseInet6(&wrong6) != null) {
        fail("v4 as v6");
        return;
    }
    if (sa.parseInet4(buf6[0..8]) != null) {
        fail("v6 as v4");
        return;
    }

    // Truncated IPv6 buffer rejected.
    if (sa.parseInet6(buf6[0..27]) != null) {
        fail("short6");
        return;
    }

    arch.serial.writeString("[SK-71] sockaddr inet6 util non-x86: OK\n");
}
