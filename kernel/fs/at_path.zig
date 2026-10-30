//! Turns the (dirfd, name) pair of the *at() syscalls, and a relative name
//! under the working directory, into a path the normal lookup can resolve.
//! Directory descriptors on every filesystem take part: a mounted ext4/NTFS
//! volume, the ext2 root disk, tmpfs and /dev.
//!
//! An ext2 directory fd uses the path it was opened by (renaming the
//! directory afterwards leaves that path stale; Linux follows the inode).
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

/// Absolute path of the directory behind descriptor `fd`, whatever
/// filesystem it is on: a volume directory (rebuilt, see dirFdPath), an ext2
/// directory (the path it was opened by), a tmpfs directory (rebuilt from its
/// parent chain) or /dev. EBADF for a free slot, ENOTDIR for anything that is
/// not a directory.
pub fn dirFdBase(cur: *task_mod.Task, fd: u32, out: *[256]u8) union(enum) { ok: []const u8, err: i64 } {
    if (fd >= vfs.MAX_FDS) return .{ .err = -9 };
    const d = &cur.fd_table.fds[fd];
    switch (d.fd_type) {
        .none => return .{ .err = -9 },
        .rofs_file => return switch (dirFdPath(cur, fd, out)) {
            .ok => |p| .{ .ok = p },
            .err => |e| .{ .err = e },
        },
        .ext2_file => {
            const ext2 = @import("ext2.zig");
            const is_dir = ext2.openFileIsDir(d.ext2_file_idx) orelse return .{ .err = -9 };
            if (!is_dir) return .{ .err = -20 };
            const stored = ext2.getOpenFilePath(d.ext2_file_idx) orelse return .{ .err = -9 };
            var tmp: [257]u8 = undefined;
            var n: usize = 0;
            if (stored.len == 0 or stored[0] != '/') {
                tmp[0] = '/';
                n = 1;
            }
            if (n + stored.len > tmp.len) return .{ .err = -36 };
            @memcpy(tmp[n..][0..stored.len], stored);
            n += stored.len;
            const abs = vfs.normalizeAbs(tmp[0..n], out) orelse return .{ .err = -36 };
            return .{ .ok = abs };
        },
        .tmpfs_file => return switch (@import("tmpfs.zig").tmpfsDirPath(d.tmpfs_idx, out)) {
            .ok => |p| .{ .ok = p },
            .err => |e| .{ .err = e },
        },
        .devfs => {
            if (d.devfs_idx != @import("devfs.zig").DIR_IDX) return .{ .err = -20 };
            @memcpy(out[0..4], "/dev");
            return .{ .ok = out[0..4] };
        },
        else => return .{ .err = -20 }, // ENOTDIR
    }
}

fn fromJoin(j: at_join.CwdJoin) Resolved {
    return switch (j) {
        .keep => .keep,
        .path => |p| .{ .path = p },
        .too_long => .{ .err = -36 }, // ENAMETOOLONG
    };
}

/// Resolve `name` as the *at() calls do. `dirfd` is the raw syscall argument
/// (AT_FDCWD for "the current directory"). Absolute names ignore dirfd; a
/// relative name is joined onto the directory and normalised. AT_FDCWD with
/// the root as cwd keeps plain names as they are (the flat filesystems look
/// them up from the root).
pub fn resolve(cur: *task_mod.Task, dirfd: i64, name: []const u8, buf: *[256]u8) Resolved {
    if (name.len == 0 or name[0] == '/') return .keep;

    if (dirfd != AT_FDCWD) {
        if (dirfd < 0 or dirfd >= vfs.MAX_FDS) return .{ .err = -9 }; // EBADF
        var dirbuf: [256]u8 = undefined;
        return switch (dirFdBase(cur, @intCast(dirfd), &dirbuf)) {
            .ok => |base| fromJoin(at_join.absJoin(base, name, buf)),
            .err => |e| .{ .err = e },
        };
    }
    return fromJoin(at_join.underCwd(cur.cwd[0..cur.cwd_len], name, buf));
}

const at_join = @import("at_join_policy.zig");
