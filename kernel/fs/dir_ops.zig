/// kernel/fs/dir_ops.zig — Directory operation syscall implementations
///
/// Extracted from syscall_entry.zig (v19.1): getcwd, fstat, listdir, mkdir.
const sched_mod = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const copy = @import("../mm/copy_from_user.zig");
const vfs_mod = @import("vfs.zig");
const bo = @import("../lib/byte_order.zig");

/// getcwd(buf_ptr, buf_size) → bytes written (including null) or -errno
pub fn getcwd(buf_ptr: u64, buf_size: u64) i64 {
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000 or buf_size == 0) return -1;

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    const cwd_len: usize = cur.cwd_len;
    const total = cwd_len + 1;
    if (total > buf_size) return -34; // -ERANGE

    var tmp: [257]u8 = undefined;
    @memcpy(tmp[0..cwd_len], cur.cwd[0..cwd_len]);
    tmp[cwd_len] = 0;

    if (copy.copyToUser(@ptrFromInt(buf_ptr), tmp[0..total], total) != total) return -14;
    return @intCast(total);
}

/// fstat(fd, stat_ptr) → 0 or -errno
pub fn fstat(fd: u64, stat_ptr: u64) i64 {
    if (stat_ptr == 0 or stat_ptr >= 0x0000_8000_0000_0000) return -1;

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS) return -9; // -EBADF

    const fdesc = cur.fd_table.fds[fd];
    if (fdesc.fd_type == .none) return -9;

    var stat_buf: [144]u8 = undefined;
    @memset(&stat_buf, 0);

    const ino: u64 = fd;
    bo.writeU64Le(stat_buf[8..16], ino);

    var mode: u32 = 0o100000; // S_IFREG
    if (fdesc.fd_type == .special) {
        mode = 0o020000; // S_IFCHR
    } else if (fdesc.fd_type == .pipe_read or fdesc.fd_type == .pipe_write) {
        mode = 0o010000; // S_IFIFO
    }
    mode |= 0o444;
    if (fdesc.writable) mode |= 0o222;
    bo.writeU32Le(stat_buf[24..28], mode);

    const size: i64 = @intCast(fdesc.file_size);
    bo.writeI64Le(stat_buf[48..56], size);

    if (fdesc.fd_type == .rofs_file) {
        const rofs = @import("rofs.zig");
        switch (rofs.statRef(fdesc.rofs_mount, fdesc.rofs_gen, fdesc.rofs_ref)) {
            .err => |e| return e,
            .ok => |o| {
                bo.writeU64Le(stat_buf[8..16], o.stat.ino);
                bo.writeU64Le(stat_buf[16..24], o.stat.nlink);
                bo.writeU32Le(stat_buf[24..28], o.stat.mode);
                bo.writeU32Le(stat_buf[28..32], o.stat.uid);
                bo.writeU32Le(stat_buf[32..36], o.stat.gid);
                bo.writeU64Le(stat_buf[48..56], o.stat.size);
                bo.writeU64Le(stat_buf[56..64], 4096);
                bo.writeU64Le(stat_buf[64..72], o.stat.blocks);
                bo.writeU64Le(stat_buf[72..80], o.stat.atime);
                bo.writeU64Le(stat_buf[88..96], o.stat.mtime);
                bo.writeU64Le(stat_buf[104..112], o.stat.ctime);
            },
        }
    }
    if (fdesc.fd_type == .tmpfs_file) {
        const tmpfs = @import("tmpfs.zig");
        if (tmpfs.tmpfsGetMetadata(@intCast(fdesc.tmpfs_idx))) |m| {
            const kind: u32 = if (m.is_dir) 0o040000 else 0o100000;
            bo.writeU64Le(stat_buf[16..24], 1);
            bo.writeU32Le(stat_buf[24..28], kind | (m.mode & 0o7777));
            bo.writeU32Le(stat_buf[28..32], m.uid);
            bo.writeU32Le(stat_buf[32..36], m.gid);
            bo.writeI64Le(stat_buf[48..56], @intCast(tmpfs.tmpfsGetSize(@intCast(fdesc.tmpfs_idx))));
            bo.writeU64Le(stat_buf[56..64], 4096);
        }
    }
    if (fdesc.fd_type == .fat32_file) {
        const fat32 = @import("fat32.zig");
        const mtime = fat32.getMtime(fdesc.fat32_file_idx);
        bo.writeU64Le(stat_buf[56..64], 4096); // st_blksize
        bo.writeU64Le(stat_buf[64..72], (fdesc.file_size + 511) / 512); // st_blocks
        // FAT keeps one write time; report it for all three (atime is a date only).
        bo.writeU64Le(stat_buf[72..80], mtime);
        bo.writeU64Le(stat_buf[88..96], mtime);
        bo.writeU64Le(stat_buf[104..112], mtime);
    }
    if (fdesc.fd_type == .ext2_file) {
        var info: @import("stat_info.zig").StatInfo = .{};
        if (@import("ext2.zig").statInode(fdesc.ext2_file_idx, &info)) {
            bo.writeU64Le(stat_buf[8..16], info.ino);
            bo.writeU64Le(stat_buf[16..24], info.nlink);
            bo.writeU32Le(stat_buf[24..28], info.mode);
            bo.writeU32Le(stat_buf[28..32], info.uid);
            bo.writeU32Le(stat_buf[32..36], info.gid);
            bo.writeU64Le(stat_buf[48..56], @max(info.size, fdesc.file_size));
            bo.writeU64Le(stat_buf[56..64], 4096); // st_blksize
            bo.writeU64Le(stat_buf[64..72], info.blocks);
            bo.writeU64Le(stat_buf[72..80], info.atime);
            bo.writeU64Le(stat_buf[88..96], info.mtime);
            bo.writeU64Le(stat_buf[104..112], info.ctime);
        }
    }

    if (copy.copyToUser(@ptrFromInt(stat_ptr), &stat_buf, stat_buf.len) != stat_buf.len) return -14;
    return 0;
}

/// listdir(buf_ptr, buf_size) → bytes written or -errno
pub fn listdir(buf_ptr: u64, buf_size: u64) i64 {
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000 or buf_size == 0) return -22;

    const ramdisk = @import("ramdisk.zig");
    const fat32 = @import("fat32.zig");

    var kbuf: [4096]u8 = undefined;
    var pos: usize = 0;
    const max = @min(buf_size, 4096);

    const rd_count = ramdisk.getFileCount();
    for (0..rd_count) |i| {
        const fname = ramdisk.getFileName(@intCast(i)) orelse continue;
        const needed = fname.len + 1;
        if (pos + needed > max) break;
        @memcpy(kbuf[pos .. pos + fname.len], fname);
        pos += fname.len;
        kbuf[pos] = '\n';
        pos += 1;
    }

    if (fat32.isActive()) {
        const f32_count = fat32.getFileCount();
        for (0..f32_count) |i| {
            const fname = fat32.getFileName(@intCast(i)) orelse continue;
            const needed = fname.len + 1;
            if (pos + needed > max) break;
            @memcpy(kbuf[pos .. pos + fname.len], fname);
            pos += fname.len;
            kbuf[pos] = '\n';
            pos += 1;
        }
    }

    const ext2 = @import("ext2.zig");
    if (ext2.isActive()) {
        const ext2_bytes = ext2.listDirRoot(kbuf[pos..max]);
        pos += ext2_bytes;
    }

    if (pos > 0) {
        if (copy.copyToUser(@ptrFromInt(buf_ptr), kbuf[0..pos], pos) != pos) return -14;
    }
    return @intCast(pos);
}

/// mkdir(name_ptr) → 0 or -1
pub fn mkdir(name_ptr: u64) i64 {
    return mkdirWithMode(name_ptr, null);
}

/// mkdir with an optional mode; null preserves the legacy 0777 default.
pub fn mkdirWithMode(name_ptr: u64, requested_mode: ?u32) i64 {
    if (name_ptr >= 0x0000_8000_0000_0000 or name_ptr == 0) return -1;

    var name_buf: [256]u8 = undefined;
    const copied = copy.copyPathFromUser(name_buf[0..], name_ptr, 255);
    const path_rc = @import("namespace_policy.zig").pathCopyErrno(name_buf[0..], copied, 255);
    if (path_rc != 0) return path_rc; // EFAULT or ENAMETOOLONG
    name_buf[if (copied < 255) copied else 255] = 0;

    var len: usize = 0;
    while (len < copied and name_buf[len] != 0) : (len += 1) {}
    var join_buf: [256]u8 = undefined;
    const name = switch (@import("dirfd_name.zig").resolve(-100, name_buf[0..len], &join_buf)) {
        .ok => |n| n,
        .err => |e| return e,
    };
    return mkdirName(name, requested_mode);
}

/// mkdirat: resolve `name_ptr` under `dirfd` first.
pub fn mkdirAt(dirfd: i64, name_ptr: u64, requested_mode: ?u32) i64 {
    if (name_ptr >= 0x0000_8000_0000_0000 or name_ptr == 0) return -1;
    var name_buf: [256]u8 = undefined;
    const copied = copy.copyPathFromUser(name_buf[0..], name_ptr, 255);
    const path_rc = @import("namespace_policy.zig").pathCopyErrno(name_buf[0..], copied, 255);
    if (path_rc != 0) return path_rc; // EFAULT or ENAMETOOLONG
    var len: usize = 0;
    while (len < copied and len < 255 and name_buf[len] != 0) : (len += 1) {}
    var join_buf: [256]u8 = undefined;
    const name = switch (@import("dirfd_name.zig").resolve(dirfd, name_buf[0..len], &join_buf)) {
        .ok => |n| n,
        .err => |e| return e,
    };
    return mkdirName(name, requested_mode);
}

fn mkdirName(name: []const u8, requested_mode: ?u32) i64 {
    if (name.len >= 4 and name[0] == '/' and name[1] == 't' and name[2] == 'm' and name[3] == 'p' and (name.len == 4 or name[4] == '/')) {
        const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
        const cur = task_mod.getTask(cur_idx) orelse return -1;
        const mode = requested_mode orelse @import("../proc/creation_metadata.zig").DEFAULT_DIRECTORY_MODE;
        return @import("tmpfs.zig").tmpfsMkdirAuthorized(name, mode, cur.umask_val, cur.euid, cur.egid, cur.effective_caps);
    }

    const ext2 = @import("ext2.zig");
    if (ext2.isActive()) {
        const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
        const cur = task_mod.getTask(cur_idx) orelse return -1;
        const cm = @import("../proc/creation_metadata.zig").decide(null, .directory, requested_mode, cur.umask_val, cur.euid, cur.egid).metadata;
        const result = ext2.createDir(name, .{ .uid = cm.uid, .gid = cm.gid, .perm = @truncate(cm.mode) }, .{ .euid = cur.euid, .egid = cur.egid, .cap_dac_override = cur.effective_caps.cap_dac_override, .groups = cur.groups[0..cur.ngroups] });
        if (result > 0) {
            ext2.closeFile(@intCast(result));
            return 0;
        }
        return result; // 0, or the errno ext2 reported (EEXIST, ENOENT, ENOTDIR, EACCES, ...)
    }

    return -38; // ENOSYS: no filesystem mounted to create it on
}
