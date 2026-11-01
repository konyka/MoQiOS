//! IP-level socket options (SOL_IP / SOL_IPV6): TTL, TOS, hop limit, traffic
//! class and IPV6_V6ONLY as pure validation, encoding and header-patch rules.

const std = @import("std");

pub const SOL_IP: u64 = 0;
pub const SOL_IPV6: u64 = 41;

pub const IP_TOS: u64 = 1;
pub const IP_TTL: u64 = 2;
pub const IPV6_UNICAST_HOPS: u64 = 16;
pub const IPV6_V6ONLY: u64 = 26;
pub const IPV6_TCLASS: u64 = 67;

pub const DEFAULT_TTL: u8 = 64;
/// The two low bits of TOS / traffic class belong to ECN, which TCP manages itself.
pub const ECN_MASK: u8 = 0x03;

/// Per-socket values; 0 means "not set, use the default".
pub const IpOpts = struct {
    ttl: u8 = 0,
    tos: u8 = 0,
    hops: u8 = 0,
    tclass: u8 = 0,
};

pub const Family = enum { v4, v6 };

/// Which level a socket of this family answers.
pub fn levelApplies(level: u64, family: Family) bool {
    return switch (family) {
        .v4 => level == SOL_IP,
        .v6 => level == SOL_IPV6,
    };
}

/// An option value as the kernel reads it: an int, or a single byte for the
/// byte-sized options when the caller passes only one byte.
pub fn readInt(val: []const u8) ?i32 {
    if (val.len >= 4) return std.mem.readInt(i32, val[0..4], .little);
    if (val.len == 1) return val[0];
    return null;
}

pub const SetResult = union(enum) { ok: IpOpts, err: i64 };

/// Apply setsockopt(level, optname, val) to `cur`.
pub fn applySet(cur: IpOpts, level: u64, optname: u64, val: []const u8) SetResult {
    const v = readInt(val) orelse return .{ .err = -22 };
    var o = cur;
    switch (level) {
        SOL_IP => switch (optname) {
            // 1..255 sets, -1 restores the default; 0 and anything else is invalid.
            IP_TTL => {
                if (v == -1) {
                    o.ttl = 0;
                } else if (v >= 1 and v <= 255) {
                    o.ttl = @intCast(v);
                } else return .{ .err = -22 };
            },
            // Only the low byte; the ECN bits are not the user's to set.
            IP_TOS => o.tos = @as(u8, @truncate(@as(u32, @bitCast(v)))) & ~ECN_MASK,
            else => return .{ .err = -92 },
        },
        SOL_IPV6 => switch (optname) {
            IPV6_UNICAST_HOPS => {
                if (v == -1) {
                    o.hops = 0;
                } else if (v >= 0 and v <= 255) {
                    // 0 is a legal hop limit on the wire but useless; keep it distinct from "unset".
                    o.hops = if (v == 0) 1 else @intCast(v);
                } else return .{ .err = -22 };
            },
            IPV6_TCLASS => {
                if (v == -1) {
                    o.tclass = 0;
                } else if (v >= 0 and v <= 255) {
                    o.tclass = @as(u8, @intCast(v)) & ~ECN_MASK;
                } else return .{ .err = -22 };
            },
            IPV6_V6ONLY => {
                // This stack has no IPv4-mapped dual-stack: an AF_INET6 socket is always v6-only.
                if (v == 0) return .{ .err = -22 };
            },
            else => return .{ .err = -92 },
        },
        else => return .{ .err = -92 },
    }
    return .{ .ok = o };
}

/// getsockopt value as an int, or null when the option does not exist.
pub fn getValue(o: IpOpts, level: u64, optname: u64) ?i32 {
    return switch (level) {
        SOL_IP => switch (optname) {
            IP_TTL => if (o.ttl == 0) DEFAULT_TTL else o.ttl,
            IP_TOS => o.tos,
            else => null,
        },
        SOL_IPV6 => switch (optname) {
            IPV6_UNICAST_HOPS => if (o.hops == 0) DEFAULT_TTL else o.hops,
            IPV6_TCLASS => o.tclass,
            IPV6_V6ONLY => 1,
            else => null,
        },
        else => null,
    };
}

/// The TTL / TOS to put in an IPv4 header (defaults when unset).
pub fn effectiveTtl(o: IpOpts) u8 {
    return if (o.ttl == 0) DEFAULT_TTL else o.ttl;
}

pub fn effectiveHops(o: IpOpts) u8 {
    return if (o.hops == 0) DEFAULT_TTL else o.hops;
}

/// Whether the header needs patching at all (everything default: leave it).
pub fn ipv4NeedsPatch(o: IpOpts) bool {
    return o.ttl != 0 or o.tos != 0;
}

pub fn ipv6NeedsPatch(o: IpOpts) bool {
    return o.hops != 0 or o.tclass != 0;
}

/// Patch an IPv4 header's TTL (byte 8) and TOS (byte 1) keeping the ECN bits
/// already there, then recompute the header checksum. `csum` computes the
/// RFC 1071 sum over the 20 header bytes.
pub fn patchIpv4(hdr: *[20]u8, o: IpOpts, csum: *const fn ([*]const u8, u16) u16) void {
    hdr[8] = effectiveTtl(o);
    hdr[1] = (hdr[1] & ECN_MASK) | o.tos;
    hdr[10] = 0;
    hdr[11] = 0;
    std.mem.writeInt(u16, hdr[10..12], csum(hdr, 20), .big);
}

/// Patch an IPv6 header's hop limit (byte 7) and traffic class (bits 20..27),
/// keeping the ECN bits already there.
pub fn patchIpv6(hdr: *[40]u8, o: IpOpts) void {
    hdr[7] = effectiveHops(o);
    const old_tc: u8 = ((hdr[0] & 0x0f) << 4) | (hdr[1] >> 4);
    const tc: u8 = (old_tc & ECN_MASK) | o.tclass;
    hdr[0] = (hdr[0] & 0xF0) | (tc >> 4);
    hdr[1] = (hdr[1] & 0x0F) | (tc << 4);
}
