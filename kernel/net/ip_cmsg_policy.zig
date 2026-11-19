//! IPv4 and IPv6 receive control messages (Linux ip_cmsg_recv_offset, ip_cmsg_recv_pktinfo / _ttl / _tos, put_cmsg). A message is
//! { u64 cmsg_len; i32 level; i32 type; data } padded to 8 bytes; IP_PKTINFO carries a struct in_pktinfo (i32 ifindex, in_addr
//! spec_dst, in_addr addr), IP_TTL an int and IP_TOS one byte, in that order. Host-testable.

const std = @import("std");
const ipo = @import("ip_opt_policy.zig");
const scm = @import("scm_policy.zig");

/// What a datagram brings with it: the interface it arrived on, the header destination (also the address a reply is sent from: this
/// stack answers from the address a datagram was sent to), TTL and TOS.
pub const RecvInfo = struct {
    ifindex: u8 = 0,
    dst: [4]u8 = .{ 0, 0, 0, 0 },
    ttl: u8 = 0,
    tos: u8 = 0,
};

pub const Wanted = struct {
    pktinfo: bool = false,
    recvttl: bool = false,
    recvtos: bool = false,

    pub fn of(o: ipo.IpOpts) Wanted {
        return .{ .pktinfo = o.pktinfo, .recvttl = o.recvttl, .recvtos = o.recvtos };
    }

    /// The IPv6 flags in the same slots: IPV6_RECVPKTINFO, IPV6_RECVHOPLIMIT, IPV6_RECVTCLASS.
    pub fn of6(o: ipo.IpOpts) Wanted {
        return .{ .pktinfo = o.pktinfo6, .recvttl = o.recvhops6, .recvtos = o.recvtclass6 };
    }
};

/// What an IPv6 datagram brings with it: the interface it arrived on, the header destination, hop limit and traffic class.
pub const RecvInfo6 = struct {
    ifindex: u8 = 0,
    dst: [16]u8 = @splat(0),
    hops: u8 = 0,
    tclass: u8 = 0,
};

pub const Built = struct {
    /// Bytes of the control buffer used (the new msg_controllen).
    written: usize,
    /// MSG_CTRUNC.
    truncated: bool,
};

/// put_cmsg: with no room for a header the message is dropped and MSG_CTRUNC set; a message longer than what is left is cut to it
/// (MSG_CTRUNC) and uses the buffer up; otherwise it takes CMSG_SPACE.
fn put(out: []u8, used: *usize, cap: usize, level: i32, typ: i32, data: []const u8, truncated: *bool) void {
    const left = cap - used.*;
    if (left < scm.HDR) {
        truncated.* = true;
        return;
    }
    var len = scm.cmsgLen(data.len);
    if (left < len) {
        truncated.* = true;
        len = left;
    }
    const base = used.*;
    // cmsg_len is written as cut (put_cmsg stores cmlen after clamping it).
    std.mem.writeInt(u64, out[base..][0..8], len, .little);
    std.mem.writeInt(i32, out[base + 8 ..][0..4], level, .little);
    std.mem.writeInt(i32, out[base + 12 ..][0..4], typ, .little);
    @memcpy(out[base + scm.HDR ..][0 .. len - scm.HDR], data[0 .. len - scm.HDR]);
    const space = @min(scm.cmsgSpace(data.len), left);
    @memset(out[base + len .. base + space], 0);
    used.* += space;
}

/// Lay out the wanted messages for `info` in a control buffer of `cap` bytes (`out` holds at least min(cap, 80) bytes).
pub fn build(w: Wanted, info: RecvInfo, cap_in: usize, out: []u8) Built {
    const cap = @min(cap_in, out.len);
    var used: usize = 0;
    var truncated = false;
    if (w.pktinfo) {
        var pi: [12]u8 = undefined;
        std.mem.writeInt(i32, pi[0..4], info.ifindex, .little);
        @memcpy(pi[4..8], &info.dst);
        @memcpy(pi[8..12], &info.dst);
        put(out, &used, cap, @intCast(ipo.SOL_IP), @intCast(ipo.IP_PKTINFO), &pi, &truncated);
    }
    if (w.recvttl) {
        var t: [4]u8 = undefined;
        std.mem.writeInt(i32, &t, info.ttl, .little);
        put(out, &used, cap, @intCast(ipo.SOL_IP), @intCast(ipo.IP_TTL), &t, &truncated);
    }
    if (w.recvtos) put(out, &used, cap, @intCast(ipo.SOL_IP), @intCast(ipo.IP_TOS), &.{info.tos}, &truncated);
    return .{ .written = used, .truncated = truncated };
}

/// ip6_datagram_recv_common_ctl then _specific_ctl: IPV6_PKTINFO (struct in6_pktinfo: in6_addr, then int ifindex), IPV6_HOPLIMIT
/// (int), IPV6_TCLASS (int), in that order (`out` holds at least min(cap, 88) bytes).
pub fn build6(w: Wanted, info: RecvInfo6, cap_in: usize, out: []u8) Built {
    const cap = @min(cap_in, out.len);
    var used: usize = 0;
    var truncated = false;
    const lv: i32 = @intCast(ipo.SOL_IPV6);
    if (w.pktinfo) {
        var pi: [20]u8 = undefined;
        @memcpy(pi[0..16], &info.dst);
        std.mem.writeInt(i32, pi[16..20], info.ifindex, .little);
        put(out, &used, cap, lv, @intCast(ipo.IPV6_PKTINFO), &pi, &truncated);
    }
    if (w.recvttl) {
        var h: [4]u8 = undefined;
        std.mem.writeInt(i32, &h, info.hops, .little);
        put(out, &used, cap, lv, @intCast(ipo.IPV6_HOPLIMIT), &h, &truncated);
    }
    if (w.recvtos) {
        var t: [4]u8 = undefined;
        std.mem.writeInt(i32, &t, info.tclass, .little);
        put(out, &used, cap, lv, @intCast(ipo.IPV6_TCLASS), &t, &truncated);
    }
    return .{ .written = used, .truncated = truncated };
}
