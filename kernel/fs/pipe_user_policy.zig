//! Per-user pipe page accounting (Linux fs/pipe.c: user_struct.pipe_bufs, /proc/sys/fs/pipe-user-pages-soft and -hard). Every
//! pipe charges its pages to the real uid that created it; past the soft limit an unprivileged user's new pipe gets 2 pages and
//! may not grow, past the hard limit it gets none (ENFILE from pipe()). 0 means no limit.
const std = @import("std");

/// PIPE_MIN_DEF_BUFFERS: the pages a new pipe gets once its user is past the soft limit.
pub const MIN_DEF_PAGES: u64 = 2;
/// PIPE_DEF_BUFFERS * INR_OPEN_CUR.
pub const DEFAULT_SOFT: u64 = 16 * 1024;

var soft: u64 = DEFAULT_SOFT;
var hard: u64 = 0;

pub fn softLimit() u64 {
    return @atomicLoad(u64, &soft, .acquire);
}

pub fn hardLimit() u64 {
    return @atomicLoad(u64, &hard, .acquire);
}

pub fn setSoftLimit(v: u64) void {
    @atomicStore(u64, &soft, v, .release);
}

pub fn setHardLimit(v: u64) void {
    @atomicStore(u64, &hard, v, .release);
}

fn tooManySoft(user_pages: u64) bool {
    const s = softLimit();
    return s != 0 and user_pages > s;
}

fn tooManyHard(user_pages: u64) bool {
    const h = hardLimit();
    return h != 0 and user_pages > h;
}

/// alloc_pipe_info: the pages a new pipe of `pages` gets when its user already has `user_pages`, or null when the hard limit
/// refuses it. `unprivileged`: neither CAP_SYS_RESOURCE nor CAP_SYS_ADMIN (pipe_is_unprivileged_user).
pub fn newPipePages(pages: u64, user_pages: u64, unprivileged: bool) ?u64 {
    var got = pages;
    if (tooManySoft(user_pages + got) and unprivileged) got = MIN_DEF_PAGES;
    if (tooManyHard(user_pages + got) and unprivileged) return null;
    return got;
}

/// pipe_set_size: growing a pipe from `old_pages` to `new_pages` while its user holds `user_pages` (this pipe included) is EPERM for
/// an unprivileged caller when the new total is past either limit; shrinking is always allowed.
pub fn growRefused(old_pages: u64, new_pages: u64, user_pages: u64, unprivileged: bool) bool {
    if (new_pages <= old_pages or !unprivileged) return false;
    const total = user_pages - old_pages + new_pages;
    return tooManyHard(total) or tooManySoft(total);
}

/// A write of an unsigned long sysctl (proc_doulongvec_minmax without bounds): leading blanks, a base-0 number, then a blank or the
/// end. A negative number, bad text, an overflow or no number at all is EINVAL. Returns the bytes taken and the value.
pub const UlongWrite = struct { ret: i64, value: ?u64 = null };

pub fn parseUlong(text: []const u8) UlongWrite {
    if (text.len == 0) return .{ .ret = 0 };
    var i: usize = 0;
    while (i < text.len and isBlank(text[i])) i += 1;
    if (i >= text.len or text[i] == '-') return .{ .ret = -22 };
    var base: u64 = 10;
    if (i + 1 < text.len and text[i] == '0' and (text[i + 1] == 'x' or text[i + 1] == 'X')) {
        base = 16;
        i += 2;
    } else if (i + 1 < text.len and text[i] == '0' and std.ascii.isDigit(text[i + 1])) {
        base = 8;
        i += 1;
    }
    const start = i;
    var v: u64 = 0;
    while (i < text.len) : (i += 1) {
        const d: u64 = switch (text[i]) {
            '0'...'9' => text[i] - '0',
            'a'...'f' => text[i] - 'a' + 10,
            'A'...'F' => text[i] - 'A' + 10,
            else => break,
        };
        if (d >= base) break;
        const m = @mulWithOverflow(v, base);
        if (m[1] != 0) return .{ .ret = -22 };
        const a = @addWithOverflow(m[0], d);
        if (a[1] != 0) return .{ .ret = -22 };
        v = a[0];
    }
    if (i == start and base != 8) return .{ .ret = -22 };
    if (i < text.len and !isBlank(text[i])) return .{ .ret = -22 };
    while (i < text.len and isBlank(text[i])) i += 1;
    return .{ .ret = @intCast(i), .value = v };
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

test "past the soft limit an unprivileged user's new pipe gets two pages, past the hard limit none" {
    defer setSoftLimit(DEFAULT_SOFT);
    defer setHardLimit(0);
    try std.testing.expectEqual(@as(?u64, 16), newPipePages(16, 100, true));
    setSoftLimit(20);
    try std.testing.expectEqual(@as(?u64, 2), newPipePages(16, 10, true));
    try std.testing.expectEqual(@as(?u64, 16), newPipePages(16, 4, true));
    try std.testing.expectEqual(@as(?u64, 16), newPipePages(16, 10, false));
    setHardLimit(11);
    try std.testing.expectEqual(@as(?u64, null), newPipePages(16, 10, true));
    try std.testing.expectEqual(@as(?u64, 2), newPipePages(16, 9, true));
    try std.testing.expectEqual(@as(?u64, 16), newPipePages(16, 10, false));
}

test "growing a pipe past either limit is refused for the unprivileged; shrinking never is" {
    defer setSoftLimit(DEFAULT_SOFT);
    defer setHardLimit(0);
    setSoftLimit(32);
    try std.testing.expect(growRefused(16, 32, 20, true));
    try std.testing.expect(!growRefused(16, 32, 16, true));
    try std.testing.expect(!growRefused(16, 32, 20, false));
    try std.testing.expect(!growRefused(16, 1, 100, true));
    setSoftLimit(0);
    setHardLimit(40);
    try std.testing.expect(growRefused(16, 64, 16, true));
    try std.testing.expect(!growRefused(16, 32, 16, true));
}

test "ulong sysctl writes: base 0, blanks around, negatives, junk and overflow are EINVAL" {
    try std.testing.expectEqual(@as(?u64, 5), parseUlong("5\n").value);
    try std.testing.expectEqual(@as(i64, 2), parseUlong("5\n").ret);
    try std.testing.expectEqual(@as(?u64, 0), parseUlong(" 0").value);
    try std.testing.expectEqual(@as(?u64, 16), parseUlong("0x10").value);
    try std.testing.expectEqual(@as(?u64, 8), parseUlong("010").value);
    try std.testing.expectEqual(@as(i64, -22), parseUlong("-1").ret);
    try std.testing.expectEqual(@as(i64, -22), parseUlong("abc").ret);
    try std.testing.expectEqual(@as(i64, -22), parseUlong("12x").ret);
    try std.testing.expectEqual(@as(i64, -22), parseUlong("+5").ret);
    try std.testing.expectEqual(@as(i64, -22), parseUlong("18446744073709551616").ret);
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), parseUlong("18446744073709551615").value);
}
