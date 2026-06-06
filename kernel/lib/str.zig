/// Shared string utility functions for the kernel (no std dependency).

/// Compare two byte slices for equality.
pub fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

/// Check if string `s` starts with `prefix`.
pub fn startsWith(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    for (s[0..prefix.len], prefix) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

/// Compute length of a NUL-terminated C string, up to `max` bytes.
pub fn strnlen(s: [*]const u8, max: usize) usize {
    var i: usize = 0;
    while (i < max and s[i] != 0) : (i += 1) {}
    return i;
}
