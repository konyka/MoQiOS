//! How the path an ext2 slot was opened by follows the namespace (Linux, measured on the host): /proc/self/fd/N of a file names it
//! where it is now. rename of the file itself, or of a directory above it, moves the path; unlinking the name it was reached by marks
//! it " (deleted)" (even while another hard link remains). Paths are compared without their leading '/', since ext2 stores both
//! "testdir/x" and "/testdir/x". Kept free of kernel state for the host tests.

fn trim(p: []const u8) []const u8 {
    var i: usize = 0;
    while (i < p.len and p[i] == '/') i += 1;
    var e = p.len;
    while (e > i and p[e - 1] == '/') e -= 1;
    return p[i..e];
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// The path of a slot opened by `stored` after `old` was renamed to `new`, written into `out` (absolute), or null when the rename
/// does not touch it (or the result does not fit).
pub fn afterRename(stored: []const u8, old: []const u8, new: []const u8, out: []u8) ?usize {
    const s = trim(stored);
    const o = trim(old);
    const n = trim(new);
    if (o.len == 0) return null;
    const rest: []const u8 = if (eql(s, o))
        ""
    else if (s.len > o.len and s[o.len] == '/' and eql(s[0..o.len], o))
        s[o.len..]
    else
        return null;
    const total = 1 + n.len + rest.len;
    if (total > out.len) return null;
    out[0] = '/';
    @memcpy(out[1..][0..n.len], n);
    @memcpy(out[1 + n.len ..][0..rest.len], rest);
    return total;
}

/// True when unlinking `path` removes the name the slot opened by `stored` is known by.
pub fn unlinkHits(stored: []const u8, path: []const u8) bool {
    return trim(stored).len > 0 and eql(trim(stored), trim(path));
}

const std = @import("std");

test "renaming the file itself moves the path" {
    var out: [64]u8 = undefined;
    const n = afterRename("testdir/a", "/testdir/a", "/testdir/b", &out).?;
    try std.testing.expectEqualStrings("/testdir/b", out[0..n]);
}

test "renaming a directory above the file moves the path below it" {
    var out: [64]u8 = undefined;
    const n = afterRename("/d/sub/f", "/d/sub", "/d/sub2", &out).?;
    try std.testing.expectEqualStrings("/d/sub2/f", out[0..n]);
}

test "a name that only shares a prefix is not touched" {
    var out: [64]u8 = undefined;
    try std.testing.expect(afterRename("/d/subx/f", "/d/sub", "/d/sub2", &out) == null);
    try std.testing.expect(afterRename("/d/other", "/d/sub", "/d/sub2", &out) == null);
}

test "a result that does not fit is null" {
    var out: [4]u8 = undefined;
    try std.testing.expect(afterRename("/a", "/a", "/abcdef", &out) == null);
}

test "unlink hits only the exact name, with or without a leading slash" {
    try std.testing.expect(unlinkHits("testdir/a", "/testdir/a"));
    try std.testing.expect(!unlinkHits("testdir/a", "/testdir/ab"));
    try std.testing.expect(!unlinkHits("", "/"));
}
