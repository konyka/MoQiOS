//! Network-interface ioctls (netdevice(7)) as pure encoding rules.
//!
//! `struct ifreq` is 40 bytes: a 16-byte NUL-terminated name, then a union
//! whose first member (sockaddr, 16 bytes) is what the address requests fill.

const std = @import("std");

pub const IFNAMSIZ: usize = 16;
pub const IFREQ_SIZE: usize = 40;

pub const SIOCGIFNAME: u64 = 0x8910;
pub const SIOCGIFCONF: u64 = 0x8912;
pub const SIOCGIFFLAGS: u64 = 0x8913;
pub const SIOCGIFADDR: u64 = 0x8915;
pub const SIOCGIFBRDADDR: u64 = 0x8919;
pub const SIOCGIFNETMASK: u64 = 0x891b;
pub const SIOCGIFMTU: u64 = 0x8921;
pub const SIOCGIFHWADDR: u64 = 0x8927;
pub const SIOCGIFINDEX: u64 = 0x8933;

pub const IFF_UP: u16 = 0x1;
pub const IFF_BROADCAST: u16 = 0x2;
pub const IFF_LOOPBACK: u16 = 0x8;
pub const IFF_RUNNING: u16 = 0x40;
pub const IFF_MULTICAST: u16 = 0x1000;

pub const AF_INET: u16 = 2;
pub const ARPHRD_ETHER: u16 = 1;
pub const ARPHRD_LOOPBACK: u16 = 772;

pub const ENODEV: i64 = -19;
pub const EADDRNOTAVAIL: i64 = -99;
pub const EINVAL: i64 = -22;

pub const Iface = struct {
    name: [IFNAMSIZ]u8 = @splat(0),
    index: u32 = 0,
    flags: u16 = 0,
    ip: [4]u8 = .{ 0, 0, 0, 0 },
    netmask: [4]u8 = .{ 0, 0, 0, 0 },
    mac: [6]u8 = @splat(0),
    mtu: u32 = 0,
    loopback: bool = false,
};

pub const MAX_IFACES: usize = 2;

pub fn makeName(s: []const u8) [IFNAMSIZ]u8 {
    var out: [IFNAMSIZ]u8 = @splat(0);
    @memcpy(out[0..s.len], s);
    return out;
}

pub fn isRequest(cmd: u64) bool {
    return switch (cmd) {
        SIOCGIFNAME, SIOCGIFCONF, SIOCGIFFLAGS, SIOCGIFADDR, SIOCGIFBRDADDR, SIOCGIFNETMASK, SIOCGIFMTU, SIOCGIFHWADDR, SIOCGIFINDEX => true,
        else => false,
    };
}

fn nameLen(name: *const [IFNAMSIZ]u8) usize {
    return std.mem.indexOfScalar(u8, name, 0) orelse IFNAMSIZ;
}

/// The interface an ifreq name selects. The name field must be NUL-terminated
/// within its 16 bytes; a name with no terminator names nothing.
pub fn findByName(ifs: []const Iface, name: *const [IFNAMSIZ]u8) ?usize {
    const n = nameLen(name);
    if (n == IFNAMSIZ or n == 0) return null;
    for (ifs, 0..) |i, k| {
        if (std.mem.eql(u8, i.name[0..nameLen(&i.name)], name[0..n])) return k;
    }
    return null;
}

pub fn findByIndex(ifs: []const Iface, index: u32) ?usize {
    for (ifs, 0..) |i, k| {
        if (i.index == index) return k;
    }
    return null;
}

fn putSockaddrIn(buf: *[IFREQ_SIZE]u8, ip: [4]u8) void {
    @memset(buf[IFNAMSIZ..], 0);
    std.mem.writeInt(u16, buf[16..18], AF_INET, .little);
    @memcpy(buf[20..24], &ip);
}

/// Broadcast address of an address/netmask pair; loopback has none.
pub fn broadcast(i: Iface) ?[4]u8 {
    if (i.loopback or i.flags & IFF_BROADCAST == 0) return null;
    var b: [4]u8 = undefined;
    for (0..4) |k| b[k] = i.ip[k] | ~i.netmask[k];
    return b;
}

/// Answer a per-interface request into `buf` (whose name field the caller has
/// already filled in for everything but SIOCGIFNAME). 0 or a negative errno.
pub fn answer(cmd: u64, i: Iface, buf: *[IFREQ_SIZE]u8) i64 {
    switch (cmd) {
        SIOCGIFNAME => {
            @memset(buf[0..IFNAMSIZ], 0);
            @memcpy(buf[0..IFNAMSIZ], &i.name);
        },
        SIOCGIFFLAGS => {
            @memset(buf[IFNAMSIZ..], 0);
            std.mem.writeInt(u16, buf[16..18], i.flags, .little);
        },
        SIOCGIFADDR => putSockaddrIn(buf, i.ip),
        SIOCGIFNETMASK => putSockaddrIn(buf, i.netmask),
        SIOCGIFBRDADDR => putSockaddrIn(buf, broadcast(i) orelse return EADDRNOTAVAIL),
        SIOCGIFMTU => {
            @memset(buf[IFNAMSIZ..], 0);
            std.mem.writeInt(u32, buf[16..20], i.mtu, .little);
        },
        SIOCGIFINDEX => {
            @memset(buf[IFNAMSIZ..], 0);
            std.mem.writeInt(u32, buf[16..20], i.index, .little);
        },
        SIOCGIFHWADDR => {
            @memset(buf[IFNAMSIZ..], 0);
            std.mem.writeInt(u16, buf[16..18], if (i.loopback) ARPHRD_LOOPBACK else ARPHRD_ETHER, .little);
            @memcpy(buf[18..24], &i.mac);
        },
        else => return EINVAL,
    }
    return 0;
}

/// Bytes SIOCGIFCONF needs to list every interface.
pub fn confSize(count: usize) usize {
    return count * IFREQ_SIZE;
}

/// How many ifreq records fit a caller buffer of `len` bytes.
pub fn confFit(count: usize, len: usize) usize {
    return @min(count, len / IFREQ_SIZE);
}

/// One SIOCGIFCONF record: name plus the IPv4 address.
pub fn confRecord(i: Iface, buf: *[IFREQ_SIZE]u8) void {
    @memset(buf, 0);
    @memcpy(buf[0..IFNAMSIZ], &i.name);
    putSockaddrIn(buf, i.ip);
}
