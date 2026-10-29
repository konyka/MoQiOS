//! *at() names under a directory descriptor (see at_join_policy.zig).

/// A relative *at() name under an ext2 directory descriptor becomes the
/// directory's stored path joined with the name. AT_FDCWD, absolute names
/// and volume (rofs) descriptors keep the name: rofsGuard already answered
/// a volume dirfd. Other descriptors: EBADF / ENOTDIR.
pub fn resolve(dirfd: i64, name: []const u8, buf: *[256]u8) union(enum) { ok: []const u8, err: i64 } {
    if (dirfd == -100 or name.len == 0 or name[0] == '/') return .{ .ok = name };
    if (dirfd < 0) return .{ .err = -9 };
    const vfs_m = @import("vfs.zig");
    const cur = @import("../proc/sched.zig").currentTask() orelse return .{ .err = -9 };
    if (dirfd >= vfs_m.MAX_FDS) return .{ .err = -9 };
    const d = &cur.fd_table.fds[@intCast(dirfd)];
    switch (d.fd_type) {
        .rofs_file => return .{ .ok = name },
        .ext2_file => {
            const dir = @import("ext2.zig").getOpenFilePath(d.ext2_file_idx) orelse return .{ .err = -9 };
            const joined = @import("at_join_policy.zig").joinStored(dir, name, buf) orelse return .{ .err = -36 };
            return .{ .ok = joined };
        },
        .none => return .{ .err = -9 },
        else => return .{ .err = -20 }, // ENOTDIR
    }
}

