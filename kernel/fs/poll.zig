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

/// poll(2): the timeout is a C int of milliseconds.
pub fn poll(fds_ptr: u64, nfds: u64, timeout_raw: u64) i64 {
    return pollWait(fds_ptr, nfds, pp.pollTimeout(timeout_raw));
}

/// Read a struct timespec for ppoll/pselect6: null pointer = wait forever.
pub fn readTimespecWait(ptr: u64) union(enum) { ok: pp.Wait, err: i64 } {
    if (ptr == 0) return .{ .ok = .forever };
    const bo = @import("../lib/byte_order.zig");
    var raw: [16]u8 = undefined;
    if (!copy.validateUserBuffer(ptr, 16) or copy.copyFromUser(&raw, @ptrFromInt(ptr), 16) != 16) return .{ .err = -14 };
    const sec: i64 = @bitCast(bo.readU64Le(raw[0..8]));
    const nsec: i64 = @bitCast(bo.readU64Le(raw[8..16]));
    return .{ .ok = pp.timespecWait(sec, nsec) orelse return .{ .err = -22 } };
}

/// ppoll(fds, nfds, tmo_p, sigmask, sigsetsize): poll with a timespec
/// timeout and a temporary signal mask installed for the wait.
pub fn ppoll(fds_ptr: u64, nfds: u64, tmo_ptr: u64, sigmask_ptr: u64, sigsetsize: u64) i64 {
    const mask = readTempMask(sigmask_ptr, sigsetsize);
    const m = switch (mask) {
        .ok => |v| v,
        .err => |e| return e,
    };
    const wait = switch (readTimespecWait(tmo_ptr)) {
        .ok => |w| w,
        .err => |e| return e,
    };
    const saved = beginTempMask(m);
    const rc = pollWait(fds_ptr, nfds, wait);
    endTempMask(saved, rc);
    return rc;
}

pub const TempMask = struct { present: bool = false, mask: u64 = 0 };

/// Parse the (sigmask, sigsetsize) pair of ppoll/pselect6.
pub fn readTempMask(sigmask_ptr: u64, sigsetsize: u64) union(enum) { ok: TempMask, err: i64 } {
    if (sigmask_ptr == 0) return .{ .ok = .{} };
    if (sigsetsize != 8) return .{ .err = -22 };
    var raw: [8]u8 = undefined;
    if (!copy.validateUserBuffer(sigmask_ptr, 8) or copy.copyFromUser(&raw, @ptrFromInt(sigmask_ptr), 8) != 8) return .{ .err = -14 };
    return .{ .ok = .{ .present = true, .mask = @bitCast(raw) } };
}

pub const SavedMask = struct { armed: bool = false, old: u64 = 0 };

/// Install the temporary mask; returns what endTempMask needs.
pub fn beginTempMask(m: TempMask) SavedMask {
    if (!m.present) return .{};
    const cur = sched.currentTask() orelse return .{};
    const saved: SavedMask = .{ .armed = true, .old = cur.signal_mask };
    cur.signal_mask = m.mask & ~@import("../proc/signal_action_policy.zig").UNBLOCKABLE;
    return saved;
}

/// Undo the temporary mask. When the wait was interrupted (-EINTR) the old
/// mask is restored only after the handler has run (TIF_RESTORE_SIGMASK).
pub fn endTempMask(saved: SavedMask, rc: i64) void {
    if (!saved.armed) return;
    const cur = sched.currentTask() orelse return;
    if (rc == -4) {
        cur.saved_sigmask = saved.old;
        cur.restore_sigmask_pending = true;
    } else {
        cur.signal_mask = saved.old;
    }
}

/// Core poll implementation. Returns number of ready fds, 0 on timeout, or -errno.
fn pollWait(fds_ptr: u64, nfds: u64, wait: pp.Wait) i64 {
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
