//! Turns the (dirfd, name) pair of the *at() syscalls into a path the normal
//! lookup can resolve, for descriptors that refer to a directory on a mounted
//! ext4/NTFS volume. Everything else is left alone: the other filesystems
//! keep their existing handling of dirfd.
//!
//! A volume directory fd carries (mount slot, generation, record number) and
//! no path, so the path is rebuilt: the mount target plus the directory's
//! path inside the volume (found by asking each parent for the child's name)
//! plus the caller's relative name. Routing the result through the usual
//! absolute-path open gives symlink following, ".." leaving the volume and
//! the permission checks for free. One consequence: the directories above the
//! fd's directory are searched again, which Linux does not do (it trusts the
//! fd). On a read-only volume permissions cannot change underneath an open
//! fd, so this only differs for a process that dropped privileges after
//! opening the directory.

const task_mod = @import("../proc/task.zig");
const vfs = @import("vfs.zig");
const rofs = @import("rofs.zig");

pub const AT_FDCWD: i64 = -100;

pub const Resolved = union(enum) {
    /// Not ours: use the name exactly as the caller passed it.
    keep,
    /// An absolute path (inside `buf`) to resolve instead.
    path: []const u8,
    /// Fail the syscall with this negative errno.
    err: i64,
};

/// Absolute path of the volume directory behind descriptor `fd`, or a
/// negative errno. `out` must be 256 bytes.
pub fn dirFdPath(cur: *task_mod.Task, fd: u32, out: *[256]u8) union(enum) { ok: []const u8, err: i64 } {
    if (fd >= vfs.MAX_FDS) return .{ .err = -9 };
    const d = &cur.fd_table.fds[fd];
    if (d.fd_type != .rofs_file) return .{ .err = -9 };
    if (!d.rofs_is_dir) return .{ .err = -20 }; // ENOTDIR

    var inside: [256]u8 = undefined;
    const rel = switch (rofs.pathOf(d.rofs_mount, d.rofs_gen, d.rofs_ref, &inside)) {
        .ok => |p| p,
        .err => |e| return .{ .err = e },
    };
    var tbuf: [256]u8 = undefined;
    const target = vfs.rofsTargetOf(d.rofs_mount, &tbuf) orelse return .{ .err = -19 };
    // The slot may have been unmounted and mounted again between the two
    // lookups above; the path would then describe another volume.
    if (rofs.generationOf(d.rofs_mount) != d.rofs_gen) return .{ .err = -19 };
    if (target.len + rel.len > out.len - 1) return .{ .err = -36 };
    @memcpy(out[0..target.len], target);
    @memcpy(out[target.len..][0..rel.len], rel);
    return .{ .ok = out[0 .. target.len + rel.len] };
}

fn join(base: []const u8, name: []const u8, buf: *[256]u8) Resolved {
    var n = base.len;
    if (n + 1 + name.len > buf.len - 1) return .{ .err = -36 }; // ENAMETOOLONG
    if (base.len > 0 and base[base.len - 1] == '/') {
        @memcpy(buf[0..n], base);
    } else {
        @memcpy(buf[0..n], base);
        buf[n] = '/';
        n += 1;
    }
    @memcpy(buf[n..][0..name.len], name);
    return .{ .path = buf[0 .. n + name.len] };
}

/// Resolve `name` as the *at() calls do. `dirfd` is the raw syscall argument
/// (AT_FDCWD for "the current directory").
pub fn resolve(cur: *task_mod.Task, dirfd: i64, name: []const u8, buf: *[256]u8) Resolved {
    if (name.len == 0 or name[0] == '/') return .keep;

    // A descriptor naming a directory on a volume.
    if (dirfd != AT_FDCWD and dirfd >= 0 and dirfd < vfs.MAX_FDS) {
        const fd: u32 = @intCast(dirfd);
        if (cur.fd_table.fds[fd].fd_type == .rofs_file) {
            var dirbuf: [256]u8 = undefined;
            switch (dirFdPath(cur, fd, &dirbuf)) {
                .ok => |dp| return join(dp, name, buf),
                .err => |e| return .{ .err = e },
            }
        }
    }

    // Relative to the working directory: it only needs help when that is
    // inside a volume (the flat filesystems resolve relative names themselves).
    if (cur.cwd_len > 1 and vfs.rofsRoute(cur.cwd[0..cur.cwd_len]) != null) {
        return join(cur.cwd[0..cur.cwd_len], name, buf);
    }
    return .keep;
}
