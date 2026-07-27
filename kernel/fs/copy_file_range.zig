/// copy_file_range — efficient kernel-space file copy.
///
/// Extracted from syscall_entry.zig (v18.9).
const copy = @import("../mm/copy_from_user.zig");
const sched_mod = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");

const EBADF: i64 = -9;
const EFAULT: i64 = -14;
const EINVAL: i64 = -22;

fn isRegularFile(fd_type: @import("vfs.zig").FdType) bool {
    return switch (fd_type) {
        .ramdisk_file, .fat32_file, .ext2_file, .tmpfs_file => true,
        else => false,
    };
}

/// copyFileRange(fd_in, off_in_ptr, fd_out, off_out_ptr, len) -> bytes copied or -errno.
pub fn copyFileRange(fd_in: u32, off_in_ptr: u64, fd_out: u32, off_out_ptr: u64, len: u64) i64 {
    if (len == 0 or len > 0x7FFFFFFF) return EINVAL;
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    // Validate untrusted fd numbers before indexing the descriptor array.
    if (fd_in >= cur.fd_table.fds.len or fd_out >= cur.fd_table.fds.len) return EBADF;
    if (cur.fd_table.fds[fd_in].fd_type == .none or cur.fd_table.fds[fd_out].fd_type == .none) return EBADF;
    if (!isRegularFile(cur.fd_table.fds[fd_in].fd_type) or !isRegularFile(cur.fd_table.fds[fd_out].fd_type)) return EINVAL;

    // Read optional offset pointers
    var off_in_val: u64 = 0;
    var off_out_val: u64 = 0;
    var use_off_in = false;
    var use_off_out = false;
    if (off_in_ptr != 0) {
        if (off_in_ptr >= 0x0000_8000_0000_0000 or !copy.validateUserBufferWritable(off_in_ptr, 8)) return EFAULT;
        var buf: [8]u8 = undefined;
        if (copy.copyFromUser(&buf, @ptrFromInt(off_in_ptr), 8) != 8) return EFAULT;
        off_in_val = @as(u64, @bitCast(buf));
        use_off_in = true;
    }
    if (off_out_ptr != 0) {
        if (off_out_ptr >= 0x0000_8000_0000_0000 or !copy.validateUserBufferWritable(off_out_ptr, 8)) return EFAULT;
        var buf: [8]u8 = undefined;
        if (copy.copyFromUser(&buf, @ptrFromInt(off_out_ptr), 8) != 8) return EFAULT;
        off_out_val = @as(u64, @bitCast(buf));
        use_off_out = true;
    }

    // Explicit offsets temporarily replace the descriptor positions. Restore both
    // descriptor offsets from one cleanup path, including all error returns.
    const orig_in = cur.fd_table.fds[fd_in].offset;
    const orig_out = cur.fd_table.fds[fd_out].offset;
    defer {
        if (use_off_in) cur.fd_table.fds[fd_in].offset = orig_in;
        if (use_off_out) cur.fd_table.fds[fd_out].offset = orig_out;
    }
    if (use_off_in) cur.fd_table.fds[fd_in].offset = off_in_val;
    if (use_off_out) cur.fd_table.fds[fd_out].offset = off_out_val;

    // Copy in 8KB chunks
    const n: usize = @intCast(@min(len, 0x7FFFFFFF));
    var total: usize = 0;
    while (total < n) {
        const chunk = @min(n - total, 8192);
        var kbuf: [8192]u8 = undefined;
        const rd = cur.fd_table.read(fd_in, &kbuf, chunk);
        if (rd < 0) return if (total > 0) @intCast(total) else rd;
        if (rd == 0) break;
        const wr = cur.fd_table.write(fd_out, &kbuf, @intCast(rd));
        if (wr < 0) return if (total > 0) @intCast(total) else wr;
        if (wr == 0) break;
        total += @intCast(wr);
        if (wr < rd) break;
    }

    // Write back updated offsets if pointer was provided
    if (use_off_in) {
        const new_off = cur.fd_table.fds[fd_in].offset;
        var buf: [8]u8 = @bitCast(new_off);
        // Data already copied is observable, so preserve its partial-copy result.
        if (copy.copyToUser(@ptrFromInt(off_in_ptr), &buf, 8) != 8) return if (total > 0) @intCast(total) else EFAULT;
    }
    if (use_off_out) {
        const new_off = cur.fd_table.fds[fd_out].offset;
        var buf: [8]u8 = @bitCast(new_off);
        if (copy.copyToUser(@ptrFromInt(off_out_ptr), &buf, 8) != 8) return if (total > 0) @intCast(total) else EFAULT;
    }

    return @intCast(total);
}
