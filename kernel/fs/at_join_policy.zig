//! Pure join of an *at() relative name onto the path stored with an open
//! directory descriptor. Absolute names ignore the directory.

/// Null when the result would not fit in `buf` (ENAMETOOLONG).
pub fn joinStored(dir: []const u8, name: []const u8, buf: *[256]u8) ?[]const u8 {
    if (name.len > 0 and name[0] == '/') {
        if (name.len > buf.len) return null;
        @memcpy(buf[0..name.len], name);
        return buf[0..name.len];
    }
    const need_slash = dir.len > 0 and dir[dir.len - 1] != '/';
    const total = dir.len + @intFromBool(need_slash) + name.len;
    if (total > buf.len) return null;
    @memcpy(buf[0..dir.len], dir);
    var n = dir.len;
    if (need_slash) {
        buf[n] = '/';
        n += 1;
    }
    @memcpy(buf[n..][0..name.len], name);
    return buf[0..total];
}
