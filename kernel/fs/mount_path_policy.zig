//! Pure path rules for mounted read-only volumes: normalisation, mount-target
//! admission and longest-prefix routing. No kernel state, so it is host-tested.

const std = @import("std");

pub const MAX_PATH: usize = 255;

/// Collapse "." / ".." / duplicate slashes of an absolute path into `out`.
/// Returns null for relative paths or when the result does not fit.
pub fn normalizeAbs(path: []const u8, out: *[256]u8) ?[]const u8 {
    if (path.len == 0 or path[0] != '/' or path.len > MAX_PATH) return null;
    var w: usize = 0;
    var i: usize = 0;
    while (i < path.len) {
        while (i < path.len and path[i] == '/') i += 1;
        if (i >= path.len) break;
        const start = i;
        while (i < path.len and path[i] != '/') i += 1;
        const comp = path[start..i];
        if (comp.len == 1 and comp[0] == '.') continue;
        if (comp.len == 2 and comp[0] == '.' and comp[1] == '.') {
            while (w > 0 and out[w - 1] != '/') w -= 1;
            if (w > 0) w -= 1;
            continue;
        }
        if (w + 1 + comp.len > MAX_PATH) return null;
        out[w] = '/';
        @memcpy(out[w + 1 ..][0..comp.len], comp);
        w += 1 + comp.len;
    }
    if (w == 0) {
        out[0] = '/';
        w = 1;
    }
    return out[0..w];
}

/// Trees that already have a filesystem of their own. Mounting a volume at or
/// above one of them (or on "/") would shadow it.
const RESERVED = [_][]const u8{ "/dev", "/proc", "/tmp", "/sys" };

pub const TargetError = enum { ok, not_absolute, is_root, reserved, too_long };

/// Is `target` (already normalised) an acceptable mount point?
pub fn checkTarget(target: []const u8) TargetError {
    if (target.len == 0 or target[0] != '/') return .not_absolute;
    if (target.len > MAX_PATH) return .too_long;
    if (target.len == 1) return .is_root;
    for (RESERVED) |r| {
        if (std.mem.eql(u8, target, r)) return .reserved;
        if (target.len > r.len and std.mem.eql(u8, target[0..r.len], r) and target[r.len] == '/') return .reserved;
    }
    return .ok;
}

/// True if `path` equals `prefix` or lies below it, on a component boundary.
pub fn under(path: []const u8, prefix: []const u8) bool {
    if (path.len < prefix.len or !std.mem.eql(u8, path[0..prefix.len], prefix)) return false;
    if (path.len == prefix.len) return true;
    if (prefix.len == 1) return true; // "/"
    return path[prefix.len] == '/';
}

/// Remainder of `path` below mount `target`, without a leading slash.
pub fn rest(path: []const u8, target: []const u8) []const u8 {
    var r = path[target.len..];
    while (r.len > 0 and r[0] == '/') r = r[1..];
    return r;
}

/// Two mount targets conflict if one is the same as, or nested inside, the other.
pub fn overlaps(a: []const u8, b: []const u8) bool {
    return under(a, b) or under(b, a);
}

/// The first path component of `target` below the directory `dir`, when `dir` is a proper ancestor of `target` ("/" and "/mnt/e/x" give
/// "mnt"; "/mnt" and "/mnt/e" give "e"; "/mnt" and "/mnt" or "/other" give null). This is the one name a mount point adds to the listing of
/// an ancestor directory.
pub fn nextChild(dir: []const u8, target: []const u8) ?[]const u8 {
    if (target.len <= dir.len or !under(target, dir)) return null;
    const below = rest(target, dir);
    if (below.len == 0) return null;
    const end = std.mem.indexOfScalar(u8, below, '/') orelse below.len;
    return below[0..end];
}
