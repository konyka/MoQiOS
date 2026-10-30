// kernel/fs/poll.zig — I/O multiplexing (poll)
//
// poll(2): readiness comes from the same per-descriptor function epoll uses
// (net/epoll.zig descriptorEvents), TCP sockets keep their own rules, and a
// wait parks the task in short sleep slices instead of spinning. Argument and
// revents rules live in poll_policy.zig.

const sched = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const vfs_mod = @import("vfs.zig");
const tcp_mod = @import("../net/tcp.zig");
const epoll_mod = @import("../net/epoll.zig");
const copy = @import("../mm/copy_from_user.zig");
const pp = @import("poll_policy.zig");

/// Linux pollfd structure.
pub const pollfd = extern struct {
    fd: i32,
    events: i16,
    revents: i16,
};

const MAX_POLL: usize = 128;
const WAKE_SLICE_MS: u64 = 5;

/// Current readiness of an open descriptor in POLL* bits.
pub fn descEvents(desc: *const vfs_mod.FileDescriptor) u32 {
    if (desc.fd_type == .tcp_socket) {
        var ev: u32 = 0;
        const closing = tcp_mod.tcpIsClosing(desc.tcb_idx);
        if (tcp_mod.tcpRecvAvailable(desc.tcb_idx) > 0 or closing) ev |= pp.POLLIN;
        if (closing) ev |= pp.POLLHUP;
        if (tcp_mod.isEstablished(desc.tcb_idx) and tcp_mod.tcpSendSpace(desc.tcb_idx) > 0) ev |= pp.POLLOUT;
        return ev;
    }
    return epoll_mod.descriptorEvents(desc);
}

/// Deadline for a wait of `w` starting now; null = no deadline.
pub fn deadlineFor(w: pp.Wait, now_ns: u64) ?u64 {
    return switch (w) {
        .forever => null,
        .ms => |ms| now_ns +| ms *| 1_000_000,
    };
}

/// Sleep one slice of a poll/select wait. Returns 0 to rescan, or a negative
/// errno (-EINTR) when a signal ended the wait.
pub fn waitSlice(deadline: ?u64) i64 {
    const tsc = @import("../arch/x86_64/tsc.zig");
    const se = @import("../arch/x86_64/syscall_entry.zig");
    const now = tsc.nanos();
    return se.sleepUntil(pp.sliceDeadline(now, deadline, WAKE_SLICE_MS), 0);
}

/// Core poll implementation. Returns number of ready fds, 0 on timeout, or -errno.
pub fn poll(fds_ptr: u64, nfds: u64, timeout_raw: u64) i64 {
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const t = task_mod.getTask(cur_idx) orelse return -1;
    if (!pp.nfdsValid(nfds, @min(t.nofile_cur, MAX_POLL))) return -22; // EINVAL

    const n: usize = @intCast(nfds);
    var pfds: [MAX_POLL]pollfd = @splat(.{ .fd = -1, .events = 0, .revents = 0 });
    const bytes = n * @sizeOf(pollfd);
    if (n > 0) {
        if (fds_ptr == 0) return -14; // EFAULT
        const dst: [*]u8 = @ptrCast(&pfds);
        if (copy.copyFromUser(dst[0..bytes], @ptrFromInt(fds_ptr), bytes) != bytes) return -14;
    }

    const tsc = @import("../arch/x86_64/tsc.zig");
    const wait = pp.pollTimeout(timeout_raw);
    const deadline = deadlineFor(wait, tsc.nanos());
    const poll_once = wait == .ms and wait.ms == 0;

    while (true) {
        var ready: u64 = 0;
        for (0..n) |i| {
            pfds[i].revents = 0;
            // A negative fd means "ignore this entry" (POSIX); test before casting.
            if (pfds[i].fd < 0) continue;
            const fd: u32 = @intCast(pfds[i].fd);
            if (fd >= vfs_mod.MAX_FDS or t.fd_table.fds[fd].fd_type == .none) {
                pfds[i].revents = @intCast(pp.POLLNVAL);
                ready += 1;
                continue;
            }
            const ev = pp.revents(descEvents(&t.fd_table.fds[fd]), @as(u16, @bitCast(pfds[i].events)));
            pfds[i].revents = @intCast(ev);
            if (ev != 0) ready += 1;
        }

        const expired = if (deadline) |d| tsc.nanos() >= d else false;
        if (ready > 0 or poll_once or expired) {
            if (n > 0) {
                const src: [*]const u8 = @ptrCast(&pfds);
                if (copy.copyToUser(@ptrFromInt(fds_ptr), src[0..bytes], bytes) != bytes) return -14;
            }
            return @intCast(ready);
        }

        const rc = waitSlice(deadline);
        if (rc < 0) return rc;
    }
}
