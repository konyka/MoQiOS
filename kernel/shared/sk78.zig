//! SK-78 — TCP sockaddr_in6 bind/connect + AddrInfo name encode on non-x86.
//!
//! SK-77 shared the data path. Syscalls still treated TCP as IPv4-only for
//! connect and getsockname/getpeername/accept peer fill. This probe locks
//! `tcpConnectSocketV6` → syn_sent and `encodeInetName` from AddrInfo.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");
const sa = @import("../net/sockaddr_util.zig");
const ndp = @import("../net/ndp.zig");
const ipv6 = @import("../net/ipv6.zig");

const PEER6: [16]u8 = .{
    0xfe, 0x80, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x78,
};
const LOCAL: u16 = 9100;
const REMOTE: u16 = 43000;
const PEER_MAC = [6]u8{ 0x02, 0, 0, 0x78, 0x00, 0x01 };

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-78] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-78] tcp sockaddr_in6 connect name non-x86: OK\n");
        return;
    }

    tcp.initTcbs();
    ndp.init();
    ndp.update(PEER6, PEER_MAC);

    // Family mismatch: v6 TCB rejects IPv4 connect helper.
    const sock0 = tcp.tcpSocket(0);
    if (sock0 < 0 or tcp.tcpSetIpv6(@intCast(sock0)) < 0) {
        fail("sock0");
        return;
    }
    if (tcp.tcpConnectSocket(@intCast(sock0), .{ 10, 0, 2, 15 }, REMOTE) == 0) {
        fail("v4 connect on v6");
        return;
    }

    // IPv6 connect with NDP → syn_sent and peer tuple visible.
    const sock1 = tcp.tcpSocket(0);
    if (sock1 < 0 or tcp.tcpSetIpv6(@intCast(sock1)) < 0 or
        tcp.tcpBind(@intCast(sock1), LOCAL) < 0)
    {
        fail("sock1 bind");
        return;
    }
    if (tcp.tcpConnectSocketV6(@intCast(sock1), PEER6, REMOTE) < 0) {
        fail("connect v6");
        return;
    }
    if (!tcp.tcpProbeIsSynSentV6(LOCAL, REMOTE, PEER6)) {
        fail("syn_sent");
        return;
    }

    const info = tcp.tcpGetAddrInfo(@intCast(sock1)) orelse {
        fail("addrinfo");
        return;
    };
    if (!info.is_v6 or info.local_port != LOCAL or info.remote_port != REMOTE or
        !ipv6.addrEq(info.remote_ip6, PEER6))
    {
        fail("addrinfo fields");
        return;
    }

    var out: [sa.SOCKADDR_IN6_LEN]u8 = undefined;
    const n_peer = sa.encodeInetName(true, info.remote_port, info.remote_ip, info.remote_ip6, &out);
    if (n_peer != sa.SOCKADDR_IN6_LEN) {
        fail("peer len");
        return;
    }
    const peer = sa.parseInet6(out[0..n_peer]) orelse {
        fail("peer parse");
        return;
    };
    if (peer.port != REMOTE or !ipv6.addrEq(peer.addr, PEER6)) {
        fail("peer fields");
        return;
    }

    @memset(&out, 0);
    const n_local = sa.encodeInetName(true, info.local_port, info.local_ip, info.local_ip6, &out);
    if (n_local != sa.SOCKADDR_IN6_LEN) {
        fail("local len");
        return;
    }
    const local = sa.parseInet6(out[0..n_local]) orelse {
        fail("local parse");
        return;
    };
    if (local.port != LOCAL) {
        fail("local port");
        return;
    }

    arch.serial.writeString("[SK-78] tcp sockaddr_in6 connect name non-x86: OK\n");
}
