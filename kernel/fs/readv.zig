/// readv / writev / preadv / pwritev — vectored I/O operations.
///
/// Extracted from syscall_entry.zig (v18.9).
const copy = @import("../mm/copy_from_user.zig");
const sched_mod = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const bo = @import("../lib/byte_order.zig");

const EFAULT: i64 = 14;

/// readv(fd, iov_ptr, iovcnt) -> bytes read or -errno.
pub fn readv(fd: u32, iov_ptr: u64, iovcnt: u32) i64 {
    if (iov_ptr == 0 or iov_ptr >= 0x0000_8000_0000_0000 or iovcnt == 0 or iovcnt > 1024) return -22;
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    var total: usize = 0;
    for (0..iovcnt) |i| {
        var iov_buf: [16]u8 = undefined;
        const src: [*]const u8 = @ptrFromInt(iov_ptr + @as(u64, @intCast(i)) * 16);
        const copied = copy.copyFromUser(&iov_buf, src, 16);
        if (copied < 16) break;

        const iov_base: u64 = bo.readU64At(&iov_buf, 0);
        const iov_len: u64 = bo.readU64At(&iov_buf, 8);

        if (iov_base == 0 or iov_base >= 0x0000_8000_0000_0000 or iov_len == 0) continue;

        const n: usize = @intCast(@min(iov_len, 0x7FFFFFFF));
        var pos: usize = 0;
        while (pos < n) {
            const chunk = @min(n - pos, 4096);
            var kbuf: [4096]u8 = undefined;
            // Refuse before consuming: whatever comes off a pipe or socket
            // cannot be put back if the destination turns out to be unwritable.
            if (!copy.validateUserBufferWritable(iov_base + pos, chunk)) {
                if (total == 0 and pos == 0) return -EFAULT;
                break;
            }
            const result = cur.fd_table.read(fd, &kbuf, chunk);
            if (result <= 0) {
                if (total == 0 and pos == 0) return @bitCast(result);
                break;
            }
            const got: usize = @intCast(result);
            const written = copy.copyToUser(@ptrFromInt(iov_base + pos), kbuf[0..got], got);
            pos += written;
            if (written < got) break;
            if (got < chunk) break;
        }
        total += pos;
        if (pos < n) break;
    }
    return @intCast(total);
}

/// writev(fd, iov_ptr, iovcnt) -> bytes written or -errno.
pub fn writev(fd: u32, iov_ptr: u64, iovcnt: u32) i64 {
    if (iov_ptr == 0 or iov_ptr >= 0x0000_8000_0000_0000 or iovcnt == 0 or iovcnt > 1024) return -22;
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    var total: usize = 0;
    for (0..iovcnt) |i| {
        var iov_buf: [16]u8 = undefined;
        const src: [*]const u8 = @ptrFromInt(iov_ptr + @as(u64, @intCast(i)) * 16);
        const copied = copy.copyFromUser(&iov_buf, src, 16);
        if (copied < 16) break;

        const iov_base: u64 = bo.readU64At(&iov_buf, 0);
        const iov_len: u64 = bo.readU64At(&iov_buf, 8);

        if (iov_base == 0 or iov_base >= 0x0000_8000_0000_0000 or iov_len == 0) continue;

        const n: usize = @intCast(@min(iov_len, 0x7FFFFFFF));
        var pos: usize = 0;
        while (pos < n) {
            const chunk = @min(n - pos, 4096);
            var kbuf: [4096]u8 = undefined;
            const from_user = copy.copyFromUser(kbuf[0..chunk], @ptrFromInt(iov_base + pos), chunk);
            if (from_user == 0) break;
            const result = cur.fd_table.write(fd, &kbuf, from_user);
            if (result <= 0) {
                if (total == 0 and pos == 0) return @bitCast(result);
                break;
            }
            pos += @intCast(result);
            if (result < @as(i64, @intCast(from_user))) break;
        }
        total += pos;
        if (pos < n) break;
    }
    return @intCast(total);
}

/// preadv(fd, iov_ptr, iovcnt, pos_l) -> bytes read or -errno.
pub fn preadv(fd: u32, iov_ptr: u64, iovcnt: u32, pos_l: u64) i64 {
    if (iov_ptr == 0 or iov_ptr >= 0x0000_8000_0000_0000 or iovcnt == 0 or iovcnt > 1024) return -22;
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    const orig_offset = cur.fd_table.fds[fd].offset;
    cur.fd_table.fds[fd].offset = pos_l;

    var total: usize = 0;
    for (0..iovcnt) |i| {
        var iov_buf: [16]u8 = undefined;
        const src: [*]const u8 = @ptrFromInt(iov_ptr + @as(u64, @intCast(i)) * 16);
        const copied = copy.copyFromUser(&iov_buf, src, 16);
        if (copied < 16) break;

        const iov_base: u64 = bo.readU64At(&iov_buf, 0);
        const iov_len: u64 = bo.readU64At(&iov_buf, 8);

        if (iov_base == 0 or iov_base >= 0x0000_8000_0000_0000 or iov_len == 0) continue;

        const n: usize = @intCast(@min(iov_len, 0x7FFFFFFF));
        var pos: usize = 0;
        while (pos < n) {
            const chunk = @min(n - pos, 4096);
            var kbuf: [4096]u8 = undefined;
            if (!copy.validateUserBufferWritable(iov_base + pos, chunk)) {
                if (total == 0 and pos == 0) {
                    cur.fd_table.fds[fd].offset = orig_offset;
                    return -EFAULT;
                }
                break;
            }
            const result = cur.fd_table.read(fd, &kbuf, chunk);
            if (result <= 0) {
                if (total == 0 and pos == 0) {
                    cur.fd_table.fds[fd].offset = orig_offset;
                    return @bitCast(result);
                }
                break;
            }
            const got: usize = @intCast(result);
            const written = copy.copyToUser(@ptrFromInt(iov_base + pos), kbuf[0..got], got);
            pos += written;
            if (written < got) break;
            if (got < chunk) break;
        }
        total += pos;
        if (pos < n) break;
    }

    cur.fd_table.fds[fd].offset = orig_offset;
    return @intCast(total);
}

/// pwritev(fd, iov_ptr, iovcnt, pos_l) -> bytes written or -errno.
pub fn pwritev(fd: u32, iov_ptr: u64, iovcnt: u32, pos_l: u64) i64 {
    if (iov_ptr == 0 or iov_ptr >= 0x0000_8000_0000_0000 or iovcnt == 0 or iovcnt > 1024) return -22;
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    const orig_offset = cur.fd_table.fds[fd].offset;
    cur.fd_table.fds[fd].offset = pos_l;

    var total: usize = 0;
    for (0..iovcnt) |i| {
        var iov_buf: [16]u8 = undefined;
        const src: [*]const u8 = @ptrFromInt(iov_ptr + @as(u64, @intCast(i)) * 16);
        const copied = copy.copyFromUser(&iov_buf, src, 16);
        if (copied < 16) break;

        const iov_base: u64 = bo.readU64At(&iov_buf, 0);
        const iov_len: u64 = bo.readU64At(&iov_buf, 8);

        if (iov_base == 0 or iov_base >= 0x0000_8000_0000_0000 or iov_len == 0) continue;

        const n: usize = @intCast(@min(iov_len, 0x7FFFFFFF));
        var pos: usize = 0;
        while (pos < n) {
            const chunk = @min(n - pos, 4096);
            var kbuf: [4096]u8 = undefined;
            const ucopy = copy.copyFromUser(kbuf[0..chunk], @ptrFromInt(iov_base + pos), chunk);
            if (ucopy == 0) break;
            const result = cur.fd_table.write(fd, &kbuf, ucopy);
            if (result <= 0) break;
            pos += @intCast(result);
            if (result < @as(i64, @intCast(ucopy))) break;
        }
        total += pos;
        if (pos < n) break;
    }

    cur.fd_table.fds[fd].offset = orig_offset;
    return @intCast(total);
}
