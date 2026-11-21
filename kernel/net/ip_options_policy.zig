//! IPv4 options of a received datagram (Linux net/ipv4/ip_options.c: __ip_options_compile with an skb, __ip_options_echo,
//! ip_options_undo). Pure, host-tested.
//!
//! `compile` walks the options after the 20-byte header the way ip_rcv_options does for a datagram this host receives: END pads
//! the rest with END, NOP is one byte, every other option has a length byte. Record route gets this host's address written into its
//! next slot and the pointer advanced; a timestamp option gets the time (and, for TSANDADDR, the address) or its overflow counter
//! bumped; router alert is noted. A malformed option makes the datagram invalid (it is dropped). A source route option is reported
//! too, so the caller drops it (accept_source_route is 0).
//!
//! `echo` builds what IP_RETOPTS reports: the options a reply would carry (ip_options_echo), with this host's own additions taken
//! back out (ip_options_undo).

const std = @import("std");

pub const IPOPT_END: u8 = 0;
pub const IPOPT_NOOP: u8 = 1;
pub const IPOPT_RR: u8 = 7;
pub const IPOPT_TIMESTAMP: u8 = 68;
pub const IPOPT_RA: u8 = 148;
pub const IPOPT_LSRR: u8 = 131;
pub const IPOPT_SSRR: u8 = 137;
pub const IPOPT_CIPSO: u8 = 134;

pub const IPOPT_TS_TSONLY: u8 = 0;
pub const IPOPT_TS_TSANDADDR: u8 = 1;
pub const IPOPT_TS_PRESPEC: u8 = 3;

/// What compile found: offsets are from the start of the options (Linux keeps them from the IP header, 20 more).
pub const Opts = struct {
    optlen: u8 = 0,
    rr: ?u8 = null,
    rr_needaddr: bool = false,
    ts: ?u8 = null,
    ts_needaddr: bool = false,
    ts_needtime: bool = false,
    srr: ?u8 = null,
    router_alert: ?u8 = null,
    cipso: ?u8 = null,
};

pub const Compiled = union(enum) { ok: Opts, bad: u8 };

/// __ip_options_compile for a received datagram: `opts` are the bytes after the 20-byte header (modified in place, as Linux does),
/// `spec_dst` the address this host records, `ms_since_midnight` the time a timestamp records. `.bad` carries the offset (from the
/// IP header) of the offending byte. `local` tells whether `addr` is one of this host's unicast addresses (TS_PRESPEC).
pub fn compile(opts: []u8, spec_dst: [4]u8, ms_since_midnight: u32, local: *const fn ([4]u8) bool) Compiled {
    var o: Opts = .{ .optlen = @intCast(opts.len) };
    var i: usize = 0;
    while (i < opts.len) {
        switch (opts[i]) {
            IPOPT_END => {
                var k = i + 1;
                while (k < opts.len) : (k += 1) opts[k] = IPOPT_END;
                return .{ .ok = o };
            },
            IPOPT_NOOP => {
                i += 1;
                continue;
            },
            else => {},
        }
        const l = opts.len - i;
        if (l < 2) return .{ .bad = @intCast(20 + i) };
        const optlen: usize = opts[i + 1];
        if (optlen < 2 or optlen > l) return .{ .bad = @intCast(20 + i) };
        const p = opts[i..][0..optlen];
        switch (p[0]) {
            IPOPT_SSRR, IPOPT_LSRR => {
                if (optlen < 3) return .{ .bad = @intCast(20 + i + 1) };
                if (p[2] < 4) return .{ .bad = @intCast(20 + i + 2) };
                if (o.srr != null) return .{ .bad = @intCast(20 + i) };
                o.srr = @intCast(i);
            },
            IPOPT_RR => {
                if (o.rr != null) return .{ .bad = @intCast(20 + i) };
                if (optlen < 3) return .{ .bad = @intCast(20 + i + 1) };
                if (p[2] < 4) return .{ .bad = @intCast(20 + i + 2) };
                if (p[2] <= optlen) {
                    if (@as(usize, p[2]) + 3 > optlen) return .{ .bad = @intCast(20 + i + 2) };
                    @memcpy(p[p[2] - 1 ..][0..4], &spec_dst);
                    p[2] += 4;
                    o.rr_needaddr = true;
                }
                o.rr = @intCast(i);
            },
            IPOPT_TIMESTAMP => {
                if (o.ts != null) return .{ .bad = @intCast(20 + i) };
                if (optlen < 4) return .{ .bad = @intCast(20 + i + 1) };
                if (p[2] < 5) return .{ .bad = @intCast(20 + i + 2) };
                if (p[2] <= optlen) {
                    if (@as(usize, p[2]) + 3 > optlen) return .{ .bad = @intCast(20 + i + 2) };
                    var t: [4]u8 = undefined;
                    std.mem.writeInt(u32, &t, ms_since_midnight, .big);
                    switch (p[3] & 0xF) {
                        IPOPT_TS_TSONLY => {
                            @memcpy(p[p[2] - 1 ..][0..4], &t);
                            o.ts_needtime = true;
                            p[2] += 4;
                        },
                        IPOPT_TS_TSANDADDR => {
                            if (@as(usize, p[2]) + 7 > optlen) return .{ .bad = @intCast(20 + i + 2) };
                            @memcpy(p[p[2] - 1 ..][0..4], &spec_dst);
                            @memcpy(p[p[2] + 3 ..][0..4], &t);
                            o.ts_needaddr = true;
                            o.ts_needtime = true;
                            p[2] += 8;
                        },
                        IPOPT_TS_PRESPEC => {
                            if (@as(usize, p[2]) + 7 > optlen) return .{ .bad = @intCast(20 + i + 2) };
                            const addr = p[p[2] - 1 ..][0..4].*;
                            if (!local(addr)) {
                                @memcpy(p[p[2] + 3 ..][0..4], &t);
                                o.ts_needtime = true;
                                p[2] += 8;
                            }
                        },
                        else => {},
                    }
                } else if ((p[3] & 0xF) != IPOPT_TS_PRESPEC) {
                    const overflow = p[3] >> 4;
                    if (overflow == 15) return .{ .bad = @intCast(20 + i + 3) };
                    p[3] = (p[3] & 0xF) | ((overflow + 1) << 4);
                }
                o.ts = @intCast(i);
            },
            IPOPT_RA => {
                if (optlen < 4) return .{ .bad = @intCast(20 + i + 1) };
                if (p[2] == 0 and p[3] == 0) o.router_alert = @intCast(i);
            },
            IPOPT_CIPSO => {
                if (o.cipso != null) return .{ .bad = @intCast(20 + i) };
                o.cipso = @intCast(i);
            },
            else => {},
        }
        i += optlen;
    }
    return .{ .ok = o };
}

/// The options a reply to a datagram would carry (ip_options_echo), with this host's own additions taken back out (ip_options_undo):
/// what IP_RETOPTS reports. `opts` are the received datagram's options as compile left them, `src` its source address. Returns
/// the length written to `out` (a multiple of 4), or null when the options cannot be echoed (MSG_CTRUNC).
pub fn echo(opts: []const u8, o: Opts, src: [4]u8, out: *[40]u8) ?usize {
    _ = src;
    var n: usize = 0;
    var rr_at: ?usize = null;
    var ts_at: ?usize = null;
    var rr_needaddr = false;
    var ts_needaddr = false;
    var ts_needtime = false;
    if (o.rr) |r| {
        const optlen: usize = opts[r + 1];
        const soffset: usize = opts[r + 2];
        rr_at = n;
        @memcpy(out[n..][0..optlen], opts[r..][0..optlen]);
        if (o.rr_needaddr and soffset <= optlen) {
            if (soffset + 3 > optlen) return null;
            out[n + 2] = @intCast(soffset + 4);
            rr_needaddr = true;
        }
        n += optlen;
    }
    if (o.ts) |t| {
        const optlen: usize = opts[t + 1];
        var soffset: usize = opts[t + 2];
        ts_at = n;
        @memcpy(out[n..][0..optlen], opts[t..][0..optlen]);
        if (soffset <= optlen) {
            if (o.ts_needaddr) {
                if (soffset + 3 > optlen) return null;
                ts_needaddr = true;
                soffset += 4;
            }
            if (o.ts_needtime) {
                if (soffset + 3 > optlen) return null;
                if ((out[n + 3] & 0xF) != IPOPT_TS_PRESPEC) {
                    ts_needtime = true;
                    soffset += 4;
                }
            }
            out[n + 2] = @intCast(soffset);
        }
        n += optlen;
    }
    if (o.cipso) |c| {
        const optlen: usize = opts[c + 1];
        @memcpy(out[n..][0..optlen], opts[c..][0..optlen]);
        n += optlen;
    }
    while (n & 3 != 0) : (n += 1) out[n] = IPOPT_END;
    // ip_options_undo: the addresses and times this host would add for the reply are taken back out.
    if (rr_needaddr) {
        const r = rr_at.?;
        out[r + 2] -= 4;
        @memset(out[r + out[r + 2] - 1 ..][0..4], 0);
    }
    if (ts_at) |t| {
        if (ts_needtime) {
            out[t + 2] -= 4;
            @memset(out[t + out[t + 2] - 1 ..][0..4], 0);
            if ((out[t + 3] & 0xF) == IPOPT_TS_PRESPEC) out[t + 2] -= 4;
        }
        if (ts_needaddr) {
            out[t + 2] -= 4;
            @memset(out[t + out[t + 2] - 1 ..][0..4], 0);
        }
    }
    return n;
}

fn notLocal(_: [4]u8) bool {
    return false;
}

test "record route: the receiver records itself; IP_RETOPTS shows the route without it" {
    var o = [_]u8{ 7, 7, 4, 0, 0, 0, 0, 0 };
    const c = compile(&o, .{ 127, 0, 0, 1 }, 0, &notLocal).ok;
    try std.testing.expectEqualSlices(u8, &.{ 7, 7, 8, 127, 0, 0, 1, 0 }, &o);
    var out: [40]u8 = undefined;
    const n = echo(&o, c, .{ 127, 0, 0, 1 }, &out).?;
    try std.testing.expectEqualSlices(u8, &.{ 7, 7, 8, 127, 0, 0, 1, 0 }, out[0..n]);
}

test "a full record route is echoed as it came; NOP NOP NOP END is left alone" {
    var o = [_]u8{ 7, 3, 4, 0, 0, 0, 0, 0 };
    const c = compile(&o, .{ 127, 0, 0, 1 }, 0, &notLocal).ok;
    var out: [40]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 7, 3, 4, 0 }, out[0..echo(&o, c, .{ 0, 0, 0, 0 }, &out).?]);
    var e = [_]u8{ 1, 1, 1, 0, 0, 0, 0, 0 };
    const ce = compile(&e, .{ 127, 0, 0, 1 }, 0, &notLocal).ok;
    try std.testing.expectEqual(@as(usize, 0), echo(&e, ce, .{ 0, 0, 0, 0 }, &out).?);
}

test "a timestamp gets the time; a malformed option is rejected at its offset" {
    var t = [_]u8{ 68, 8, 5, 0, 0, 0, 0, 0 };
    _ = compile(&t, .{ 127, 0, 0, 1 }, 0x01020304, &notLocal).ok;
    try std.testing.expectEqualSlices(u8, &.{ 68, 8, 9, 0, 1, 2, 3, 4 }, &t);
    var bad = [_]u8{ 7, 2, 4, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(u8, 21), compile(&bad, .{ 127, 0, 0, 1 }, 0, &notLocal).bad);
    var long = [_]u8{ 7, 9, 4, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(u8, 20), compile(&long, .{ 127, 0, 0, 1 }, 0, &notLocal).bad);
}
