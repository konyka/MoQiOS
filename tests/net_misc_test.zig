const std = @import("std");
const testing = std.testing;
const ks = @import("kernel_shared");
const echo = ks.icmp_echo_policy;
const na = ks.ndp_na_policy;
const ps2 = ks.ps2_policy;
const dns = ks.dns_policy;

// ─── ICMPv4 echo reply sizing (RFC 792) ───

test "icmp echo: small request echoed in full" {
    try testing.expectEqual(@as(u16, 64), echo.replyIcmpLen(64, 1500, echo.FRAME_BUF_LEN));
}

test "icmp echo: >214-byte payload is no longer truncated to 222" {
    // 8-byte ICMP header + 1000-byte payload.
    try testing.expectEqual(@as(u16, 1008), echo.replyIcmpLen(1008, 1500, echo.FRAME_BUF_LEN));
}

test "icmp echo: full-MTU request fits one datagram" {
    try testing.expectEqual(@as(u16, 1480), echo.replyIcmpLen(1480, 1500, echo.FRAME_BUF_LEN));
    try testing.expectEqual(@as(u16, 1480), echo.replyIcmpLen(4000, 1500, echo.FRAME_BUF_LEN));
}

test "icmp echo: truncated to interface MTU" {
    try testing.expectEqual(@as(u16, 556), echo.replyIcmpLen(1480, 576, echo.FRAME_BUF_LEN));
}

test "icmp echo: truncated to frame buffer" {
    try testing.expectEqual(@as(u16, 222), echo.replyIcmpLen(1480, 1500, 256));
    try testing.expectEqual(@as(u16, 0), echo.replyIcmpLen(100, 1500, 20));
}

// ─── NA → neighbor cache (RFC 4861 §7.2.5) ───

const OLD: [6]u8 = .{ 0x52, 0x54, 0, 0, 0, 1 };
const NEW: [6]u8 = .{ 0x52, 0x54, 0, 0, 0, 2 };

fn mk(s: bool, o: bool, t: ?[6]u8) na.Na {
    var flags: u8 = 0;
    if (s) flags |= 0x40;
    if (o) flags |= 0x20;
    return na.parseFlags(flags, t);
}

test "na flags: S and O bits parsed, R ignored" {
    const a = na.parseFlags(0xE0, null);
    try testing.expect(a.solicited and a.override);
    const b = na.parseFlags(0x80, null);
    try testing.expect(!b.solicited and !b.override);
}

test "na: unsolicited NA never makes an entry reachable or rewrites it" {
    for ([_]na.EntryState{ .none, .incomplete, .reachable, .stale, .delay, .probe }) |st| {
        try testing.expectEqual(@as(?[6]u8, null), na.decide(st, mk(false, true, NEW), OLD));
        try testing.expectEqual(@as(?[6]u8, null), na.decide(st, mk(false, false, NEW), OLD));
    }
}

test "na: O=0 solicited NA with a different MAC does not overwrite a reachable entry" {
    try testing.expectEqual(@as(?[6]u8, null), na.decide(.reachable, mk(true, false, NEW), OLD));
    try testing.expectEqual(@as(?[6]u8, null), na.decide(.stale, mk(true, false, NEW), OLD));
}

test "na: O=0 solicited NA with the same MAC confirms reachability" {
    try testing.expectEqual(@as(?[6]u8, OLD), na.decide(.reachable, mk(true, false, OLD), OLD));
    try testing.expectEqual(@as(?[6]u8, OLD), na.decide(.probe, mk(true, false, OLD), OLD));
}

test "na: O=1 solicited NA installs the new MAC" {
    try testing.expectEqual(@as(?[6]u8, NEW), na.decide(.reachable, mk(true, true, NEW), OLD));
    try testing.expectEqual(@as(?[6]u8, NEW), na.decide(.delay, mk(true, true, NEW), OLD));
}

test "na: solicited NA without TLLA keeps the cached MAC" {
    try testing.expectEqual(@as(?[6]u8, OLD), na.decide(.stale, mk(true, false, null), OLD));
}

test "na: incomplete entry completed by solicited NA with TLLA only" {
    try testing.expectEqual(@as(?[6]u8, NEW), na.decide(.incomplete, mk(true, false, NEW), null));
    try testing.expectEqual(@as(?[6]u8, null), na.decide(.incomplete, mk(true, true, null), null));
}

test "na: no cache entry → NA is not used to create one" {
    try testing.expectEqual(@as(?[6]u8, null), na.decide(.none, mk(true, true, NEW), null));
}

test "na: existing entry whose MAC vanished is left alone" {
    try testing.expectEqual(@as(?[6]u8, null), na.decide(.reachable, mk(true, true, NEW), null));
}

// ─── i8042 output-byte ownership ───

test "ps2: OBF clear → nobody reads" {
    try testing.expectEqual(ps2.Owner.none, ps2.classify(0x00));
    try testing.expectEqual(ps2.Owner.none, ps2.classify(0x20)); // AUX without OBF
    try testing.expectEqual(ps2.KbdAction.ignore, ps2.keyboardAction(0x20, false));
    try testing.expect(!ps2.mouseShouldConsume(0x20));
}

test "ps2: keyboard byte goes to keyboard, not mouse" {
    try testing.expectEqual(ps2.KbdAction.consume, ps2.keyboardAction(0x01, true));
    try testing.expectEqual(ps2.KbdAction.consume, ps2.keyboardAction(0x15, false)); // other status bits set
    try testing.expect(!ps2.mouseShouldConsume(0x01));
}

test "ps2: aux byte goes to mouse, keyboard leaves it" {
    try testing.expect(ps2.mouseShouldConsume(0x21));
    try testing.expectEqual(ps2.KbdAction.ignore, ps2.keyboardAction(0x21, true));
}

test "ps2: aux byte with no mouse driver is drained by keyboard (not decoded)" {
    try testing.expectEqual(ps2.KbdAction.discard, ps2.keyboardAction(0x21, false));
}

// ─── DNS response acceptance ───

const SERVER: [4]u8 = .{ 10, 0, 2, 3 };

test "dns: matching server, port and id accepted" {
    try testing.expect(dns.acceptResponse(SERVER, 53, SERVER, 0xBEEF, 0xBEEF));
}

test "dns: response from another IP rejected" {
    try testing.expect(!dns.acceptResponse(.{ 10, 0, 2, 99 }, 53, SERVER, 0xBEEF, 0xBEEF));
}

test "dns: wrong source port rejected" {
    try testing.expect(!dns.acceptResponse(SERVER, 5353, SERVER, 0xBEEF, 0xBEEF));
}

test "dns: id mismatch rejected" {
    try testing.expect(!dns.acceptResponse(SERVER, 53, SERVER, 0xBEEE, 0xBEEF));
}
