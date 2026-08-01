/// POSIX Message Queues implementation.
///
/// Provides mq_open, mq_unlink, mq_timedsend, mq_timedreceive, mq_notify, mq_getsetattr.
/// Messages are stored in a ring buffer per queue. Max 16 queues, 8 messages per queue.
const serial = @import("../arch/arch.zig").serial;
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const fmt = @import("../lib/fmt.zig");
const str = @import("../lib/str.zig");
const bo = @import("../lib/byte_order.zig");
const copy = @import("../mm/copy_from_user.zig");
const task = @import("../proc/task.zig");
const sched = @import("../proc/sched.zig");

const MAX_QUEUES: u32 = 16;
const MAX_MSGS: u32 = 8;
const MAX_MSG_SIZE: u32 = 512;
const MAX_NAME_LEN: u32 = 64;

/// POSIX message buffer
const MsgEntry = struct {
    data: [MAX_MSG_SIZE]u8 = @splat(0),
    len: u32 = 0,
    priority: u32 = 0,
    used: bool = false,
};

/// POSIX message queue
pub const MqQueue = struct {
    active: bool = false,
    name: [MAX_NAME_LEN]u8 = @splat(0),
    name_len: u32 = 0,
    /// File descriptor assigned to this queue
    fd: i32 = -1,
    /// Ring buffer of messages
    msgs: [MAX_MSGS]MsgEntry = @splat(.{}),
    head: u32 = 0, // next read position
    tail: u32 = 0, // next write position
    count: u32 = 0,
    /// Queue attributes
    max_msg: u32 = MAX_MSGS,
    msg_size: u32 = MAX_MSG_SIZE,
    /// Flags (O_NONBLOCK etc.)
    flags: u32 = 0,
    /// Marked for removal (mq_unlink)
    marked_removed: bool = false,
    /// Notification registered (pid of notifier, 0 = none)
    notify_pid: u32 = 0,
    /// Senders blocked on a full queue (mq_timedsend without O_NONBLOCK)
    send_waiters: ?*task.WaitNode = null,
    /// Receivers blocked on an empty queue (mq_timedreceive without O_NONBLOCK)
    recv_waiters: ?*task.WaitNode = null,
};

var queues: [MAX_QUEUES]MqQueue = @splat(.{});
var mq_lock: IrqSpinlock = .{};

// ── O_* flags ──
const O_RDONLY: u32 = 0;
const O_WRONLY: u32 = 1;
const O_RDWR: u32 = 2;
const O_CREAT: u32 = 0o100;
const O_EXCL: u32 = 0o200;
const O_NONBLOCK: u32 = 0o4000;
const O_CLOEXEC: u32 = 0o2000000;

// ── Error codes ──
const errno = @import("../lib/errno.zig");
const ENOENT = errno.ENOENT;
const EINVAL = errno.EINVAL;
const EEXIST = errno.EEXIST;
const ENOSPC = errno.ENOSPC;
const EAGAIN = errno.EAGAIN;
const EMFILE = errno.EMFILE;
const EBADF = errno.EBADF;
const EFAULT = errno.EFAULT;
const ETIMEDOUT = errno.ETIMEDOUT;

/// Linux timespec for timeout reading.
const Timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

/// Read absolute timeout from user space, return absolute time in nanoseconds.
/// Returns 0 if timeout_ptr is NULL or invalid (caller should treat as no timeout).
fn readAbsTimeout(timeout_ptr: u64) u64 {
    if (timeout_ptr == 0 or timeout_ptr >= 0x0000_8000_0000_0000) return 0;
    var ts_buf: [@sizeOf(Timespec)]u8 = undefined;
    if (copy.copyFromUser(&ts_buf, @ptrFromInt(timeout_ptr), @sizeOf(Timespec)) != @sizeOf(Timespec)) {
        return 0;
    }
    const ts: *const Timespec = @ptrCast(@alignCast(&ts_buf));
    if (ts.tv_sec < 0) return 0;
    const sec: u64 = @intCast(ts.tv_sec);
    const nsec: u64 = if (ts.tv_nsec >= 0) @intCast(ts.tv_nsec) else 0;
    return sec * 1_000_000_000 + nsec;
}

/// Check if timeout has expired. abs_timeout_ns == 0 means no timeout.
fn isTimedOut(abs_timeout_ns: u64) bool {
    if (abs_timeout_ns == 0) return false;
    const tsc = @import("../arch/arch.zig").tsc;
    return tsc.nanos() >= abs_timeout_ns;
}

/// Remove `node` from `wait_queue` if still linked. Caller holds mq_lock.
/// wakeOne already pops woken nodes; this only matters if a wake path ever
/// bypasses the queue (defensive — mirrors futex.removeWaitNode).
fn unlinkNode(wait_queue: *?*task.WaitNode, node: *task.WaitNode) void {
    var prev: ?*task.WaitNode = null;
    var cur = wait_queue.*;
    while (cur) |n| {
        if (n == node) {
            if (prev) |p| {
                p.next = n.next;
            } else {
                wait_queue.* = n.next;
            }
            return;
        }
        prev = n;
        cur = n.next;
    }
}

/// Free a queue slot, waking any blocked senders/receivers first so they
/// re-check and see the queue gone (EBADF) instead of sleeping forever.
/// Caller holds mq_lock.
fn freeQueue(q: *MqQueue) void {
    sched.wakeAll(&q.send_waiters);
    sched.wakeAll(&q.recv_waiters);
    q.* = .{};
}

/// mq_open(name, oflag, mode, attr) -> fd or -errno
/// rdi=name, rsi=oflag, rdx=mode, r10=attr
pub fn mqOpen(name_ptr: u64, oflag: u32, mode: u32, attr_ptr: u64) i64 {
    _ = mode;

    // Read name and attributes BEFORE taking mq_lock: user copies walk page
    // tables and must not run with IRQs off. Linux struct mq_attr is four
    // 8-byte longs: mq_flags@0, mq_maxmsg@8, mq_msgsize@16, mq_curmsgs@24.
    var name_buf: [MAX_NAME_LEN]u8 = @splat(0);
    const name_len: u32 = @intCast(readUserString(name_ptr, &name_buf));
    if (name_len == 0) return EINVAL;

    var maxmsg: i64 = 0;
    var msgsize: i64 = 0;
    if (attr_ptr != 0 and attr_ptr < 0x0000_8000_0000_0000) {
        var attr_buf: [32]u8 = undefined;
        if (copy.copyFromUser(&attr_buf, @ptrFromInt(attr_ptr), 32) == 32) {
            maxmsg = bo.readI64Le(attr_buf[8..16]);
            msgsize = bo.readI64Le(attr_buf[16..24]);
        }
    }

    const flags = mq_lock.acquire();
    defer mq_lock.release(flags);

    // Search for existing queue with this name
    for (&queues) |*q| {
        if (q.active and str.eql(q.name[0..q.name_len], name_buf[0..name_len])) {
            if (oflag & O_CREAT != 0 and oflag & O_EXCL != 0) {
                return EEXIST;
            }
            // Return existing fd (or assign one)
            if (q.fd < 0) q.fd = allocFd();
            return @intCast(q.fd);
        }
    }

    // Need to create
    if (oflag & O_CREAT == 0) {
        return ENOENT;
    }

    // Find free slot
    var slot: ?u32 = null;
    for (0..MAX_QUEUES) |i| {
        if (!queues[i].active) {
            slot = @intCast(i);
            break;
        }
    }
    if (slot == null) return ENOSPC;

    const idx = slot.?;
    var q = &queues[idx];

    @memset(&q.name, 0);
    for (0..name_len) |j| q.name[j] = name_buf[j];
    q.name_len = name_len;
    q.active = true;
    q.flags = oflag & (O_NONBLOCK | O_CLOEXEC);
    q.head = 0;
    q.tail = 0;
    q.count = 0;
    q.marked_removed = false;
    q.notify_pid = 0;

    // Apply optional attributes (only honored at creation)
    if (maxmsg > 0 and maxmsg <= MAX_MSGS) q.max_msg = @intCast(maxmsg);
    if (msgsize > 0 and msgsize <= MAX_MSG_SIZE) q.msg_size = @intCast(msgsize);

    q.fd = allocFd();

    serial.writeString("[posix_mq] created mq=");
    serial.writeString(q.name[0..q.name_len]);
    serial.writeString(" fd=");
    fmt.writeDecimal64(@intCast(q.fd));
    serial.writeString("\n");

    return @intCast(q.fd);
}

/// mq_unlink(name) -> 0 or -errno
/// rdi=name
pub fn mqUnlink(name_ptr: u64) i64 {
    // Read name before taking mq_lock (see mqOpen).
    var name_buf: [MAX_NAME_LEN]u8 = @splat(0);
    const name_len: u32 = @intCast(readUserString(name_ptr, &name_buf));
    if (name_len == 0) return EINVAL;

    const flags = mq_lock.acquire();
    defer mq_lock.release(flags);

    for (&queues) |*q| {
        if (q.active and str.eql(q.name[0..q.name_len], name_buf[0..name_len])) {
            serial.writeString("[posix_mq] unlink mq=");
            serial.writeString(q.name[0..q.name_len]);
            serial.writeString("\n");
            q.marked_removed = true;
            // If no messages and no references, free immediately
            if (q.count == 0) {
                freeQueue(q);
            }
            return 0;
        }
    }
    return ENOENT;
}

/// mq_timedsend(mqd, msg_ptr, msg_len, msg_prio, abs_timeout) -> 0 or -errno
/// rdi=mqd, rsi=msg_ptr, rdx=msg_len, r10=msg_prio, r8=abs_timeout
pub fn mqTimedSend(mqd: u32, msg_ptr: u64, msg_len: u64, msg_prio: u32, timeout_ptr: u64) i64 {
    // Read timeout before acquiring lock
    const abs_timeout_ns = readAbsTimeout(timeout_ptr);


    // Try to send, blocking on the send wait queue if the queue is full
    while (true) {
        const flags = mq_lock.acquire();

        const q = findByFd(mqd) orelse {
            mq_lock.release(flags);
            return EBADF;
        };
        if (q.marked_removed) {
            mq_lock.release(flags);
            return EBADF;
        }

        if (msg_len > q.msg_size) {
            mq_lock.release(flags);
            return EINVAL;
        }

        if (q.count >= q.max_msg) {
            if (q.flags & O_NONBLOCK != 0) {
                mq_lock.release(flags);
                return EAGAIN;
            }
            // Check timeout before blocking
            if (isTimedOut(abs_timeout_ns)) {
                mq_lock.release(flags);
                return ETIMEDOUT;
            }
            // Block until a receiver frees a slot (or mq_unlink wakes us).
            // Enqueue while holding mq_lock so a concurrent mq_timedreceive
            // can't wakeOne before we join the queue (lost wakeup) — the
            // sysv_sem.semop pattern.
            var node: task.WaitNode = .{ .task_idx = 0 };
            const cur_idx = sched.currentTaskIndex() orelse {
                mq_lock.release(flags);
                return EAGAIN; // kernel thread: cannot block
            };
            node.task_idx = cur_idx;
            node.next = q.send_waiters;
            q.send_waiters = &node;
            const cur_task = task.getTask(cur_idx) orelse {
                mq_lock.release(flags);
                return EAGAIN;
            };
            cur_task.state = .blocked;
            mq_lock.release(flags);
            sched.forceReschedule();
            // Woken: wakeOne already popped our node; unlink defensively in
            // case a future wake path bypasses the queue, then re-check the
            // condition and the deadline from the top.
            const flags2 = mq_lock.acquire();
            unlinkNode(&q.send_waiters, &node);
            mq_lock.release(flags2);
            continue;
        }

        // Space available — send message
        var msg = &q.msgs[q.tail];
        const copy_len: usize = if (msg_len > MAX_MSG_SIZE) MAX_MSG_SIZE else @intCast(msg_len);
        const copied = copy.copyFromUser(msg.data[0..copy_len], @ptrFromInt(msg_ptr), copy_len);
        if (copied != copy_len) {
            mq_lock.release(flags);
            return EFAULT;
        }

        msg.len = @intCast(copy_len);
        msg.priority = msg_prio;
        msg.used = true;
        q.tail = (q.tail + 1) % MAX_MSGS;
        q.count += 1;

        // Wake a receiver blocked on the empty queue
        _ = sched.wakeOne(&q.recv_waiters);

        mq_lock.release(flags);
        return 0;
    }
}

/// mq_timedreceive(mqd, msg_ptr, msg_len, msg_prio, abs_timeout) -> bytes or -errno
/// rdi=mqd, rsi=msg_ptr, rdx=msg_len, r10=msg_prio, r8=abs_timeout
pub fn mqTimedReceive(mqd: u32, msg_ptr: u64, msg_len: u64, prio_ptr: u64, timeout_ptr: u64) i64 {
    if (prio_ptr != 0 and !copy.validateUserBufferWritable(prio_ptr, 4)) return EFAULT;
    // Read timeout before acquiring lock
    const abs_timeout_ns = readAbsTimeout(timeout_ptr);


    // Try to receive, blocking on the receive wait queue if the queue is empty
    while (true) {
        const flags = mq_lock.acquire();

        const q = findByFd(mqd) orelse {
            mq_lock.release(flags);
            return EBADF;
        };
        if (q.marked_removed) {
            mq_lock.release(flags);
            return EBADF;
        }

        if (q.count == 0) {
            if (q.flags & O_NONBLOCK != 0) {
                mq_lock.release(flags);
                return EAGAIN;
            }
            // Check timeout before blocking
            if (isTimedOut(abs_timeout_ns)) {
                mq_lock.release(flags);
                return ETIMEDOUT;
            }
            // Block until a sender posts a message (or mq_unlink wakes us).
            // Enqueue under mq_lock to avoid a lost wakeup (sysv_sem pattern).
            var node: task.WaitNode = .{ .task_idx = 0 };
            const cur_idx = sched.currentTaskIndex() orelse {
                mq_lock.release(flags);
                return EAGAIN; // kernel thread: cannot block
            };
            node.task_idx = cur_idx;
            node.next = q.recv_waiters;
            q.recv_waiters = &node;
            const cur_task = task.getTask(cur_idx) orelse {
                mq_lock.release(flags);
                return EAGAIN;
            };
            cur_task.state = .blocked;
            mq_lock.release(flags);
            sched.forceReschedule();
            // Woken: re-check condition and deadline from the top.
            const flags2 = mq_lock.acquire();
            unlinkNode(&q.recv_waiters, &node);
            mq_lock.release(flags2);
            continue;
        }

        // Message available — receive it
        var msg = &q.msgs[q.head];
        const out_len: usize = if (msg_len < msg.len) @intCast(msg_len) else @intCast(msg.len);

        const written = copy.copyToUser(@ptrFromInt(msg_ptr), msg.data[0..out_len], out_len);
        if (written != out_len) {
            mq_lock.release(flags);
            return EFAULT;
        }

        // Write priority if requested
        if (prio_ptr != 0) {
            var prio_buf: [4]u8 = undefined;
            prio_buf[0] = @intCast(msg.priority & 0xFF);
            prio_buf[1] = @intCast((msg.priority >> 8) & 0xFF);
            prio_buf[2] = @intCast((msg.priority >> 16) & 0xFF);
            prio_buf[3] = @intCast((msg.priority >> 24) & 0xFF);
            if (copy.copyToUser(@ptrFromInt(prio_ptr), &prio_buf, 4) != 4) {
                mq_lock.release(flags);
                return EFAULT;
            }
        }

        const result_len: i64 = @intCast(out_len);

        // Free slot
        msg.used = false;
        msg.len = 0;
        q.head = (q.head + 1) % MAX_MSGS;
        q.count -= 1;

        // Wake a sender blocked on the full queue
        _ = sched.wakeOne(&q.send_waiters);

        // If queue was marked for removal and now empty, free it
        if (q.marked_removed and q.count == 0) {
            freeQueue(q);
        }

        mq_lock.release(flags);
        return result_len;
    }
}

/// mq_notify(mqd, notification) -> 0 or -errno
/// rdi=mqd, rsi=notification (sigevent struct pointer, or NULL to unregister)
pub fn mqNotify(mqd: u32, notif_ptr: u64) i64 {
    const flags = mq_lock.acquire();
    defer mq_lock.release(flags);

    const q = findByFd(mqd) orelse return EBADF;

    if (notif_ptr == 0) {
        // Unregister notification
        q.notify_pid = 0;
        return 0;
    }

    // Register: simplified — just store a marker
    q.notify_pid = 1; // would be PID in real impl
    return 0;
}

/// mq_getsetattr(mqd, newattr, oldattr) -> 0 or -errno
/// rdi=mqd, rsi=newattr, rdx=oldattr
/// Linux struct mq_attr is four 8-byte longs (32 bytes):
/// mq_flags@0, mq_maxmsg@8, mq_msgsize@16, mq_curmsgs@24.
pub fn mqGetSetAttr(mqd: u32, newattr_ptr: u64, oldattr_ptr: u64) i64 {
    if (oldattr_ptr != 0 and !copy.validateUserBufferWritable(oldattr_ptr, 32)) return EFAULT;
    const flags = mq_lock.acquire();
    defer mq_lock.release(flags);

    const q = findByFd(mqd) orelse return EBADF;

    // Write old attributes if requested
    if (oldattr_ptr != 0) {
        var attr_buf: [32]u8 = @splat(0);
        bo.writeI64Le(attr_buf[0..8], q.flags);
        bo.writeI64Le(attr_buf[8..16], q.max_msg);
        bo.writeI64Le(attr_buf[16..24], q.msg_size);
        bo.writeI64Le(attr_buf[24..32], q.count);
        if (copy.copyToUser(@ptrFromInt(oldattr_ptr), &attr_buf, 32) != 32) return EFAULT;
    }

    // Read new attributes if provided
    if (newattr_ptr != 0 and newattr_ptr < 0x0000_8000_0000_0000) {
        var attr_buf: [32]u8 = undefined;
        if (copy.copyFromUser(&attr_buf, @ptrFromInt(newattr_ptr), 32) == 32) {
            const new_flags: u32 = @truncate(@as(u64, @bitCast(bo.readI64Le(attr_buf[0..8]))));
            // Only O_NONBLOCK can be changed
            q.flags = (q.flags & ~@as(u32, O_NONBLOCK)) | (new_flags & O_NONBLOCK);
        }
    }

    return 0;
}

// ── Internal helpers ──

fn findByFd(fd: u32) ?*MqQueue {
    for (&queues) |*q| {
        if (q.active and @as(i32, @bitCast(fd)) == q.fd) return q;
    }
    return null;
}

var next_mq_fd: i32 = 300; // start from high fd number to avoid conflicts

fn allocFd() i32 {
    const fd = next_mq_fd;
    next_mq_fd += 1;
    return fd;
}

fn readUserString(user_ptr: u64, buf: []u8) usize {
    if (user_ptr == 0 or user_ptr >= 0x0000_8000_0000_0000) return 0;
    const max_len = buf.len;
    // Fast path: one bulk copy — a single page-table walk for the whole
    // range instead of one per byte.
    if (copy.copyFromUser(buf, @ptrFromInt(user_ptr), max_len) == max_len) {
        for (buf, 0..) |c, i| {
            if (c == 0) return i;
        }
        return max_len;
    }
    // The 64-byte range may run past the string into an unmapped page;
    // fall back to per-byte copies.
    var len: usize = 0;
    while (len < max_len) : (len += 1) {
        var byte: [1]u8 = .{0};
        if (copy.copyFromUser(&byte, @ptrFromInt(user_ptr + len), 1) != 1) return 0;
        if (byte[0] == 0) break;
        buf[len] = byte[0];
    }
    return len;
}
