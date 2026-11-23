//! /proc/net/if_inet6: one line per IPv6 address, as Linux's if6_seq_show prints it (net/ipv6/addrconf.c):
//! "%pi6 %02x %02x %02x %02x %8s\n" — the address as 32 lower-case hex digits, the interface index, the prefix length, the
//! scope and the low byte of the address flags, then the interface name right-aligned in eight columns.

const std = @import("std");

/// IFA_F_* (include/uapi/linux/if_addr.h), the bits of the low byte that MoQiOS addresses can carry.
pub const IFA_F_DEPRECATED: u8 = 0x20;
pub const IFA_F_TENTATIVE: u8 = 0x40;
pub const IFA_F_PERMANENT: u8 = 0x80;

/// The scope column: ipv6_addr_scope folded to the IFA_* values if6_seq_show prints — host (::1) 0x10, link-local fe80::/10
/// 0x20, site-local fec0::/10 0x40, everything else global 0.
pub fn scopeOf(addr: [16]u8) u8 {
    const loopback = [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    if (std.mem.eql(u8, &addr, &loopback)) return 0x10;
    if (addr[0] == 0xfe and (addr[1] & 0xc0) == 0x80) return 0x20;
    if (addr[0] == 0xfe and (addr[1] & 0xc0) == 0xc0) return 0x40;
    return 0;
}

/// One line into `out`; its length, or 0 when `out` is too small (nothing is written then).
pub fn formatLine(out: []u8, addr: [16]u8, ifindex: u32, prefix_len: u8, scope: u8, flags: u8, dev: []const u8) usize {
    var tmp: [96]u8 = undefined;
    var hex: [32]u8 = undefined;
    const digits = "0123456789abcdef";
    for (addr, 0..) |b, i| {
        hex[2 * i] = digits[b >> 4];
        hex[2 * i + 1] = digits[b & 15];
    }
    const line = std.fmt.bufPrint(&tmp, "{s} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {s: >8}\n", .{ hex, ifindex, prefix_len, scope, flags, dev }) catch return 0;
    if (line.len > out.len) return 0;
    @memcpy(out[0..line.len], line);
    return line.len;
}
