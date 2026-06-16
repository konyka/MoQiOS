/// Shared integer formatting utilities without hardware side effects.
/// Format a u64 as decimal into `buf`. Returns the valid slice.
/// Buffer must be at least 20 bytes for u64 max (20 digits).
pub fn fmtDec(buf: []u8, value: u64) []const u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var i: usize = 0;
    var v = value;
    while (v > 0) : (v /= 10) {
        buf[i] = @intCast(v % 10 + '0');
        i += 1;
    }
    var j: usize = 0;
    while (j < i / 2) : (j += 1) {
        const tmp = buf[j];
        buf[j] = buf[i - 1 - j];
        buf[i - 1 - j] = tmp;
    }
    return buf[0..i];
}

/// Alias for fmtDec (backward compat with formatInt/formatIntBuf callers).
pub const formatInt = fmtDec;
pub const formatIntBuf = fmtDec;

/// Format a u64 as 16-char zero-padded lowercase hex into `buf`.
/// Buffer must be at least 16 bytes.
pub fn fmtHex16(buf: []u8, value: u64) []const u8 {
    const hex = "0123456789abcdef";
    var i: usize = 16;
    var v = value;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@as(usize, @intCast(v & 0xf))];
        v >>= 4;
    }
    return buf[0..16];
}

/// Alias for fmtHex16 (backward compat).
pub const formatHex = fmtHex16;

/// Format a u64 as variable-length lowercase hex into `buf`.
/// Returns only the significant digits (no leading zeros).
pub fn fmtHex(buf: []u8, value: u64) []const u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var i: usize = 0;
    var v = value;
    while (v > 0 and i < buf.len) : (v >>= 4) {
        const nibble: u8 = @intCast(v & 0xF);
        buf[i] = if (nibble < 10) '0' + nibble else 'a' + nibble - 10;
        i += 1;
    }
    var j: usize = 0;
    while (j < i / 2) : (j += 1) {
        const tmp = buf[j];
        buf[j] = buf[i - 1 - j];
        buf[i - 1 - j] = tmp;
    }
    return buf[0..i];
}

/// Format a u32 as 8-char zero-padded lowercase hex.
pub fn fmtHex8(buf: []u8, value: u32) []const u8 {
    const hex = "0123456789abcdef";
    var i: usize = 8;
    var v: u32 = value;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@as(usize, @intCast(v & 0xf))];
        v >>= 4;
    }
    return buf[0..8];
}

/// Format a signed i64 as decimal (with minus sign for negatives).
pub fn fmtSignedDec(buf: []u8, value: i64) []const u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    const negative = value < 0;
    const abs_val: u64 = if (negative)
        @as(u64, @bitCast(~value)) + 1
    else
        @intCast(value);
    var pos: usize = 0;
    if (negative) {
        buf[0] = '-';
        pos = 1;
    }
    const digits = fmtDec(buf[pos..], abs_val);
    return buf[0 .. pos + digits.len];
}
