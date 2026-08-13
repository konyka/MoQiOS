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
    const copied = copy.copyFromUser(name_buf[0..], @ptrFromInt(name_ptr), 255);
    if (copied == 0) return -1;
    name_buf[if (copied < 255) copied else 255] = 0;

    var len: usize = 0;
    while (len < copied and name_buf[len] != 0) : (len += 1) {}
    const name = name_buf[0..len];

    if (name.len >= 4 and name[0] == '/' and name[1] == 't' and name[2] == 'm' and name[3] == 'p') {
        const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
        const cur = task_mod.getTask(cur_idx) orelse return -1;
        const mode = requested_mode orelse @import("../proc/creation_metadata.zig").DEFAULT_DIRECTORY_MODE;
        return @import("tmpfs.zig").tmpfsMkdirAuthorized(name, mode, cur.umask_val, cur.euid, cur.egid, cur.effective_caps);
    }

    const ext2 = @import("ext2.zig");
    if (ext2.isActive()) {
        const result = ext2.createDir(name);
        if (result > 0) {
            ext2.closeFile(@intCast(result));
            return 0;
        }
        if (result == 0) return 0;
    }

    return -1;
}
