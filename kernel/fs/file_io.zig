/// kernel/fs/file_io.zig — Core file I/O syscall implementations (read/write/open/close)
///
/// Extracted from syscall_entry.zig (v19.1).
const serial = @import("../arch/arch.zig").serial;
const sched_mod = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const copy = @import("../mm/copy_from_user.zig");

const EFAULT: i64 = 14;

/// write(fd, buf, count) → bytes written or -errno
pub fn write(fd: u64, buf: u64, count: u64) i64 {
    if (buf == 0 or buf >= 0x0000_8000_0000_0000 or count > 0x7FFFFFFF) return -1;
    const n: usize = @intCast(count);
    if (n == 0) return 0;

    // stdout/stderr → serial
    if (fd == 1 or fd == 2) {
        var pos: usize = 0;
        while (pos < n) {
            const chunk = @min(n - pos, 4096);
            var kbuf: [4096]u8 = undefined;
            const copied = copy.copyFromUser(kbuf[0..chunk], @ptrFromInt(buf + pos), chunk);
            if (copied == 0) break;
            for (0..copied) |i| {
                serial.writeByte(kbuf[i]);
            }
            pos += copied;
            if (copied < chunk) break;
        }
        return @intCast(pos);
    }

    // VFS write
    if (sched_mod.currentTaskIndex()) |cur_idx| {
        if (task_mod.getTask(cur_idx)) |cur| {
            var pos: usize = 0;
            while (pos < n) {
                const chunk = @min(n - pos, 4096);
                var kbuf: [4096]u8 = undefined;
                const copied = copy.copyFromUser(kbuf[0..chunk], @ptrFromInt(buf + pos), chunk);
                if (copied == 0) break;
                const result = cur.fd_table.write(@intCast(fd), &kbuf, copied);
                // Propagate a first-chunk error (e.g. -28 ENOSPC from the
                // writeback cache) instead of reporting a 0-byte write that
                // callers would retry forever — mirrors pwrite below.
                if (result < 0) {
                    if (pos == 0) return result;
                    break;
                }
                if (result == 0) break;
                pos += @intCast(result);
                if (result < @as(i64, @intCast(copied))) break;
            }
            return @intCast(pos);
        }
    }
    return -1;
}

/// open(name_ptr, flags) → fd or -1
pub fn open(name_ptr: u64, flags: u32) i64 {
    if (name_ptr >= 0x0000_8000_0000_0000 or name_ptr == 0) return -1;

    var name_buf: [256]u8 = undefined;
    const copied = copy.copyFromUser(name_buf[0..], @ptrFromInt(name_ptr), 255);
    if (copied == 0) return -1;
    name_buf[if (copied < 255) copied else 255] = 0;

    var len: usize = 0;
    while (len < copied and name_buf[len] != 0) : (len += 1) {}
    const name = name_buf[0..len];

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    const result = cur.fd_table.open(name, flags);
    return @bitCast(result);
}

/// read(fd, buf_ptr, count) → bytes read or -errno
pub fn read(fd: u32, buf_ptr: u64, count: u64) i64 {
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000 or count > 0x7FFFFFFF) return -1;
    const n: usize = @intCast(count);
    if (n == 0) return 0;

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    var pos: usize = 0;
    var faulted = false;
    var first_err: i64 = 0;
    while (pos < n) {
        const chunk = @min(n - pos, 4096);
        var kbuf: [4096]u8 = undefined;

        // Refuse before consuming. A pipe or socket hands its data over for
        // good, so discovering at copy time that the destination is read-only
        // means the bytes are simply gone.
        if (!copy.validateUserBufferWritable(buf_ptr + pos, chunk)) {
            faulted = true;
            break;
        }

        const result = cur.fd_table.read(fd, &kbuf, chunk);
        if (result < 0) {
            if (pos == 0) first_err = result;
            break;
        }
        if (result == 0) break;
        const got: usize = @intCast(result);
        // Count what reached the user buffer, not what came off the file:
        // copyToUser refuses an unmapped or read-only destination, and
        // crediting those bytes would report a read that never landed.
        const written = copy.copyToUser(@ptrFromInt(buf_ptr + pos), kbuf[0..got], got);
        pos += written;
        if (written < got) {
            faulted = true;
            break;
        }
        if (got < chunk) break;
    }
    if (faulted and pos == 0) return -EFAULT;
    // A genuine error is returned, never re-issued: re-reading after an error
    // would consume more from a pipe and could turn the error into a bogus
    // 1-byte success. The fallback below is only for the EOF-ish 0 return.
    if (pos == 0 and first_err < 0) return first_err;
    if (pos == 0 and n > 0) {
        // v53.45: Fix 1-byte read not being copied to user space
        var tmp: [1]u8 = undefined;
        const r = cur.fd_table.read(fd, &tmp, 1);
        if (r > 0) {
            if (copy.copyToUser(@ptrFromInt(buf_ptr), &tmp, 1) == 0) return -EFAULT;
        }
        return @bitCast(r);
    }
    return @intCast(pos);
}

/// close(fd) → 0 or -1
pub fn close(fd: u32) i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;
    const result = cur.fd_table.close(fd);
    return @bitCast(result);
}

/// pread64(fd, buf_ptr, count, offset) → bytes read or -errno
/// Reads from a file at a specific offset without changing the fd's current position.
pub fn pread(fd: u32, buf_ptr: u64, count: u64, offset: u64) i64 {
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000 or count > 0x7FFFFFFF) return -1;
    const n: usize = @intCast(count);
    if (n == 0) return 0;

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    var pos: usize = 0;
    var current_offset = offset;
    var faulted = false;
    while (pos < n) {
        const chunk = @min(n - pos, 4096);
        var kbuf: [4096]u8 = undefined;
        if (!copy.validateUserBufferWritable(buf_ptr + pos, chunk)) {
            faulted = true;
            break;
        }
        const result = cur.fd_table.readAtOffset(fd, &kbuf, chunk, current_offset);
        if (result < 0) {
            if (pos == 0) return result;
            break;
        }
        if (result == 0) break;
        const got: usize = @intCast(result);
        const written = copy.copyToUser(@ptrFromInt(buf_ptr + pos), kbuf[0..got], got);
        pos += written;
        current_offset += written;
        if (written < got) {
            faulted = true;
            break;
        }
        if (got < chunk) break;
    }

    if (faulted and pos == 0) return -EFAULT;
    return @intCast(pos);
}

/// pwrite64(fd, buf_ptr, count, offset) → bytes written or -errno
/// Writes to a file at a specific offset without changing the fd's current position.
pub fn pwrite(fd: u32, buf_ptr: u64, count: u64, offset: u64) i64 {
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000 or count > 0x7FFFFFFF) return -1;
    const n: usize = @intCast(count);
    if (n == 0) return 0;

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    var pos: usize = 0;
    var current_offset = offset;
    while (pos < n) {
        const chunk = @min(n - pos, 4096);
        var kbuf: [4096]u8 = undefined;
        const copied = copy.copyFromUser(kbuf[0..chunk], @ptrFromInt(buf_ptr + pos), chunk);
        if (copied == 0) break;
        const result = cur.fd_table.writeAtOffset(fd, &kbuf, copied, current_offset);
        if (result < 0) {
            if (pos == 0) return result;
            break;
        }
        if (result == 0) break;
        pos += @intCast(result);
        current_offset += @intCast(result);
        if (result < @as(i64, @intCast(copied))) break;
    }

    return @intCast(pos);
}
