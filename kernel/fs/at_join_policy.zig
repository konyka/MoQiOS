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

pub const CwdJoin = union(enum) {
    /// Use the name exactly as given.
    keep,
    /// The name to look up instead (inside the caller's buf).
    path: []const u8,
    /// The joined name does not fit (ENAMETOOLONG).
    too_long,
};

/// A relative name under the working directory `cwd`. From the root a plain
/// name ("hello2") is kept: the flat filesystems look bare names up from the
/// root themselves.
pub fn underCwd(cwd: []const u8, name: []const u8, buf: *[256]u8) CwdJoin {
    if (name.len == 0 or name[0] == '/') return .keep;
    const at_root = cwd.len == 0 or (cwd.len == 1 and cwd[0] == '/');
    if (at_root and isPlain(name) and !namesRootTree(name)) return .keep;
    return absJoin(if (at_root) "/" else cwd, name, buf);
}

/// `base` + "/" + `name`, with "." / ".." / duplicate slashes collapsed. A
/// relative `base` counts from the root (ext2 keeps the name a directory was
/// opened with). A result that is a single component directly under the root
/// is returned without its slash, the form the flat root filesystems (ramdisk,
/// FAT32) store names in; /tmp, /dev and /proc stay absolute.
pub fn absJoin(base: []const u8, name: []const u8, buf: *[256]u8) CwdJoin {
    var tmp: [512]u8 = undefined;
    var n: usize = 0;
    if (base.len == 0 or base[0] != '/') {
        tmp[0] = '/';
        n = 1;
    }
    if (n + base.len + 1 + name.len > tmp.len) return .too_long;
    @memcpy(tmp[n..][0..base.len], base);
    n += base.len;
    tmp[n] = '/';
    n += 1;
    @memcpy(tmp[n..][0..name.len], name);
    n += name.len;
    const abs = mount_path.normalizeAbs(tmp[0..n], buf) orelse return .too_long;
    if (abs.len > 1 and isPlain(abs[1..]) and !namesRootTree(abs[1..])) return .{ .path = abs[1..] };
    return .{ .path = abs };
}

/// One component that is neither "." nor "..".
fn isPlain(name: []const u8) bool {
    for (name) |c| if (c == '/') return false;
    return !eql(name, ".") and !eql(name, "..");
}

/// Trees that are only reachable by an absolute path ("/tmp", "/dev",
/// "/proc"): a relative name from the root that starts with one of them has
/// to be made absolute, or it would be looked up on the root disk.
pub fn namesRootTree(name: []const u8) bool {
    const trees = [_][]const u8{ "tmp", "dev", "proc" };
    for (trees) |t| {
        if (name.len < t.len) continue;
        if (!eql(name[0..t.len], t)) continue;
        if (name.len == t.len or name[t.len] == '/') return true;
    }
    return false;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

const mount_path = @import("mount_path_policy.zig");
