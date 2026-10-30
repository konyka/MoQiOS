//! *at() names under a directory descriptor or the working directory, for
//! the handlers that only have the raw dirfd (see at_path.zig).

/// The name to look up for (dirfd, name): unchanged, or joined onto the
/// directory. EBADF / ENOTDIR / ENAMETOOLONG as at_path.resolve decides.
pub fn resolve(dirfd: i64, name: []const u8, buf: *[256]u8) union(enum) { ok: []const u8, err: i64 } {
    const cur = @import("../proc/sched.zig").currentTask() orelse return .{ .ok = name };
    return switch (@import("at_path.zig").resolve(cur, dirfd, name, buf)) {
        .keep => .{ .ok = name },
        .path => |p| .{ .ok = p },
        .err => |e| .{ .err = e },
    };
}
