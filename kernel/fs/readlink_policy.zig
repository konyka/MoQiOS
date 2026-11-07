//! Pure fd-number parser for /proc/self/fd/N readlink targets.

/// Parse the leading decimal digits of `s` (trailing non-digits ignored).
/// Returns null on u32 overflow so the caller rejects with EINVAL instead of
/// panicking (Debug) or wrapping onto another fd. Same overflow-checked
/// pattern as vfs.zig parseU32.
pub fn parseFdPrefix(s: []const u8) ?u32 {
    var v: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        const product = @mulWithOverflow(v, @as(u32, 10));
        if (product[1] != 0) return null;
        const sum = @addWithOverflow(product[0], @as(u32, c - '0'));
        if (sum[1] != 0) return null;
        v = sum[0];
    }
    return v;
}

const std = @import("std");

/// The text /proc/self/fd/N reads back as for an anonymous object: "anon_inode:[eventpoll]" and the like, copied as given.
pub fn anonLink(text: []const u8, out: []u8) ?usize {
    if (text.len > out.len) return null;
    @memcpy(out[0..text.len], text);
    return text.len;
}

/// "pipe:[<number>]" or "socket:[<number>]": `kind` is the word before the colon and `number` the object's identity (a pipe or socket index
/// here, an inode number on Linux). Returns the length written to `out`, or null when it does not fit.
pub fn numberedLink(kind: []const u8, number: u64, out: []u8) ?usize {
    var digits: [20]u8 = undefined;
    var dn: usize = 0;
    var v = number;
    if (v == 0) {
        digits[0] = '0';
        dn = 1;
    }
    while (v > 0) : (v /= 10) {
        digits[dn] = '0' + @as(u8, @intCast(v % 10));
        dn += 1;
    }
    if (kind.len + 2 + dn + 1 > out.len) return null;
    @memcpy(out[0..kind.len], kind);
    var w: usize = kind.len;
    out[w] = ':';
    out[w + 1] = '[';
    w += 2;
    var i: usize = 0;
    while (i < dn) : (i += 1) out[w + i] = digits[dn - 1 - i];
    w += dn;
    out[w] = ']';
    return w + 1;
}

test "readlink policy: pipe and socket links carry the object number, anon_inode links are fixed text" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("pipe:[7]", b[0..numberedLink("pipe", 7, &b).?]);
    try std.testing.expectEqualStrings("socket:[0]", b[0..numberedLink("socket", 0, &b).?]);
    try std.testing.expectEqualStrings("pipe:[1234567890]", b[0..numberedLink("pipe", 1234567890, &b).?]);
    try std.testing.expectEqualStrings("anon_inode:[eventpoll]", b[0..anonLink("anon_inode:[eventpoll]", &b).?]);
    var tiny: [4]u8 = undefined;
    try std.testing.expect(numberedLink("pipe", 7, &tiny) == null);
    try std.testing.expect(anonLink("anon_inode:[eventpoll]", &tiny) == null);
}
