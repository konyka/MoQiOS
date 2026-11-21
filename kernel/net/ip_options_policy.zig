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

/// Options a sender gives (IP_OPTIONS, an IP_RETOPTS control message): padded with END to a multiple of 4 and checked as
/// __ip_options_compile does without an skb. A source route's first hop moves to `faddr` (the datagram is sent there, the final
/// destination goes last); RR / TS slots are left for `build` to fill. `privileged` (CAP_NET_RAW) allows unknown options and
/// timestamp flags beyond the three defined ones.
pub const SendOpts = struct {
    len: u8 = 0,
    data: [40]u8 = @splat(0),
    o: Opts = .{},
    faddr: [4]u8 = @splat(0),
};

pub fn compileForSend(in: []const u8, privileged: bool) ?SendOpts {
    if (in.len > 40) return null;
    var so: SendOpts = .{};
    @memcpy(so.data[0..in.len], in);
    var n = in.len;
    while (n & 3 != 0) : (n += 1) so.data[n] = IPOPT_END;
    so.len = @intCast(n);
    so.o.optlen = so.len;
    const opts = so.data[0..n];
    var i: usize = 0;
    while (i < n) {
        switch (opts[i]) {
            IPOPT_END => {
                var k = i + 1;
                while (k < n) : (k += 1) opts[k] = IPOPT_END;
                return so;
            },
            IPOPT_NOOP => {
                i += 1;
                continue;
            },
            else => {},
        }
        const l = n - i;
        if (l < 2) return null;
        const optlen: usize = opts[i + 1];
        if (optlen < 2 or optlen > l) return null;
        const p = opts[i..][0..optlen];
        switch (p[0]) {
            IPOPT_SSRR, IPOPT_LSRR => {
                if (optlen < 3 or p[2] < 4 or so.o.srr != null) return null;
                if (p[2] != 4 or optlen < 7 or ((optlen - 3) & 3) != 0) return null;
                so.faddr = p[3..7].*;
                if (optlen > 7) std.mem.copyForwards(u8, p[3 .. optlen - 4], p[7..optlen]);
                so.o.srr = @intCast(i);
            },
            IPOPT_RR => {
                if (so.o.rr != null or optlen < 3 or p[2] < 4) return null;
                if (p[2] <= optlen) {
                    if (@as(usize, p[2]) + 3 > optlen) return null;
                    p[2] += 4;
                    so.o.rr_needaddr = true;
                }
                so.o.rr = @intCast(i);
            },
            IPOPT_TIMESTAMP => {
                if (so.o.ts != null or optlen < 4 or p[2] < 5) return null;
                if (p[2] <= optlen) {
                    if (@as(usize, p[2]) + 3 > optlen) return null;
                    switch (p[3] & 0xF) {
                        IPOPT_TS_TSONLY => {
                            so.o.ts_needtime = true;
                            p[2] += 4;
                        },
                        IPOPT_TS_TSANDADDR => {
                            if (@as(usize, p[2]) + 7 > optlen) return null;
                            so.o.ts_needaddr = true;
                            so.o.ts_needtime = true;
                            p[2] += 8;
                        },
                        IPOPT_TS_PRESPEC => {
                            if (@as(usize, p[2]) + 7 > optlen) return null;
                            so.o.ts_needtime = true;
                            p[2] += 8;
                        },
                        else => if (!privileged) return null,
                    }
                } else if ((p[3] & 0xF) != IPOPT_TS_PRESPEC) {
                    if (p[3] >> 4 == 15) return null;
                }
                so.o.ts = @intCast(i);
            },
            IPOPT_RA => {
                if (optlen < 4) return null;
                if (p[2] == 0 and p[3] == 0) so.o.router_alert = @intCast(i);
            },
            else => if (!privileged) return null,
        }
        i += optlen;
    }
    return so;
}

/// ip_options_build: the options as they go out in a header from `src` to the final destination `daddr`: a source route ends with
/// `daddr`, record route and timestamp slots get `src` and the time.
pub fn build(so: SendOpts, src: [4]u8, daddr: [4]u8, ms_since_midnight: u32, out: *[40]u8) void {
    out.* = so.data;
    if (so.o.srr) |r| @memcpy(out[r + out[r + 1] - 4 ..][0..4], &daddr);
    if (so.o.rr_needaddr) {
        const r = so.o.rr.?;
        @memcpy(out[r + out[r + 2] - 5 ..][0..4], &src);
    }
    if (so.o.ts) |t| {
        if (so.o.ts_needaddr) @memcpy(out[t + out[t + 2] - 9 ..][0..4], &src);
        if (so.o.ts_needtime) {
            var tm: [4]u8 = undefined;
            std.mem.writeInt(u32, &tm, ms_since_midnight, .big);
            @memcpy(out[t + out[t + 2] - 5 ..][0..4], &tm);
        }
    }
}

/// ip_options_fragment: the options of every fragment after the first, from the first's built `opts` (`len` bytes): an option whose
/// copied bit (0x80) is clear becomes NOPs; END stops the walk.
pub fn fragmentOpts(opts: []u8) void {
    var i: usize = 0;
    while (i < opts.len) {
        switch (opts[i]) {
            IPOPT_END => return,
            IPOPT_NOOP => {
                i += 1;
                continue;
            },
            else => {},
        }
        if (i + 1 >= opts.len) return;
        const optlen: usize = opts[i + 1];
        if (optlen < 2 or optlen > opts.len - i) return;
        if (opts[i] & 0x80 == 0) @memset(opts[i..][0..optlen], IPOPT_NOOP);
        i += optlen;
    }
}

test "later fragments keep only the copied options (router alert), the rest become NOPs" {
    var o = [_]u8{ 7, 7, 8, 127, 0, 0, 1, 0x94, 4, 0, 0, 1, 1, 1, 0, 0 };
    fragmentOpts(&o);
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1, 1, 1, 1, 0x94, 4, 0, 0, 1, 1, 1, 0, 0 }, &o);
}

/// getsockopt(IP_OPTIONS): the options as the user gave them back (a source route's first hop restored, ip_options_undo).
pub fn userView(so: SendOpts, out: *[40]u8) usize {
    out.* = so.data;
    if (so.o.srr) |r| {
        const optlen = out[r + 1];
        std.mem.copyBackwards(u8, out[r + 7 .. r + optlen], out[r + 3 .. r + optlen - 4]);
        @memcpy(out[r + 3 ..][0..4], &so.faddr);
    }
    if (so.o.rr_needaddr) {
        const r = so.o.rr.?;
        out[r + 2] -= 4;
        @memset(out[r + out[r + 2] - 1 ..][0..4], 0);
    }
    if (so.o.ts) |t| {
        if (so.o.ts_needtime) {
            out[t + 2] -= 4;
            @memset(out[t + out[t + 2] - 1 ..][0..4], 0);
            if ((out[t + 3] & 0xF) == IPOPT_TS_PRESPEC) out[t + 2] -= 4;
        }
        if (so.o.ts_needaddr) {
            out[t + 2] -= 4;
            @memset(out[t + out[t + 2] - 1 ..][0..4], 0);
        }
    }
    return so.len;
}

test "IP_OPTIONS: a 7-byte record route is padded to 8, built with the source, read back as given" {
    const so = compileForSend(&.{ 7, 7, 4, 0, 0, 0, 0 }, false).?;
    try std.testing.expectEqual(@as(u8, 8), so.len);
    var out: [40]u8 = undefined;
    build(so, .{ 127, 0, 0, 1 }, .{ 127, 0, 0, 1 }, 0, &out);
    try std.testing.expectEqualSlices(u8, &.{ 7, 7, 8, 127, 0, 0, 1, 0 }, out[0..8]);
    var back: [40]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 8), userView(so, &back));
    try std.testing.expectEqualSlices(u8, &.{ 7, 7, 4, 0, 0, 0, 0, 0 }, back[0..8]);
    try std.testing.expect(compileForSend(&.{ 0x44, 12, 5, 0 }, false) == null);
    try std.testing.expect(compileForSend(&.{ 7, 2 }, false) == null);
    try std.testing.expect(compileForSend(&.{ 0x82, 4, 0, 0 }, false) == null);
    try std.testing.expect(compileForSend(&.{ 0x82, 4, 0, 0 }, true) != null);
    var big: [41]u8 = @splat(1);
    try std.testing.expect(compileForSend(&big, true) == null);
}

test "a loose source route sends to its first hop and reads back unchanged" {
    const so = compileForSend(&.{ 0x83, 7, 4, 127, 0, 0, 1 }, false).?;
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &so.faddr);
    var back: [40]u8 = undefined;
    _ = userView(so, &back);
    try std.testing.expectEqualSlices(u8, &.{ 0x83, 7, 4, 127, 0, 0, 1, 0 }, back[0..8]);
}

/// inet_current_timestamp: the milliseconds since midnight UTC of the real-time clock reading `wall_ns`.
pub fn msSinceMidnight(wall_ns: u64) u32 {
    return @intCast((wall_ns / std.time.ns_per_ms) % (24 * 60 * 60 * 1000));
}

test "the timestamp counts from midnight UTC" {
    try std.testing.expectEqual(@as(u32, 0), msSinceMidnight(86_400 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(u32, 3_600_000 + 5), msSinceMidnight(3 * 86_400 * std.time.ns_per_s + 3_600_005 * std.time.ns_per_ms));
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
