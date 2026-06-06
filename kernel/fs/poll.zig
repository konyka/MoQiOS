// kernel/fs/poll.zig — I/O multiplexing (poll)
//
// Implements the poll() syscall core: poll an array of file descriptors for
// readability / writability / errors with a timeout.

const sched = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const vfs_mod = @import("vfs.zig");
const tcp_mod = @import("../net/tcp.zig");
const copy = @import("../mm/copy_from_user.zig");

/// Linux pollfd structure.
pub const pollfd = extern struct {
    fd: i32,
    events: i16,
    revents: i16,
};

const POLLIN: i16 = 0x001;
const POLLOUT: i16 = 0x004;
const POLLERR: i16 = 0x008;
const POLLHUP: i16 = 0x010;
const POLLNVAL: i16 = 0x020;

/// Core poll implementation. Returns number of ready fds, 0 on timeout, or -errno.
pub fn poll(fds_ptr: u64, nfds: u64, timeout_ms: u64) i64 {
    if (fds_ptr == 0 or nfds == 0 or nfds > 128) return -22; // EINVAL

    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;

    // Stack-allocate pollfd array
    var pfds: [128]pollfd = @splat(.{ .fd = -1, .events = 0, .revents = 0 });
    const copy_len = @as(usize, @intCast(nfds * @sizeOf(pollfd)));
    const pfds_dst: [*]u8 = @ptrCast(&pfds);
    if (copy.copyFromUser(pfds_dst[0..copy_len], @ptrFromInt(fds_ptr), copy_len) == 0) {
        return -14; // EFAULT
    }

    // Try up to timeout_ms/10 iterations (10ms per check)
    const max_checks = if (timeout_ms == 0) 1 else if (timeout_ms > 30000) 3000 else @max(timeout_ms / 10, 1);
    var checks: u64 = 0;

    while (checks < max_checks) : (checks += 1) {
        var ready_count: u64 = 0;
        for (0..@min(nfds, 128)) |i| {
            pfds[i].revents = 0;
            const fd: u32 = @intCast(pfds[i].fd);
            if (fd >= vfs_mod.MAX_FDS or pfds[i].fd < 0) continue;
            const desc = &t.fd_table.fds[fd];
            if (desc.fd_type == .none) {
                pfds[i].revents = POLLNVAL;
                ready_count += 1;
                continue;
            }

            // Check for readability
            if (pfds[i].events & POLLIN != 0) {
                switch (desc.fd_type) {
                    .tcp_socket => {
                        const avail = tcp_mod.tcpRecvAvailable(desc.tcb_idx);
                        if (avail > 0 or tcp_mod.tcpIsClosing(desc.tcb_idx)) {
                            pfds[i].revents |= POLLIN;
                        }
                    },
                    .pipe_read => {
                        if (desc.pipe_idx < 16) {
                            const pipe = &vfs_mod.pipes[desc.pipe_idx];
                            if (pipe.tail > pipe.head) pfds[i].revents |= POLLIN;
                        }
                    },
                    .eventfd => {
                        const eventfd_mod = @import("eventfd.zig");
                        if (eventfd_mod.eventfdGetCounter(desc.eventfd_idx) > 0) pfds[i].revents |= POLLIN;
                    },
                    .timerfd => {
                        const timerfd_mod = @import("../ipc/timerfd.zig");
                        if (timerfd_mod.timerfdGetExpirations(desc.timerfd_idx) > 0) pfds[i].revents |= POLLIN;
                    },
                    else => {
                        pfds[i].revents |= POLLIN; // files, ramdisk always readable
                    },
                }
            }

            // Check for writability
            if (pfds[i].events & POLLOUT != 0) {
                switch (desc.fd_type) {
                    .tcp_socket => {
                        if (tcp_mod.isEstablished(desc.tcb_idx)) {
                            const space = tcp_mod.tcpSendSpace(desc.tcb_idx);
                            if (space > 0) pfds[i].revents |= POLLOUT;
                        }
                    },
                    else => {
                        pfds[i].revents |= POLLOUT; // pipes, files always writable
                    },
                }
            }

            // Always report errors
            pfds[i].revents |= POLLERR | POLLHUP;
            if (pfds[i].revents & (POLLIN | POLLOUT | POLLERR | POLLHUP | POLLNVAL) != 0) {
                ready_count += 1;
            }
        }

        if (ready_count > 0 or timeout_ms == 0) {
            // Copy back to user
            const pfds_src: [*]const u8 = @ptrCast(&pfds);
            _ = copy.copyToUser(@ptrFromInt(fds_ptr), pfds_src[0..copy_len], copy_len);
            return @intCast(ready_count);
        }

        // Yield CPU and try again
        for (0..100000) |_| {
            asm volatile ("pause");
        }
    }

    // Timeout
    const pfds_src: [*]const u8 = @ptrCast(&pfds);
    _ = copy.copyToUser(@ptrFromInt(fds_ptr), pfds_src[0..copy_len], copy_len);
    return 0;
}
