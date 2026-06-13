/// POSIX Message Queues implementation.
///
/// Provides mq_open, mq_unlink, mq_timedsend, mq_timedreceive, mq_notify, mq_getsetattr.
/// Messages are stored in a ring buffer per queue. Max 16 queues, 8 messages per queue.
const serial = @import("../arch/x86_64/serial.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const fmt = @import("../lib/fmt.zig");
const str = @import("../lib/str.zig");
const bo = @import("../lib/byte_order.zig");

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
    const copy = @import("../mm/copy_from_user.zig");
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
    const tsc = @import("../arch/x86_64/tsc.zig");
    return tsc.nanos() >= abs_timeout_ns;
}

/// Sleep approximately 1ms using TSC busy-wait to yield CPU to other tasks.
fn sleepBrief() void {
    const tsc = @import("../arch/x86_64/tsc.zig");
    const start = tsc.nanos();
    while (tsc.nanos() - start < 1_000_000) {
        asm volatile ("pause");
    }
}

/// mq_open(name, oflag, mode, attr) -> fd or -errno
/// rdi=name, rsi=oflag, rdx=mode, r10=attr
pub fn mqOpen(name_ptr: u64, oflag: u32, mode: u32, attr_ptr: u64) i64 {
    _ = mode;
    const flags = mq_lock.acquire();
    defer mq_lock.release(flags);

    // Read name from user space
    var name_buf: [MAX_NAME_LEN]u8 = @splat(0);
    const name_len: u32 = @intCast(readUserString(name_ptr, &name_buf));
    if (name_len == 0) return EINVAL;

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

    // Read optional attributes
    if (attr_ptr != 0 and attr_ptr < 0x0000_8000_0000_0000) {
        const copy = @import("../mm/copy_from_user.zig");
        var attr_buf: [8]u8 = undefined;
        if (copy.copyFromUser(&attr_buf, @ptrFromInt(attr_ptr), 8) == 8) {
            const mq_maxmsg: u32 = @as(u32, attr_buf[0]) | (@as(u32, attr_buf[1]) << 8) |
                (@as(u32, attr_buf[2]) << 16) | (@as(u32, attr_buf[3]) << 24);
            const mq_msgsize: u32 = @as(u32, attr_buf[4]) | (@as(u32, attr_buf[5]) << 8) |
                (@as(u32, attr_buf[6]) << 16) | (@as(u32, attr_buf[7]) << 24);
            if (mq_maxmsg > 0 and mq_maxmsg <= MAX_MSGS) q.max_msg = mq_maxmsg;
            if (mq_msgsize > 0 and mq_msgsize <= MAX_MSG_SIZE) q.msg_size = mq_msgsize;
        }
    }

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
    const flags = mq_lock.acquire();
    defer mq_lock.release(flags);

    var name_buf: [MAX_NAME_LEN]u8 = @splat(0);
    const name_len: u32 = @intCast(readUserString(name_ptr, &name_buf));
    if (name_len == 0) return EINVAL;

    for (&queues) |*q| {
        if (q.active and str.eql(q.name[0..q.name_len], name_buf[0..name_len])) {
            serial.writeString("[posix_mq] unlink mq=");
            serial.writeString(q.name[0..q.name_len]);
            serial.writeString("\n");
            q.marked_removed = true;
            // If no messages and no references, free immediately
            if (q.count == 0) {
                q.* = .{};
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

    const copy = @import("../mm/copy_from_user.zig");

    // Try to send, with timeout-based retry if queue is full
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
            // Release lock, sleep briefly, retry
            mq_lock.release(flags);
            sleepBrief();
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

        mq_lock.release(flags);
        return 0;
    }
}

/// mq_timedreceive(mqd, msg_ptr, msg_len, msg_prio, abs_timeout) -> bytes or -errno
/// rdi=mqd, rsi=msg_ptr, rdx=msg_len, r10=msg_prio, r8=abs_timeout
pub fn mqTimedReceive(mqd: u32, msg_ptr: u64, msg_len: u64, prio_ptr: u64, timeout_ptr: u64) i64 {
    // Read timeout before acquiring lock
    const abs_timeout_ns = readAbsTimeout(timeout_ptr);

    const copy = @import("../mm/copy_from_user.zig");

    // Try to receive, with timeout-based retry if queue is empty
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
            // Release lock, sleep briefly, retry
            mq_lock.release(flags);
            sleepBrief();
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
        if (prio_ptr != 0 and prio_ptr < 0x0000_8000_0000_0000) {
            var prio_buf: [4]u8 = undefined;
            prio_buf[0] = @intCast(msg.priority & 0xFF);
            prio_buf[1] = @intCast((msg.priority >> 8) & 0xFF);
            prio_buf[2] = @intCast((msg.priority >> 16) & 0xFF);
            prio_buf[3] = @intCast((msg.priority >> 24) & 0xFF);
            _ = copy.copyToUser(@ptrFromInt(prio_ptr), &prio_buf, 4);
        }

        const result_len: i64 = @intCast(out_len);

        // Free slot
        msg.used = false;
        msg.len = 0;
        q.head = (q.head + 1) % MAX_MSGS;
        q.count -= 1;

        // If queue was marked for removal and now empty, free it
        if (q.marked_removed and q.count == 0) {
            q.* = .{};
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
pub fn mqGetSetAttr(mqd: u32, newattr_ptr: u64, oldattr_ptr: u64) i64 {
    const flags = mq_lock.acquire();
    defer mq_lock.release(flags);

    const q = findByFd(mqd) orelse return EBADF;

    // Write old attributes if requested
    if (oldattr_ptr != 0 and oldattr_ptr < 0x0000_8000_0000_0000) {
        const copy = @import("../mm/copy_from_user.zig");
        var attr_buf: [16]u8 = @splat(0);
        // mq_flags (4 bytes) + mq_maxmsg (4 bytes) + mq_msgsize (4 bytes) + mq_curmsgs (4 bytes)
        bo.writeU32Le(attr_buf[0..4], q.flags);
        bo.writeU32Le(attr_buf[4..8], q.max_msg);
        bo.writeU32Le(attr_buf[8..12], q.msg_size);
        bo.writeU32Le(attr_buf[12..16], q.count);
        _ = copy.copyToUser(@ptrFromInt(oldattr_ptr), &attr_buf, 16);
    }

    // Read new attributes if provided
    if (newattr_ptr != 0 and newattr_ptr < 0x0000_8000_0000_0000) {
        const copy = @import("../mm/copy_from_user.zig");
        var attr_buf: [16]u8 = undefined;
        if (copy.copyFromUser(&attr_buf, @ptrFromInt(newattr_ptr), 16) == 16) {
            const new_flags = bo.readU32Le(attr_buf[0..4]);
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
    const copy = @import("../mm/copy_from_user.zig");
    const max_len = buf.len;
    var len: usize = 0;
    while (len < max_len) : (len += 1) {
        var byte: [1]u8 = .{0};
        if (copy.copyFromUser(&byte, @ptrFromInt(user_ptr + len), 1) != 1) return 0;
        if (byte[0] == 0) break;
        buf[len] = byte[0];
    }
    return len;
}
