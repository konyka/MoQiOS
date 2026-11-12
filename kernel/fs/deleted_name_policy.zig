//! The label /proc/self/fd/N reports for an entry that no longer has that name: Linux appends " (deleted)" to the path it had when
//! the entry was unlinked, and the descriptor keeps working (measured: readlink gives "/tmp/x (deleted)", open through the link
//! still reads the file). The kernel builds the base path the same way it does for a live entry; only the suffix and the fact that
//! a deleted entry is not an error differ.

pub const SUFFIX = " (deleted)";

/// Append the suffix to the path already in `out[0..len]` (in place; the caller reports ENAMETOOLONG when it does not fit).
pub fn appendInPlace(out: []u8, len: usize) ?usize {
    if (len + SUFFIX.len > out.len) return null;
    @memcpy(out[len..][0..SUFFIX.len], SUFFIX);
    return len + SUFFIX.len;
}

/// Base path plus the suffix, or null if it does not fit (the caller reports ENAMETOOLONG).
pub fn withSuffix(base: []const u8, out: []u8) ?usize {
    if (base.len + SUFFIX.len > out.len) return null;
    @memcpy(out[0..base.len], base);
    return appendInPlace(out, base.len);
}

const testing = @import("std").testing;

test "the deleted suffix is appended verbatim" {
    var out: [256]u8 = undefined;
    const n = withSuffix("/tmp/a", &out).?;
    try testing.expectEqualStrings("/tmp/a (deleted)", out[0..n]);
    // exactly fitting is fine, one byte less is not
    var tight: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 16), withSuffix("/tmp/a", &tight).?); // "/tmp/a" (6) + " (deleted)" (10)
    try testing.expect(withSuffix("/tmp/ab", &tight) == null);
    // in place: the path already sits in the buffer (the caller's case)
    var same: [256]u8 = undefined;
    @memcpy(same[0..6], "/tmp/a");
    try testing.expectEqual(@as(usize, 16), appendInPlace(&same, 6).?);
    try testing.expectEqualStrings("/tmp/a (deleted)", same[0..16]);
    try testing.expect(appendInPlace(&same, 250) == null);
}
