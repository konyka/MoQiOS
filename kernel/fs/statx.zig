/// statx — extended file stat (Linux syscall #332).
///
/// Extracted from syscall_entry.zig (v18.8).
const copy = @import("../mm/copy_from_user.zig");
const sched_mod = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const bo = @import("../lib/byte_order.zig");

/// statx(dirfd, pathname_ptr, flags, mask, statxbuf_ptr) -> 0 or -errno.
pub fn statx(pathname_ptr: u64, statxbuf_ptr: u64) i64 {
    // Validate the full destination before opening a temporary fd; this keeps
    // bad output pointers from causing needless fd-table mutation.
    if (!copy.validateUserBufferWritable(statxbuf_ptr, 144)) return -14; // EFAULT

    // Read pathname
    var name_buf: [256]u8 = undefined;
    if (pathname_ptr == 0 or pathname_ptr >= 0x0000_8000_0000_0000) return -14; // EFAULT
    const copied = copy.copyFromUser(&name_buf, @ptrFromInt(pathname_ptr), 255);
    if (copied == 0) return -14;
    var len: usize = 0;
    while (len < copied and name_buf[len] != 0) : (len += 1) {}
    const name = name_buf[0..len];

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    // Try to open and fstat
    var stat_buf: [144]u8 = undefined;
    @memset(&stat_buf, 0);
    const fd_result = cur.fd_table.openWithCredentials(name, 0, cur.euid, cur.egid, cur.effective_caps); // O_RDONLY
    if (fd_result >= 0) {
        const fd: u32 = @intCast(fd_result);
        const fd_entry = &cur.fd_table.fds[fd];

        // Fill statx fields: stx_mask(4), stx_blksize(4), stx_attributes(8),
        // stx_nlink(4), stx_uid(4), stx_gid(4), stx_mode(2), pad(2),
        // stx_ino(8), stx_size(8), stx_blocks(8), stx_attributes_mask(8)
        var off: usize = 0;
        const stx_mask: u32 = 0x7FF; // STATX_BASIC
        bo.writeU32Le(stat_buf[off..], stx_mask);
        off += 4;
        const blksize: u32 = 4096;
        bo.writeU32Le(stat_buf[off..], blksize);
        off += 4;
        const attrs: u64 = 0;
        bo.writeU64Le(stat_buf[off..], attrs);
        off += 8;
        const nlink: u32 = 1;
        bo.writeU32Le(stat_buf[off..], nlink);
        off += 4;
        var uid: u32 = 0;
        var gid: u32 = 0;
        var mode: u16 = if (fd_entry.fd_type == .tcp_socket) @as(u16, 0o140777) else @as(u16, 0o100644);
        if (fd_entry.fd_type == .tmpfs_file) {
            const tmpfs = @import("tmpfs.zig");
            const metadata = tmpfs.tmpfsGetMetadata(@intCast(fd_entry.tmpfs_idx)) orelse {
                _ = cur.fd_table.close(fd);
                return -2;
            };
            uid = metadata.uid;
            gid = metadata.gid;
            const file_type = if (metadata.is_dir) @as(u16, 0o040000) else @as(u16, 0o100000);
            mode = file_type | @as(u16, @intCast(metadata.mode & 0o777));
        }
        bo.writeU32Le(stat_buf[off..], uid);
        off += 4;
        bo.writeU32Le(stat_buf[off..], gid);
        off += 4;
        bo.writeU16Le(stat_buf[off..], mode);
        off += 2;
        off += 2; // padding
        const ino: u64 = @intCast(fd);
        bo.writeU64Le(stat_buf[off..], ino);
        off += 8;
        const size: u64 = fd_entry.file_size;
        bo.writeU64Le(stat_buf[off..], size);
        off += 8;

        _ = cur.fd_table.close(fd);
    } else {
        return -2; // ENOENT
    }

    // Write statx buffer to user space
    if (copy.copyToUser(@ptrFromInt(statxbuf_ptr), &stat_buf, stat_buf.len) != stat_buf.len) return -14;
    return 0;
}
