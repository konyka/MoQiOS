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
