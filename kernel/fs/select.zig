/// select — I/O multiplexing via fd_set bitmaps.
///
/// Extracted from syscall_entry.zig (v18.8).
const copy = @import("../mm/copy_from_user.zig");
const sched_mod = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const vfs_mod = @import("../fs/vfs.zig");
const tcp_mod = @import("../net/tcp.zig");
const bo = @import("../lib/byte_order.zig");

/// select(nfds, readfds_ptr, writefds_ptr, exceptfds_ptr, timeout_ptr) -> ready count or -errno.
pub fn select(nfds: u64, readfds_ptr: u64, writefds_ptr: u64, exceptfds_ptr: u64, timeout_ptr: u64) i64 {
    if (nfds > 128) return -22; // -EINVAL
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (readfds_ptr != 0 and !copy.validateUserBuffer(readfds_ptr, 16)) return -14;
    if (writefds_ptr != 0 and !copy.validateUserBuffer(writefds_ptr, 16)) return -14;
    if (exceptfds_ptr != 0 and !copy.validateUserBuffer(exceptfds_ptr, 16)) return -14;
    if (timeout_ptr != 0 and !copy.validateUserBuffer(timeout_ptr, 16)) return -14;

    var timeout_ms: u64 = 0;
    if (timeout_ptr != 0) {
        var tv: [16]u8 = undefined;
        if (copy.copyFromUser(&tv, @ptrFromInt(timeout_ptr), 16) != 16) return -14;
        const sec: u64 = bo.readU64Le(tv[0..8]);
        const usec: u64 = bo.readU64Le(tv[8..16]);
        timeout_ms = sec * 1000 + usec / 1000;
    }

    var read_fds: [16]u8 = @splat(0);
    var write_fds: [16]u8 = @splat(0);
    if (readfds_ptr != 0) {
        if (copy.copyFromUser(&read_fds, @ptrFromInt(readfds_ptr), 16) != 16) return -14;
    }
    if (writefds_ptr != 0) {
        if (copy.copyFromUser(&write_fds, @ptrFromInt(writefds_ptr), 16) != 16) return -14;
    }

    const max_checks = if (timeout_ms == 0) 1 else @max(timeout_ms / 10, 1);
    var checks: u64 = 0;
    while (checks < max_checks) : (checks += 1) {
        var read_out: [16]u8 = @splat(0);
        var write_out: [16]u8 = @splat(0);
        var total_ready: u64 = 0;

        for (0..@min(nfds, 128)) |fd_i| {
            const fd: u32 = @intCast(fd_i);
            if (fd >= vfs_mod.MAX_FDS) continue;
            const desc = &cur.fd_table.fds[fd];
            if (desc.fd_type == .none) continue;
            const byte_idx = fd_i / 8;
            const bit_idx: u3 = @intCast(fd_i % 8);

            if (read_fds[byte_idx] & (@as(u8, 1) << bit_idx) != 0) {
                var rdy = false;
                switch (desc.fd_type) {
                    .tcp_socket => {
                        if (tcp_mod.tcpRecvAvailable(desc.tcb_idx) > 0 or tcp_mod.tcpIsClosing(desc.tcb_idx)) rdy = true;
                    },
                    .pipe_read => {
                        if (desc.pipe_idx < 16 and vfs_mod.pipes[desc.pipe_idx].tail > vfs_mod.pipes[desc.pipe_idx].head) rdy = true;
                    },
                    else => rdy = true,
                }
                if (rdy) {
                    read_out[byte_idx] |= @as(u8, 1) << bit_idx;
                    total_ready += 1;
                }
            }
            if (write_fds[byte_idx] & (@as(u8, 1) << bit_idx) != 0) {
                var rdy = false;
                switch (desc.fd_type) {
                    .tcp_socket => {
                        if (tcp_mod.isEstablished(desc.tcb_idx) and tcp_mod.tcpSendSpace(desc.tcb_idx) > 0) rdy = true;
                    },
                    else => rdy = true,
                }
                if (rdy) {
                    write_out[byte_idx] |= @as(u8, 1) << bit_idx;
                    total_ready += 1;
                }
            }
        }

        if (total_ready > 0 or timeout_ms == 0) {
            if (readfds_ptr != 0 and copy.copyToUser(@ptrFromInt(readfds_ptr), &read_out, 16) != 16) return -14;
            if (writefds_ptr != 0 and copy.copyToUser(@ptrFromInt(writefds_ptr), &write_out, 16) != 16) return -14;
            if (exceptfds_ptr != 0) {
                var z: [16]u8 = @splat(0);
                if (copy.copyToUser(@ptrFromInt(exceptfds_ptr), &z, 16) != 16) return -14;
            }
            return @intCast(total_ready);
        }
        for (0..100000) |_| {
            asm volatile ("pause");
        }
    }

    if (readfds_ptr != 0 and readfds_ptr < 0x0000_8000_0000_0000) {
        var z: [16]u8 = @splat(0);
        if (copy.copyToUser(@ptrFromInt(readfds_ptr), &z, 16) != 16) return -14;
    }
    if (writefds_ptr != 0 and writefds_ptr < 0x0000_8000_0000_0000) {
        var z: [16]u8 = @splat(0);
        if (copy.copyToUser(@ptrFromInt(writefds_ptr), &z, 16) != 16) return -14;
    }
    if (exceptfds_ptr != 0) {
        var z: [16]u8 = @splat(0);
        if (copy.copyToUser(@ptrFromInt(exceptfds_ptr), &z, 16) != 16) return -14;
    }
    return 0; // timeout
}
