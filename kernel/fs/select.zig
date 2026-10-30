/// select — I/O multiplexing via fd_set bitmaps.
///
/// Readiness comes from poll.descEvents (the epoll per-descriptor function),
/// waits park the task in short sleep slices, and the timeout / EBADF /
/// EINVAL rules live in poll_policy.zig.
const copy = @import("../mm/copy_from_user.zig");
const sched_mod = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const vfs_mod = @import("../fs/vfs.zig");
const bo = @import("../lib/byte_order.zig");
const poll_mod = @import("poll.zig");
const pp = @import("poll_policy.zig");

const SET_BYTES: usize = 16;

/// select(nfds, readfds_ptr, writefds_ptr, exceptfds_ptr, timeout_ptr) -> ready count or -errno.
pub fn select(nfds_raw: u64, readfds_ptr: u64, writefds_ptr: u64, exceptfds_ptr: u64, timeout_ptr: u64) i64 {
    if (nfds_raw > 0x7FFF_FFFF) return -22; // negative nfds
    // Linux clamps nfds to the descriptor table size.
    const nfds: usize = @intCast(@min(nfds_raw, vfs_mod.MAX_FDS));
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (readfds_ptr != 0 and !copy.validateUserBufferWritable(readfds_ptr, SET_BYTES)) return -14;
    if (writefds_ptr != 0 and !copy.validateUserBufferWritable(writefds_ptr, SET_BYTES)) return -14;
    if (exceptfds_ptr != 0 and !copy.validateUserBufferWritable(exceptfds_ptr, SET_BYTES)) return -14;
    if (timeout_ptr != 0 and !copy.validateUserBuffer(timeout_ptr, 16)) return -14;

    var wait: pp.Wait = .forever;
    if (timeout_ptr != 0) {
        var tv: [16]u8 = undefined;
        if (copy.copyFromUser(&tv, @ptrFromInt(timeout_ptr), 16) != 16) return -14;
        const sec: i64 = @bitCast(bo.readU64Le(tv[0..8]));
        const usec: i64 = @bitCast(bo.readU64Le(tv[8..16]));
        wait = pp.selectTimeout(sec, usec) orelse return -22;
    }

    var read_fds: [SET_BYTES]u8 = @splat(0);
    var write_fds: [SET_BYTES]u8 = @splat(0);
    var except_fds: [SET_BYTES]u8 = @splat(0);
    if (readfds_ptr != 0 and copy.copyFromUser(&read_fds, @ptrFromInt(readfds_ptr), SET_BYTES) != SET_BYTES) return -14;
    if (writefds_ptr != 0 and copy.copyFromUser(&write_fds, @ptrFromInt(writefds_ptr), SET_BYTES) != SET_BYTES) return -14;
    if (exceptfds_ptr != 0 and copy.copyFromUser(&except_fds, @ptrFromInt(exceptfds_ptr), SET_BYTES) != SET_BYTES) return -14;

    const tsc = @import("../arch/x86_64/tsc.zig");
    const deadline = poll_mod.deadlineFor(wait, tsc.nanos());
    const poll_once = wait == .ms and wait.ms == 0;

    while (true) {
        var read_out: [SET_BYTES]u8 = @splat(0);
        var write_out: [SET_BYTES]u8 = @splat(0);
        var total_ready: u64 = 0;

        for (0..nfds) |fd_i| {
            const byte_idx = fd_i / 8;
            const mask = @as(u8, 1) << @intCast(fd_i % 8);
            const want_r = read_fds[byte_idx] & mask != 0;
            const want_w = write_fds[byte_idx] & mask != 0;
            const want_e = except_fds[byte_idx] & mask != 0;
            if (!want_r and !want_w and !want_e) continue;
            const desc = &cur.fd_table.fds[fd_i];
            if (desc.fd_type == .none) return -9; // EBADF
            const ev = poll_mod.descEvents(desc);
            if (want_r and pp.selectReadable(ev)) {
                read_out[byte_idx] |= mask;
                total_ready += 1;
            }
            if (want_w and pp.selectWritable(ev)) {
                write_out[byte_idx] |= mask;
                total_ready += 1;
            }
        }

        const expired = if (deadline) |d| tsc.nanos() >= d else false;
        if (total_ready > 0 or poll_once or expired) {
            const zero: [SET_BYTES]u8 = @splat(0);
            if (readfds_ptr != 0 and copy.copyToUser(@ptrFromInt(readfds_ptr), &read_out, SET_BYTES) != SET_BYTES) return -14;
            if (writefds_ptr != 0 and copy.copyToUser(@ptrFromInt(writefds_ptr), &write_out, SET_BYTES) != SET_BYTES) return -14;
            if (exceptfds_ptr != 0 and copy.copyToUser(@ptrFromInt(exceptfds_ptr), &zero, SET_BYTES) != SET_BYTES) return -14;
            return @intCast(total_ready);
        }

        const rc = poll_mod.waitSlice(deadline);
        if (rc < 0) return rc;
    }
}
