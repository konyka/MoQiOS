/// copy_file_range — efficient kernel-space file copy.
///
/// Extracted from syscall_entry.zig (v18.9).
const copy = @import("../mm/copy_from_user.zig");
const sched_mod = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");

/// copyFileRange(fd_in, off_in_ptr, fd_out, off_out_ptr, len) -> bytes copied or -errno.
pub fn copyFileRange(fd_in: u32, off_in_ptr: u64, fd_out: u32, off_out_ptr: u64, len: u64) i64 {
    if (len == 0 or len > 0x7FFFFFFF) return -22; // -EINVAL
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    // Read optional offset pointers
    var off_in_val: u64 = 0;
    var off_out_val: u64 = 0;
    var use_off_in = false;
    var use_off_out = false;
    if (off_in_ptr != 0) {
        if (off_in_ptr >= 0x0000_8000_0000_0000 or !copy.validateUserBufferWritable(off_in_ptr, 8)) return -14;
        var buf: [8]u8 = undefined;
        if (copy.copyFromUser(&buf, @ptrFromInt(off_in_ptr), 8) == 8) {
            off_in_val = @as(u64, @bitCast(buf));
            use_off_in = true;
        }
    }
    if (off_out_ptr != 0) {
        if (off_out_ptr >= 0x0000_8000_0000_0000 or !copy.validateUserBufferWritable(off_out_ptr, 8)) return -14;
        var buf: [8]u8 = undefined;
        if (copy.copyFromUser(&buf, @ptrFromInt(off_out_ptr), 8) == 8) {
            off_out_val = @as(u64, @bitCast(buf));
            use_off_out = true;
        }
    }

    // Save offsets
    const orig_in = cur.fd_table.fds[fd_in].offset;
    const orig_out = cur.fd_table.fds[fd_out].offset;
    if (use_off_in) cur.fd_table.fds[fd_in].offset = off_in_val;
    if (use_off_out) cur.fd_table.fds[fd_out].offset = off_out_val;

    // Copy in 8KB chunks
    const n: usize = @intCast(@min(len, 0x7FFFFFFF));
    var total: usize = 0;
    while (total < n) {
        const chunk = @min(n - total, 8192);
        var kbuf: [8192]u8 = undefined;
        const rd = cur.fd_table.read(fd_in, &kbuf, chunk);
        if (rd <= 0) break;
        const wr = cur.fd_table.write(fd_out, &kbuf, @intCast(rd));
        if (wr <= 0) break;
        total += @intCast(wr);
        if (wr < rd) break;
    }

    // Write back updated offsets if pointer was provided
    if (use_off_in) {
        const new_off = cur.fd_table.fds[fd_in].offset;
        var buf: [8]u8 = @bitCast(new_off);
        if (copy.copyToUser(@ptrFromInt(off_in_ptr), &buf, 8) != 8) return -14;
        cur.fd_table.fds[fd_in].offset = orig_in;
    }
    if (use_off_out) {
        const new_off = cur.fd_table.fds[fd_out].offset;
        var buf: [8]u8 = @bitCast(new_off);
        if (copy.copyToUser(@ptrFromInt(off_out_ptr), &buf, 8) != 8) return -14;
        cur.fd_table.fds[fd_out].offset = orig_out;
    }

    return @intCast(total);
}
